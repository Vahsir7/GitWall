import Foundation
import Security

/// Token lives in the login keychain, never in UserDefaults.
enum TokenStore {
    private static let service = "com.gitwall.token"
    private static let account = "github"

    static func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Fall back to whatever `gh` is already logged in with.
    static func fromGHCLI() -> String? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["auth", "token"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, let t, !t.isEmpty { return t }
        }
        return nil
    }
}
