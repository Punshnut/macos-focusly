import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import MetalKit
import os.log
@preconcurrency import ScreenCaptureKit

fileprivate struct CompositorShaderTuning: Equatable {
    var blurQuality: UInt32
    var blurStrength: Float
    var blurSpread: Float
}

/// GPU compositor backend that captures one display and applies a focus-window carve-out in shader space.
@MainActor
final class CompositorOverlayPipeline: NSObject {
    private enum PowerPreset: String {
        case auto
        case quality
        case balanced
        case efficiency
    }

    private struct RuntimeTuning: Equatable {
        var effectivePreset: PowerPreset
        var captureFPSCap: Int
        var queueDepth: Int
        var shader: CompositorShaderTuning
        var idlePauseDelay: TimeInterval
        var noFocusPauseDelay: TimeInterval
        var minimumCaptureRunDuration: TimeInterval
        var restartDebounce: TimeInterval

        static let `default` = RuntimeTuning(
            effectivePreset: .balanced,
            captureFPSCap: 90,
            queueDepth: 3,
            shader: CompositorShaderTuning(blurQuality: 1, blurStrength: 0.8, blurSpread: 1.0),
            idlePauseDelay: 1.2,
            noFocusPauseDelay: 0.65,
            minimumCaptureRunDuration: 1.2,
            restartDebounce: 0.16
        )
    }

    private let displayID: DisplayID
    private let logger = Logger(subsystem: "com.focusly.app", category: "CompositorOverlay")
    private let rendererView: CompositorOverlayView
    private let streamCoordinator: CompositorStreamCoordinator
    private var currentStyle: FocusOverlayStyle = .blurFocus
    private var currentRefreshProfile: DisplayRefreshProfile?
    private var runtimeTuning = RuntimeTuning.default
    private var filtersEnabled = true
    private var currentOverlayFrame: NSRect = .zero
    private var currentFocusFrame: NSRect?
    private var idlePauseWorkItem: DispatchWorkItem?
    private var restartWorkItem: DispatchWorkItem?
    private var lastCaptureStartedAt = Date.distantPast
    private var lastCaptureStoppedAt = Date.distantPast
    private var lastCaptureFailureAt = Date.distantPast
    private var consecutiveStartFailures = 0
    private var lastCaptureActivityAt = Date.distantPast
    private var hasRenderedFrameSinceCaptureStart = false

    private(set) var isRunning = false
    private(set) var isAvailable = true
    private(set) var isPresentationReady = false
    var onAvailabilityChanged: ((Bool) -> Void)?
    var onPresentationStateChanged: ((Bool) -> Void)?

    init(displayID: DisplayID) {
        self.displayID = displayID
        self.rendererView = CompositorOverlayView(frame: .zero)
        self.streamCoordinator = CompositorStreamCoordinator(displayID: displayID)
        super.init()
        streamCoordinator.onFrameAvailable = { [weak self, weak rendererView] pixelBuffer in
            Task { @MainActor in
                rendererView?.consume(pixelBuffer: pixelBuffer)
                self?.hasRenderedFrameSinceCaptureStart = true
                self?.lastCaptureActivityAt = Date()
                self?.updatePresentationState()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerStateDidChange),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        refreshRuntimeTuning(reason: "init")
        rendererView.updateStyle(currentStyle, filtersEnabled: filtersEnabled, shaderTuning: runtimeTuning.shader)
    }

    var view: NSView { rendererView }

    /// Updates visual style used by the compositor shader.
    func apply(style: FocusOverlayStyle) {
        currentStyle = style
        refreshRuntimeTuning(reason: "style")
        rendererView.updateStyle(style, filtersEnabled: filtersEnabled, shaderTuning: runtimeTuning.shader)
        registerCaptureActivity(requiresImmediateCapture: false)
    }

    /// Enables or disables compositor tint/dim effects.
    func setFiltersEnabled(_ enabled: Bool) {
        filtersEnabled = enabled
        rendererView.updateStyle(currentStyle, filtersEnabled: enabled, shaderTuning: runtimeTuning.shader)
        if enabled {
            registerCaptureActivity(requiresImmediateCapture: true)
        } else {
            stopCapture()
        }
        updatePresentationState()
    }

    /// Updates capture/shader tuning from the display refresh profile.
    func setRefreshProfile(_ profile: DisplayRefreshProfile?) {
        guard currentRefreshProfile != profile else { return }
        currentRefreshProfile = profile
        refreshRuntimeTuning(reason: "refresh_profile")
    }

    /// Updates the overlay frame used to normalize focused-window coordinates.
    func setOverlayFrame(_ frame: NSRect) {
        let didChange = !currentOverlayFrame.isApproximatelyEqual(to: frame, tolerance: 0.35)
        currentOverlayFrame = frame
        rendererView.updateFocusFrame(currentFocusFrame, overlayFrame: frame)
        if didChange {
            registerCaptureActivity(requiresImmediateCapture: true)
        }
    }

    /// Updates the currently focused window frame (global coordinates).
    func setFocusedWindowFrame(_ frame: NSRect?) {
        let didChange = frameDidChangeSignificantly(from: currentFocusFrame, to: frame)
        currentFocusFrame = frame
        rendererView.updateFocusFrame(frame, overlayFrame: currentOverlayFrame)
        let shouldResumeCapture = didChange || (frame != nil && !isRunning)
        registerCaptureActivity(requiresImmediateCapture: shouldResumeCapture)
    }

    /// Starts display capture if compositor mode is enabled and permission is granted.
    func startCaptureIfNeeded() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        guard filtersEnabled else { return }
        guard !isRunning else { return }
        if consecutiveStartFailures > 0 {
            let elapsed = Date().timeIntervalSince(lastCaptureFailureAt)
            let backoff = startFailureBackoffDelay()
            if elapsed < backoff {
                scheduleCaptureRestart(after: backoff - elapsed)
                return
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await streamCoordinator.startCaptureIfNeeded()
            self.isRunning = started
            if !started {
                self.lastCaptureStoppedAt = Date()
                self.lastCaptureFailureAt = Date()
                self.consecutiveStartFailures = min(self.consecutiveStartFailures + 1, 8)
                self.updateAvailability(false)
                self.logger.error("Compositor capture unavailable for display \(self.displayID, privacy: .public); retrying on next activity.")
                self.updatePresentationState()
                self.scheduleCaptureRestart(after: self.startFailureBackoffDelay())
                return
            }
            self.consecutiveStartFailures = 0
            self.lastCaptureFailureAt = .distantPast
            self.updateAvailability(true)
            self.hasRenderedFrameSinceCaptureStart = false
            self.lastCaptureStartedAt = Date()
            self.lastCaptureActivityAt = Date()
            self.updatePresentationState()
            self.scheduleIdlePauseIfNeeded()
        }
    }

    /// Stops display capture to reduce energy and avoid persistent capture indicators.
    func stopCapture() {
        idlePauseWorkItem?.cancel()
        idlePauseWorkItem = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        guard isRunning else { return }
        isRunning = false
        lastCaptureStoppedAt = Date()
        streamCoordinator.stopCapture()
        updatePresentationState()
    }

    /// Re-resolves runtime tuning whenever power state, style, or display profile changes.
    private func refreshRuntimeTuning(reason: StaticString) {
        let previousTuning = runtimeTuning
        runtimeTuning = resolveRuntimeTuning()
        rendererView.updateStyle(currentStyle, filtersEnabled: filtersEnabled, shaderTuning: runtimeTuning.shader)

        let policyChanged = streamCoordinator.updateCapturePolicy(
            frameRateCap: runtimeTuning.captureFPSCap,
            queueDepth: runtimeTuning.queueDepth
        )
        if policyChanged, isRunning {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.debug(
                    "Restarting capture for display \(self.displayID, privacy: .public) due to runtime tuning change (\(reason, privacy: .public))."
                )
                let started = await self.streamCoordinator.restartCaptureIfNeeded()
                self.isRunning = started
                if started {
                    self.lastCaptureStartedAt = Date()
                    self.lastCaptureActivityAt = Date()
                    self.scheduleIdlePauseIfNeeded()
                } else {
                    self.lastCaptureStoppedAt = Date()
                }
            }
        } else if previousTuning != runtimeTuning, isRunning {
            scheduleIdlePauseIfNeeded()
        }
    }

    /// Selects capture frame-rate, queue depth, and shader complexity based on display/power conditions.
    private func resolveRuntimeTuning() -> RuntimeTuning {
        let defaults = UserDefaults.standard
        let requestedPreset = resolvedRequestedPreset(defaults: defaults)
        let effectivePreset = resolvedEffectivePreset(from: requestedPreset)
        let profileFPS = max(60, Int(round(currentRefreshProfile?.preferredFramesPerSecond ?? 60)))

        let captureCap: Int = {
            let baseCap: Int
            switch effectivePreset {
            case .quality:
                baseCap = min(profileFPS, 120)
            case .balanced:
                baseCap = min(profileFPS, 90)
            case .efficiency:
                baseCap = min(profileFPS, 60)
            case .auto:
                baseCap = min(profileFPS, 90)
            }

            var resolved = baseCap
            let globalOverride = defaults.integer(forKey: "Focusly.CompositorCaptureFPSCap")
            if globalOverride > 0 {
                resolved = min(resolved, globalOverride)
            }
            let perDisplayOverrideKey = "Focusly.CompositorCaptureFPSCap.\(displayID)"
            let perDisplayOverride = defaults.integer(forKey: perDisplayOverrideKey)
            if perDisplayOverride > 0 {
                resolved = min(resolved, perDisplayOverride)
            }
            return min(max(resolved, 24), 240)
        }()

        let blurRadius = Float(max(0, currentStyle.blurRadius))
        let radiusFactor = min(max(blurRadius / 36.0, 0.45), 1.25)
        let shader: CompositorShaderTuning
        let queueDepth: Int
        let idlePauseDelay: TimeInterval
        let noFocusPauseDelay: TimeInterval
        let minRunDuration: TimeInterval
        let restartDebounce: TimeInterval

        switch effectivePreset {
        case .quality:
            shader = CompositorShaderTuning(
                blurQuality: 2,
                blurStrength: min(max(0.74 * radiusFactor, 0.5), 1.0),
                blurSpread: min(max(1.05 * radiusFactor, 0.85), 1.6)
            )
            queueDepth = 4
            idlePauseDelay = 1.85
            noFocusPauseDelay = 0.95
            minRunDuration = 1.6
            restartDebounce = 0.12
        case .balanced:
            shader = CompositorShaderTuning(
                blurQuality: 1,
                blurStrength: min(max(0.68 * radiusFactor, 0.42), 0.9),
                blurSpread: min(max(0.92 * radiusFactor, 0.72), 1.35)
            )
            queueDepth = 3
            idlePauseDelay = 1.2
            noFocusPauseDelay = 0.65
            minRunDuration = 1.2
            restartDebounce = 0.16
        case .efficiency:
            shader = CompositorShaderTuning(
                blurQuality: 0,
                blurStrength: min(max(0.54 * radiusFactor, 0.34), 0.74),
                blurSpread: min(max(0.78 * radiusFactor, 0.55), 1.12)
            )
            queueDepth = 2
            idlePauseDelay = 0.78
            noFocusPauseDelay = 0.4
            minRunDuration = 0.85
            restartDebounce = 0.24
        case .auto:
            shader = RuntimeTuning.default.shader
            queueDepth = RuntimeTuning.default.queueDepth
            idlePauseDelay = RuntimeTuning.default.idlePauseDelay
            noFocusPauseDelay = RuntimeTuning.default.noFocusPauseDelay
            minRunDuration = RuntimeTuning.default.minimumCaptureRunDuration
            restartDebounce = RuntimeTuning.default.restartDebounce
        }

        return RuntimeTuning(
            effectivePreset: effectivePreset,
            captureFPSCap: captureCap,
            queueDepth: queueDepth,
            shader: shader,
            idlePauseDelay: idlePauseDelay,
            noFocusPauseDelay: noFocusPauseDelay,
            minimumCaptureRunDuration: minRunDuration,
            restartDebounce: restartDebounce
        )
    }

    /// Returns the user-requested compositor power preset, defaulting to `auto`.
    private func resolvedRequestedPreset(defaults: UserDefaults) -> PowerPreset {
        guard let raw = defaults.string(forKey: "Focusly.CompositorPowerPreset"),
              let preset = PowerPreset(rawValue: raw) else {
            return .auto
        }
        return preset
    }

    /// Resolves the effective power preset from user intent + runtime power/display constraints.
    private func resolvedEffectivePreset(from requested: PowerPreset) -> PowerPreset {
        guard requested == .auto else { return requested }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return .efficiency
        }
        if let profile = currentRefreshProfile, profile.preferredFramesPerSecond >= 120 {
            return .balanced
        }
        return .quality
    }

    /// Records compositor activity and decides whether capture should be resumed or paused.
    private func registerCaptureActivity(requiresImmediateCapture: Bool) {
        lastCaptureActivityAt = Date()
        idlePauseWorkItem?.cancel()
        idlePauseWorkItem = nil

        guard filtersEnabled else { return }

        if requiresImmediateCapture {
            ensureCaptureRunningWithDebounce()
        } else if isRunning {
            scheduleIdlePauseIfNeeded()
        } else if currentFocusFrame != nil {
            ensureCaptureRunningWithDebounce()
        }
    }

    /// Starts capture immediately when debounce allows; otherwise schedules a delayed restart.
    private func ensureCaptureRunningWithDebounce() {
        if isRunning {
            scheduleIdlePauseIfNeeded()
            return
        }

        let now = Date()
        let elapsedSinceStop = now.timeIntervalSince(lastCaptureStoppedAt)
        if elapsedSinceStop >= runtimeTuning.restartDebounce || lastCaptureStoppedAt == .distantPast {
            startCaptureIfNeeded()
            return
        }

        restartWorkItem?.cancel()
        let remaining = runtimeTuning.restartDebounce - elapsedSinceStop
        scheduleCaptureRestart(after: remaining)
    }

    /// Schedules an idle timeout that pauses capture to reduce sustained indicator uptime.
    private func scheduleIdlePauseIfNeeded() {
        idlePauseWorkItem?.cancel()
        idlePauseWorkItem = nil
        guard isRunning else { return }
        guard filtersEnabled else { return }
        guard dynamicPauseEnabled else { return }

        let idleDelay = currentFocusFrame == nil
            ? runtimeTuning.noFocusPauseDelay
            : runtimeTuning.idlePauseDelay
        let now = Date()
        let elapsedRun = now.timeIntervalSince(lastCaptureStartedAt)
        let remainingMinimumRun = max(0, runtimeTuning.minimumCaptureRunDuration - elapsedRun)
        let delay = max(idleDelay, remainingMinimumRun)

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isRunning, self.filtersEnabled else { return }
                if !self.hasRenderedFrameSinceCaptureStart {
                    self.scheduleIdlePauseIfNeeded()
                    return
                }
                let idleDelay = self.currentFocusFrame == nil
                    ? self.runtimeTuning.noFocusPauseDelay
                    : self.runtimeTuning.idlePauseDelay
                let idleElapsed = Date().timeIntervalSince(self.lastCaptureActivityAt)
                if idleElapsed < idleDelay {
                    self.scheduleIdlePauseIfNeeded()
                    return
                }
                self.logger.debug(
                    "Pausing compositor capture on display \(self.displayID, privacy: .public) after \(idleElapsed, format: .fixed(precision: 2), privacy: .public)s idle."
                )
                self.stopCapture()
            }
        }
        idlePauseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Allows dynamic pause/restart heuristics to be toggled from defaults during field testing.
    private var dynamicPauseEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "Focusly.CompositorDynamicPauseEnabled") == nil {
            return true
        }
        return defaults.bool(forKey: "Focusly.CompositorDynamicPauseEnabled")
    }

    /// Returns whether focus geometry changed enough to warrant immediate capture restart.
    private func frameDidChangeSignificantly(from previous: NSRect?, to next: NSRect?) -> Bool {
        switch (previous, next) {
        case (nil, nil):
            return false
        case (.none, .some), (.some, .none):
            return true
        case let (lhs?, rhs?):
            return !lhs.isApproximatelyEqual(to: rhs, tolerance: 0.45)
        }
    }

    /// Updates compositor availability and notifies listeners so they can switch rendering backends.
    private func updateAvailability(_ available: Bool) {
        guard isAvailable != available else { return }
        isAvailable = available
        onAvailabilityChanged?(available)
        updatePresentationState()
    }

    /// Computes exponential backoff after repeated capture-start failures.
    private func startFailureBackoffDelay() -> TimeInterval {
        guard consecutiveStartFailures > 0 else { return 0 }
        let exponent = max(0, consecutiveStartFailures - 1)
        return min(2.5, 0.22 * pow(1.8, Double(exponent)))
    }

    /// Schedules a capture restart attempt after a delay.
    private func scheduleCaptureRestart(after delay: TimeInterval) {
        guard delay.isFinite, delay >= 0 else { return }
        restartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.startCaptureIfNeeded()
            }
        }
        restartWorkItem = workItem
        if delay <= 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    /// Publishes whether the compositor currently has live output ready for presentation.
    private func updatePresentationState() {
        let ready = isAvailable && filtersEnabled && isRunning && hasRenderedFrameSinceCaptureStart
        guard isPresentationReady != ready else { return }
        isPresentationReady = ready
        onPresentationStateChanged?(ready)
    }

    /// Re-tunes compositor policy when macOS low-power state toggles.
    @objc private func handlePowerStateDidChange(_ notification: Notification) {
        refreshRuntimeTuning(reason: "power_state")
    }
}

/// Metal view that renders captured frames and applies focus carve-outs directly in the fragment shader.
@MainActor
private final class CompositorOverlayView: MTKView {
    private let renderer: CompositorMetalRenderer?

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        let resolvedDevice = device ?? MTLCreateSystemDefaultDevice()
        if let resolvedDevice {
            self.renderer = CompositorMetalRenderer(device: resolvedDevice)
        } else {
            self.renderer = nil
        }
        super.init(frame: frameRect, device: resolvedDevice)
        translatesAutoresizingMaskIntoConstraints = false
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 120
        layerContentsPlacement = .scaleAxesIndependently
        layer?.drawsAsynchronously = true
        wantsLayer = true
        delegate = renderer
        renderer?.attach(to: self)
    }

    convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, device: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Enqueues a captured frame for the next draw pass.
    func consume(pixelBuffer: CVPixelBuffer) {
        renderer?.consume(pixelBuffer: pixelBuffer)
        setNeedsDisplay(bounds)
    }

    /// Updates shader uniforms for overlay style, active filter state, and runtime quality tuning.
    func updateStyle(_ style: FocusOverlayStyle, filtersEnabled: Bool, shaderTuning: CompositorShaderTuning) {
        renderer?.updateStyle(style, filtersEnabled: filtersEnabled, shaderTuning: shaderTuning)
        setNeedsDisplay(bounds)
    }

    /// Recomputes the normalized focus rect used by the shader.
    func updateFocusFrame(_ globalFrame: NSRect?, overlayFrame: NSRect) {
        guard overlayFrame.width > 0, overlayFrame.height > 0 else {
            renderer?.updateFocusRect(nil)
            return
        }
        guard let globalFrame else {
            renderer?.updateFocusRect(nil)
            return
        }

        let visibleFocus = globalFrame.intersection(overlayFrame)
        guard !visibleFocus.isNull, visibleFocus.width > 0, visibleFocus.height > 0 else {
            renderer?.updateFocusRect(nil)
            return
        }

        let normalized = CGRect(
            x: (visibleFocus.minX - overlayFrame.minX) / overlayFrame.width,
            y: (visibleFocus.minY - overlayFrame.minY) / overlayFrame.height,
            width: visibleFocus.width / overlayFrame.width,
            height: visibleFocus.height / overlayFrame.height
        ).standardized
        renderer?.updateFocusRect(normalized)
    }
}

/// Encapsulates Metal rendering state for the compositor view.
private final class CompositorMetalRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var focusRect: SIMD4<Float> = .zero
        var tintColor: SIMD4<Float> = SIMD4<Float>(repeating: 0)
        var texelSize: SIMD2<Float> = SIMD2<Float>(0, 0)
        var dimAlpha: Float = 0
        var feather: Float = 0.008
        var blurStrength: Float = 0.8
        var blurSpread: Float = 1.0
        var hasFocus: UInt32 = 0
        var blurQuality: UInt32 = 1
        var _padding0: UInt32 = 0
        var _padding1: UInt32 = 0
    }

    private weak var view: MTKView?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var latestPixelBuffer: CVPixelBuffer?
    private var uniforms = Uniforms()
    private let logger = Logger(subsystem: "com.focusly.app", category: "CompositorRenderer")

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: compositorShaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "focuslyCompositorVertex"),
              let fragmentFunction = library.makeFunction(name: "focuslyCompositorFragment")
        else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "FocuslyCompositorPipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        super.init()
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        if cacheStatus != kCVReturnSuccess {
            logger.error("Failed to create CVMetalTextureCache: \(cacheStatus, privacy: .public)")
        }
    }

    func attach(to view: MTKView) {
        self.view = view
    }

    /// Stores latest frame sample to be drawn on next MTKView refresh.
    @MainActor
    func consume(pixelBuffer: CVPixelBuffer) {
        latestPixelBuffer = pixelBuffer
    }

    /// Updates overlay tint/dim intensity uniforms and shader quality controls.
    @MainActor
    func updateStyle(_ style: FocusOverlayStyle, filtersEnabled: Bool, shaderTuning: CompositorShaderTuning) {
        let tint = style.tint.makeColor().usingColorSpace(.deviceRGB) ?? .black
        let tintAlpha = Float(max(0, min(tint.alphaComponent, 1)))
        uniforms.tintColor = SIMD4<Float>(
            Float(tint.redComponent),
            Float(tint.greenComponent),
            Float(tint.blueComponent),
            tintAlpha
        )
        uniforms.dimAlpha = filtersEnabled ? Float(max(0, min(style.opacity, 1))) : 0
        uniforms.blurStrength = shaderTuning.blurStrength
        uniforms.blurSpread = shaderTuning.blurSpread
        uniforms.blurQuality = shaderTuning.blurQuality
    }

    /// Updates focus-rect uniforms (normalized 0...1 in overlay coordinates).
    @MainActor
    func updateFocusRect(_ normalized: CGRect?) {
        guard let normalized else {
            uniforms.focusRect = .zero
            uniforms.hasFocus = 0
            return
        }
        uniforms.focusRect = SIMD4<Float>(
            Float(max(0, min(1, normalized.origin.x))),
            Float(max(0, min(1, normalized.origin.y))),
            Float(max(0, min(1, normalized.size.width))),
            Float(max(0, min(1, normalized.size.height)))
        )
        uniforms.hasFocus = (uniforms.focusRect.z > 0 && uniforms.focusRect.w > 0) ? 1 : 0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        uniforms.texelSize = SIMD2<Float>(Float(1.0 / size.width), Float(1.0 / size.height))
    }

    func draw(in view: MTKView) {
        guard let pixelBuffer = latestPixelBuffer,
              let texture = makeTexture(from: pixelBuffer),
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }

        uniforms.texelSize = SIMD2<Float>(
            Float(1.0 / CGFloat(max(texture.width, 1))),
            Float(1.0 / CGFloat(max(texture.height, 1)))
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else {
            return nil
        }
        return CVMetalTextureGetTexture(cvTexture)
    }
}

/// Manages a ScreenCaptureKit stream for one display and forwards frames to the compositor renderer.
@MainActor
private final class CompositorStreamCoordinator: NSObject {
    typealias FrameHandler = (CVPixelBuffer) -> Void

    private static let capturePermissionPromptCooldown: TimeInterval = 7 * 24 * 60 * 60
    private static let lastCapturePermissionPromptKey = "Focusly.LastScreenCapturePromptAt"
    private let displayID: DisplayID
    private let outputQueue = DispatchQueue(label: "com.focusly.compositor.stream", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.focusly.app", category: "CompositorCapture")
    private var captureFrameRateCap = 90
    private var captureQueueDepth = 3
    private var stream: SCStream?
    private var streamOutput: StreamOutputProxy?
    var onFrameAvailable: FrameHandler?

    init(displayID: DisplayID) {
        self.displayID = displayID
        super.init()
    }

    /// Updates runtime capture policy and reports whether an active stream must restart.
    func updateCapturePolicy(frameRateCap: Int, queueDepth: Int) -> Bool {
        let clampedCap = min(max(frameRateCap, 24), 240)
        let clampedQueueDepth = min(max(queueDepth, 1), 8)
        let changed = clampedCap != captureFrameRateCap || clampedQueueDepth != captureQueueDepth
        captureFrameRateCap = clampedCap
        captureQueueDepth = clampedQueueDepth
        return changed && stream != nil
    }

    /// Starts ScreenCaptureKit stream if permission and display metadata are available.
    func startCaptureIfNeeded() async -> Bool {
        if stream != nil {
            return true
        }
        let hasPermission = await MainActor.run {
            Self.ensureCapturePermission()
        }
        guard hasPermission else {
            return false
        }

        do {
            let shareableContent = try await SCShareableContent.current
            guard let targetDisplay = shareableContent.displays.first(where: { DisplayID($0.displayID) == displayID }) else {
                logger.error("Unable to resolve shareable display \(self.displayID, privacy: .public)")
                return false
            }

            let filter = SCContentFilter(
                display: targetDisplay,
                excludingApplications: [],
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(targetDisplay.width))
            configuration.height = max(1, Int(targetDisplay.height))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(captureFrameRateCap))
            configuration.queueDepth = captureQueueDepth
            configuration.capturesAudio = false
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB

            let outputProxy = StreamOutputProxy()
            outputProxy.onSampleBuffer = { [weak self] sampleBuffer in
                DispatchQueue.main.async { [weak self] in
                    self?.handleSampleBuffer(sampleBuffer)
                }
            }

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(outputProxy, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()

            self.stream = stream
            self.streamOutput = outputProxy
            return true
        } catch {
            logger.error("Failed starting compositor stream: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Restarts stream capture using current runtime policy settings.
    func restartCaptureIfNeeded() async -> Bool {
        guard stream != nil else {
            return await startCaptureIfNeeded()
        }
        await stopCaptureAndWait()
        return await startCaptureIfNeeded()
    }

    /// Stops stream capture and releases stream/output references.
    func stopCapture() {
        Task { @MainActor [weak self] in
            await self?.stopCaptureAndWait()
        }
    }

    /// Stops capture synchronously for restart flows.
    private func stopCaptureAndWait() async {
        guard let stream else { return }
        self.stream = nil
        self.streamOutput = nil
        do {
            try await stream.stopCapture()
        } catch {
            // Stream teardown can race with display changes; ignore stop failures.
        }
    }

    /// Requests capture permission when required (one-time prompt).
    private static func ensureCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "Focusly.AutoPromptPermissions") else {
            return false
        }
        let now = Date()
        let lastPrompt = defaults.object(forKey: lastCapturePermissionPromptKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(lastPrompt) >= capturePermissionPromptCooldown else {
            return false
        }
        defaults.set(now, forKey: lastCapturePermissionPromptKey)
        return CGRequestScreenCaptureAccess()
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }
        let pixelBuffer = imageBuffer as CVPixelBuffer
        onFrameAvailable?(pixelBuffer)
    }
}

/// Stream output bridge that forwards SCStream buffers using a closure.
private final class StreamOutputProxy: NSObject, SCStreamOutput {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        onSampleBuffer?(sampleBuffer)
    }
}

private let compositorShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct FocuslyCompositorUniforms {
    float4 focusRect;
    float4 tintColor;
    float2 texelSize;
    float dimAlpha;
    float feather;
    float blurStrength;
    float blurSpread;
    uint hasFocus;
    uint blurQuality;
    uint padding0;
    uint padding1;
};

vertex VertexOut focuslyCompositorVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    constexpr float2 texCoords[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 focuslyCompositorFragment(
    VertexOut in [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    constant FocuslyCompositorUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);

    const float4 baseColor = sourceTexture.sample(textureSampler, uv);
    const float2 texel = uniforms.texelSize * max(uniforms.blurSpread, 0.2);
    float3 blurAccum = baseColor.rgb;
    float blurWeight = 1.0;

    const float3 blurSampleX0 = sourceTexture.sample(textureSampler, uv + float2(texel.x, 0.0)).rgb;
    const float3 blurSampleX1 = sourceTexture.sample(textureSampler, uv - float2(texel.x, 0.0)).rgb;
    const float3 blurSampleY0 = sourceTexture.sample(textureSampler, uv + float2(0.0, texel.y)).rgb;
    const float3 blurSampleY1 = sourceTexture.sample(textureSampler, uv - float2(0.0, texel.y)).rgb;
    blurAccum += (blurSampleX0 + blurSampleX1 + blurSampleY0 + blurSampleY1) * 0.9;
    blurWeight += 3.6;

    if (uniforms.blurQuality >= 1) {
        const float3 blurSampleD0 = sourceTexture.sample(textureSampler, uv + float2(texel.x, texel.y)).rgb;
        const float3 blurSampleD1 = sourceTexture.sample(textureSampler, uv + float2(-texel.x, texel.y)).rgb;
        const float3 blurSampleD2 = sourceTexture.sample(textureSampler, uv + float2(texel.x, -texel.y)).rgb;
        const float3 blurSampleD3 = sourceTexture.sample(textureSampler, uv + float2(-texel.x, -texel.y)).rgb;
        blurAccum += (blurSampleD0 + blurSampleD1 + blurSampleD2 + blurSampleD3) * 0.52;
        blurWeight += 2.08;
    }

    if (uniforms.blurQuality >= 2) {
        const float2 ring = texel * 1.9;
        const float3 blurSampleR0 = sourceTexture.sample(textureSampler, uv + float2(ring.x, 0.0)).rgb;
        const float3 blurSampleR1 = sourceTexture.sample(textureSampler, uv - float2(ring.x, 0.0)).rgb;
        const float3 blurSampleR2 = sourceTexture.sample(textureSampler, uv + float2(0.0, ring.y)).rgb;
        const float3 blurSampleR3 = sourceTexture.sample(textureSampler, uv - float2(0.0, ring.y)).rgb;
        const float3 blurSampleRD0 = sourceTexture.sample(textureSampler, uv + float2(ring.x, ring.y)).rgb;
        const float3 blurSampleRD1 = sourceTexture.sample(textureSampler, uv + float2(-ring.x, ring.y)).rgb;
        const float3 blurSampleRD2 = sourceTexture.sample(textureSampler, uv + float2(ring.x, -ring.y)).rgb;
        const float3 blurSampleRD3 = sourceTexture.sample(textureSampler, uv + float2(-ring.x, -ring.y)).rgb;
        blurAccum += (blurSampleR0 + blurSampleR1 + blurSampleR2 + blurSampleR3) * 0.36;
        blurAccum += (blurSampleRD0 + blurSampleRD1 + blurSampleRD2 + blurSampleRD3) * 0.22;
        blurWeight += 2.32;
    }

    const float3 blurColor = blurAccum / max(blurWeight, 0.0001);

    float dimFactor = uniforms.dimAlpha;
    if (uniforms.hasFocus == 1) {
        const float2 minPoint = uniforms.focusRect.xy;
        const float2 maxPoint = uniforms.focusRect.xy + uniforms.focusRect.zw;
        const float feather = max(uniforms.feather, 0.0001);
        const float xMask = smoothstep(minPoint.x - feather, minPoint.x + feather, in.texCoord.x) *
            (1.0 - smoothstep(maxPoint.x - feather, maxPoint.x + feather, in.texCoord.x));
        const float yMask = smoothstep(minPoint.y - feather, minPoint.y + feather, in.texCoord.y) *
            (1.0 - smoothstep(maxPoint.y - feather, maxPoint.y + feather, in.texCoord.y));
        const float focusMask = clamp(xMask * yMask, 0.0, 1.0);
        dimFactor *= (1.0 - focusMask);
    }

    const float blurMix = clamp(dimFactor * uniforms.blurStrength, 0.0, 0.82);
    const float3 compositedBase = mix(baseColor.rgb, blurColor, blurMix);
    const float tintMix = clamp(dimFactor * uniforms.tintColor.a, 0.0, 1.0);
    const float3 tinted = mix(compositedBase, uniforms.tintColor.rgb, tintMix);
    return float4(tinted, 1.0);
}
"""
