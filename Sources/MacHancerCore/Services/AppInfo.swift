import Foundation

/// Version and build identity, read from the bundle rather than hard-coded.
///
/// Hard-coding a version string in Swift means two places to update and one of them is
/// always forgotten. `build.sh` writes the build number into `Info.plist`; this reads it
/// back, so the number shown in the UI is by construction the one that was built.
public enum AppInfo {
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// "1.0.0 (42)" — what belongs in an About box and a bug report.
    public static var versionString: String { "\(version) (\(build))" }

    public static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "MacHancer"
    }

    /// Short summary of the environment, for pasting into a bug report. The two things
    /// that have actually mattered when diagnosing this app are the macOS build and
    /// whether the signature is ad-hoc, since both change how it behaves.
    public static var supportSummary: String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(name) \(versionString)\n\(os)"
    }
}
