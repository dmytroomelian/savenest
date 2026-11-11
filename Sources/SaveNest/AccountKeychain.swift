import Foundation
import Security
import Darwin
import SaveNestCore

/// The lock contains no credentials. It serializes Keychain updates across installed app copies.
/// A consumed attempt remains in Keychain until the exchange finishes so cancellation/sign-out
/// in another copy can prevent its result from installing a new login.
enum AccountKeychain {
    private static func locked<T>(_ operation: () throws -> T) throws -> T {
        let directory = AppRuntime.supportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(directory.appendingPathComponent("account.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AccountFailure.keychain }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AccountFailure.accountBusy }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
    private static func query(_ item: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AppRuntime.keychainService, kSecAttrAccount as String: item]
    }
    private static func data(_ item: String) throws -> Data? {
        var request = query(item); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result = value as? Data else { throw AccountFailure.keychain }
        return result
    }
    private static func write(_ item: String, _ data: Data) throws {
        let attributes = [kSecValueData as String: data] as [String: Any]
        let status = SecItemUpdate(query(item) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(item); request.merge(attributes) { _, new in new }
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw AccountFailure.keychain }
        } else if status != errSecSuccess { throw AccountFailure.keychain }
    }
    private static func delete(_ item: String) throws {
        let status = SecItemDelete(query(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountFailure.keychain }
    }
    private static func decode<T: Decodable>(_ type: T.Type, item: String) throws -> T? {
        guard let bytes = try data(item) else { return nil }
        guard let value = try? JSONDecoder().decode(type, from: bytes) else { try delete(item); return nil }
        return value
    }
    private static func pendingSignIn() throws -> PendingEmailSignIn? {
        guard let value = try decode(PendingEmailSignIn.self, item: "pending-sign-in") else { return nil }
        guard value.isValid() else { try delete("pending-sign-in"); return nil }
        return value
    }
    static func token() throws -> String? {
        try locked {
            guard let bytes = try data("access-token"), let value = String(data: bytes, encoding: .utf8), !value.isEmpty else { return nil }
            return value
        }
    }
    static func pending() throws -> PendingEmailSignIn? { try locked { try pendingSignIn() } }
    static func save(_ pending: PendingEmailSignIn) throws {
        try locked { guard pending.isValid() && !pending.consumed else { throw AccountFailure.callback }; try write("pending-sign-in", JSONEncoder().encode(pending)) }
    }
    static func claimSignIn(_ url: URL, currentEmail: String?) throws -> (PendingEmailSignIn, String)? {
        try locked {
            guard var value = try pendingSignIn(), currentEmail == nil || currentEmail?.lowercased() == value.email,
                  let code = value.consume(url) else { return nil }
            try write("pending-sign-in", JSONEncoder().encode(value)); return (value, code)
        }
    }
    static func completeSignIn(_ pending: PendingEmailSignIn, token: String) throws -> Bool {
        try locked {
            guard let current = try pendingSignIn(), current.id == pending.id, current.consumed else { return false }
            try write("access-token", Data(token.utf8)); try delete("pending-sign-in"); return true
        }
    }
    static func cancelSignIn(id: UUID?) throws {
        try locked { if let value = try pendingSignIn(), value.id == id { try delete("pending-sign-in") } }
    }
    static func clearToken(ifMatches token: String) throws {
        try locked { if let bytes = try data("access-token"), String(data: bytes, encoding: .utf8) == token { try delete("access-token") } }
    }
    static func signOut(token: String?) throws {
        try locked {
            if let bytes = try data("access-token"), String(data: bytes, encoding: .utf8) == token { try delete("access-token") }
            try delete("pending-sign-in"); try delete("pending-billing-return")
        }
    }
    private static func pendingBilling() throws -> PendingBillingReturn? {
        guard let value = try decode(PendingBillingReturn.self, item: "pending-billing-return") else { return nil }
        guard value.isValid(), !value.consumed else { try delete("pending-billing-return"); return nil }
        return value
    }
    static func billing() throws -> PendingBillingReturn? { try locked { try pendingBilling() } }
    static func saveBilling(_ value: PendingBillingReturn) throws {
        try locked {
            guard value.isValid(), !value.consumed else { throw AccountFailure.callback }
            guard try pendingBilling() == nil else { throw AccountFailure.service("A checkout or billing page is already open. Finish it, or stop waiting in Account first.") }
            try write("pending-billing-return", JSONEncoder().encode(value))
        }
    }
    static func claimBilling(_ url: URL, userID: String) throws -> NativeBillingReturn? {
        try locked {
            guard var value = try pendingBilling(), let result = value.consume(url, userID: userID) else { return nil }
            try delete("pending-billing-return"); return result
        }
    }
    static func cancelBilling(id: UUID?) throws {
        try locked { if let value = try pendingBilling(), value.id == id { try delete("pending-billing-return") } }
    }
}
