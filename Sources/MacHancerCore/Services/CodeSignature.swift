import Foundation
import Security

/// The app's own code signature, read at runtime.
///
/// This exists because TCC keys an Accessibility grant to a *code requirement*, not to
/// a bundle identifier. For an ad-hoc signature that requirement is the `cdhash`, which
/// changes on every single compile — so a grant made against one build is silently
/// rejected for the next one while System Settings still shows the checkbox ticked.
/// tccd reports it as "Failed to match existing code requirement" and the app just
/// looks broken. Knowing our own hash and whether we are ad-hoc signed is what lets us
/// explain that instead of leaving the user to guess.
public enum CodeSignature {

    /// Signing identity name, e.g. "MacHancer Dev". `nil` for an ad-hoc signature,
    /// which carries no certificate at all.
    public static var authority: String? {
        guard
            let info = signingInformation(),
            let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { return nil }

        var name: CFString?
        guard SecCertificateCopyCommonName(leaf, &name) == errSecSuccess else { return nil }
        return name as String?
    }

    /// Ad-hoc signed, i.e. the grant will not survive the next rebuild.
    public static var isAdHoc: Bool { authority == nil }

    /// The unique identifier TCC matches against — `codesign -dv --verbose=4` prints the
    /// same value as `CDHash`.
    public static var cdHash: String? {
        guard
            let info = signingInformation(),
            let unique = info[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// Enough of the hash to compare two builds by eye, which is all it is ever used for.
    public static func shortHash(_ hash: String?) -> String {
        guard let hash, !hash.isEmpty else { return "unknown" }
        return String(hash.prefix(8))
    }

    public static var summary: String {
        let hash = shortHash(cdHash)
        if let authority {
            return "signed as “\(authority)” (cdhash \(hash)) — the Accessibility grant "
                 + "survives rebuilds"
        }
        return "ad-hoc signed (cdhash \(hash)) — the Accessibility grant is tied to this "
             + "exact binary and will stop applying the next time the app is rebuilt"
    }

    /// Read once, for the life of the process.
    ///
    /// `SecCodeCopySigningInformation` is not cheap — it reaches into the bundle and
    /// reads the signature — and every property here was calling it fresh on each
    /// access. The settings window's one-second poll asks for `cdHash` on every tick,
    /// so this was a full signature read per second for as long as the window was open,
    /// and it was the app's largest single CPU cost. A running process cannot change
    /// its own signature, so once is right and once a second was never buying anything.
    ///
    /// `nil` is cached as readily as a value: an unsigned or unreadable binary stays
    /// unreadable, and retrying it every second would be the same waste for no answer.
    private static let cachedSigningInformation: [String: Any]? = readSigningInformation()

    private static func signingInformation() -> [String: Any]? { cachedSigningInformation }

    private static func readSigningInformation() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess
        else { return nil }

        return info as? [String: Any]
    }
}
