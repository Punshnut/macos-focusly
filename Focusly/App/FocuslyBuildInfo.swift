/// Compile-time constants that expose app build metadata.
enum FocuslyBuildInfo {
    static let marketingVersion = "v0.3.1a"
    static let developerName = "Jan Feuerbacher"
    static let developerOrganization = "Punshnut"

    static var developerSummary: String {
        "\(developerName)\n\(developerOrganization)"
    }
}
