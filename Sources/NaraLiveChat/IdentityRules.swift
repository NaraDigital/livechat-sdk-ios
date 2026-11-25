import Foundation

/// Pure identity / prechat-form rules (user data and the prechat form).
/// Same decision table as the Android SDK — full parity.
public enum IdentityRules {

    static let emailRegex = try! NSRegularExpression(pattern: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")

    /// Spec: an invalid email from the app is treated as empty — the form asks for it if required.
    public static func sanitizeEmail(_ email: String?) -> String? {
        guard let e = email?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty else { return nil }
        let range = NSRange(e.startIndex..., in: e)
        guard emailRegex.firstMatch(in: e, options: [], range: range) != nil else { return nil }
        return e
    }

    public static func sanitizeName(_ name: String?) -> String? {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (n?.isEmpty == false) ? n : nil
    }

    /// Which prechat fields must the form still collect. Empty list => skip the form.
    public static func missingPrechatFields(
        formEnabled: Bool,
        requireName: Bool,
        requireEmail: Bool,
        suppliedName: String?,
        suppliedEmail: String?
    ) -> [String] {
        guard formEnabled else { return [] }
        var missing: [String] = []
        if requireName && suppliedName == nil { missing.append("name") }
        if requireEmail && suppliedEmail == nil { missing.append("email") }
        return missing
    }

    public enum Identity: Equatable {
        case login(userId: String, userHash: String, name: String?, email: String?)
        case setUser(name: String?, email: String?)
        case anonymous
    }

    /// - `login` with hash → verified identity, cross-device history
    /// - `setUser` / `login` without hash → unverified, per-device history, form still skipped
    /// - neither → anonymous
    public static func decideIdentity(
        loginUserId: String?,
        loginUserHash: String?,
        loginName: String?,
        loginEmail: String?,
        setUser: (name: String?, email: String?)?
    ) -> Identity {
        let name = sanitizeName(loginName ?? setUser?.name)
        let email = sanitizeEmail(loginEmail ?? setUser?.email)
        let uid = loginUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hash = loginUserHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !uid.isEmpty && !hash.isEmpty {
            return .login(userId: uid, userHash: hash, name: name, email: email)
        }
        let hasUserData = setUser != nil || name != nil || email != nil
        return hasUserData ? .setUser(name: name, email: email) : .anonymous
    }
}

/// Semantic-version gate for `sdk.minSupportedVersion` (free-form `a.b.c`, compared numerically).
public enum VersionCheck {

    public static func parse(_ v: String?) -> [Int]? {
        guard let v, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let parts = v.trimmingCharacters(in: .whitespaces).split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        var nums = parts.compactMap { $0 }
        while nums.count < 4 { nums.append(0) }
        return nums
    }

    /// a < b (missing parts count as 0: "1.2" == "1.2.0"). Nil/garbage never blocks.
    public static func lessThan(_ a: String?, _ b: String?) -> Bool {
        guard let pa = parse(a), let pb = parse(b) else { return false }
        for i in 0..<4 where pa[i] != pb[i] { return pa[i] < pb[i] }
        return false
    }
}
