import Foundation

public enum SensitivePathPolicy {
    public static func isSensitive(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.lowercased().split(separator: "/").map(String.init)
        if components.contains(".git") || components.contains(".ssh") { return true }
        guard let last = components.last?.lowercased() else { return false }
        if last == ".env" || last.hasPrefix(".env.") { return true }
        if [".p8", ".p12", ".pfx", ".pem", ".key", ".mobileprovision", ".keystore"].contains(where: last.hasSuffix) { return true }
        if ["id_rsa", "id_ed25519", "id_ecdsa", "credentials", ".netrc", ".npmrc"].contains(last) { return true }
        return false
    }
}
