import AppKit
import SwiftUI

/// Modernized onboarding surface that mirrors the frosted preferences chrome.
struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                header
                stepContent
                progressIndicators
                actionBar
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 30)
            .padding(.top, 34)
        }
        .frame(width: 520, height: 360)
        .background(
            GlassyBackgroundView(material: .hudWindow, cornerRadius: 28)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            windowControls
        }
        .shadow(color: Color.black.opacity(0.25), radius: 26, x: 0, y: 18)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("Focusly Onboarding"))
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundColor(.secondary)
                Text(localized("Quick setup"))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
            }
            Spacer()
            Button {
                viewModel.cancel()
            } label: {
                Text(localized("Close"))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var stepContent: some View {
        HStack(alignment: .top, spacing: 18) {
            if let symbol = viewModel.currentStep.systemImageName {
                stepIcon(systemName: symbol)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.currentStep.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text(viewModel.currentStep.message)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func stepIcon(systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.28),
                            Color.accentColor.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 72, height: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )

            Image(systemName: systemName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.accentColor)
        }
    }

    private var progressIndicators: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.steps) { step in
                Capsule()
                    .fill(step.id == viewModel.currentStep.id ? Color.accentColor : Color.white.opacity(0.18))
                    .frame(width: step.id == viewModel.currentStep.id ? 32 : 12, height: 4)
                    .animation(.easeOut(duration: 0.2), value: viewModel.currentStep.id)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            Button {
                viewModel.retreat()
            } label: {
                Text(localized("Back"))
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 22)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isFirstStep)
            .opacity(viewModel.isFirstStep ? 0.4 : 1)

            Spacer()

            Button {
                viewModel.advance()
            } label: {
                HStack(spacing: 8) {
                    Text(localized(viewModel.isLastStep ? "Get Started" : "Next"))
                        .font(.system(size: 14, weight: .bold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 24)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor,
                                    Color.accentColor.opacity(0.85)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var windowControls: some View {
        HStack(spacing: 8) {
            ForEach(WindowChromeDot.allCases, id: \.self) { dot in
                Circle()
                    .fill(dot.color)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            }
            Spacer()
        }
        .padding(.top, 18)
        .padding(.leading, 28)
    }

    /// Convenience wrapper so the view can access the localization service.
    private func localized(_ key: String) -> String {
        localization.localized(key, fallback: key)
    }
}

private enum WindowChromeDot: CaseIterable {
    case close, minimize, zoom

    var color: Color {
        switch self {
        case .close:
            return Color(red: 1.0, green: 0.37, blue: 0.34)
        case .minimize:
            return Color(red: 1.0, green: 0.78, blue: 0.0)
        case .zoom:
            return Color(red: 0.19, green: 0.81, blue: 0.29)
        }
    }
}

private struct GlassyBackgroundView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        view.blendingMode = .behindWindow
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.state = .active
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.masksToBounds = true
    }
}
