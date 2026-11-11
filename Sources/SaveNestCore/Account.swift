import Foundation

public struct SaveNestAccount: Codable, Equatable {
    public struct User: Codable, Equatable {
        public let id: String
        public let name: String
        public let email: String
        public init(id: String, name: String, email: String) { self.id = id; self.name = name; self.email = email }
    }
    public struct Subscription: Codable, Equatable {
        public let active: Bool
        public let plan: String?
        public let status: String
        public let mode: String
        /// Stripe's billing-period end, in Unix seconds.
        public let renewsAt: Double?
        public let cancelAtPeriodEnd: Bool
        /// Old or unavailable backends must not expose a new checkout action.
        public let billingReady: Bool
        public init(active: Bool, plan: String?, status: String, mode: String, renewsAt: Double?, cancelAtPeriodEnd: Bool = false, billingReady: Bool = false) {
            self.active = active; self.plan = plan; self.status = status; self.mode = mode; self.renewsAt = renewsAt; self.cancelAtPeriodEnd = cancelAtPeriodEnd; self.billingReady = billingReady
        }
        enum CodingKeys: String, CodingKey { case active, plan, status, mode, renewsAt, cancelAtPeriodEnd, billingReady }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            active = try values.decode(Bool.self, forKey: .active)
            plan = try values.decodeIfPresent(String.self, forKey: .plan)
            status = try values.decode(String.self, forKey: .status)
            mode = try values.decode(String.self, forKey: .mode)
            renewsAt = try values.decodeIfPresent(Double.self, forKey: .renewsAt)
            cancelAtPeriodEnd = try values.decodeIfPresent(Bool.self, forKey: .cancelAtPeriodEnd) ?? false
            billingReady = try values.decodeIfPresent(Bool.self, forKey: .billingReady) ?? false
        }
    }
    public let user: User
    public let subscription: Subscription
    public init(user: User, subscription: Subscription) { self.user = user; self.subscription = subscription }
}

public enum AccountAccess {
    /// Server account data can still describe a current paid subscription even when
    /// its short in-memory verification lease has expired.
    public static func hasCurrentSubscription(_ account: SaveNestAccount?, now: Date = Date()) -> Bool {
        guard let account,
              account.subscription.active, ["active", "trialing"].contains(account.subscription.status),
              ["sandbox", "live"].contains(account.subscription.mode),
              ["monthly", "yearly"].contains(account.subscription.plan ?? ""),
              let periodEnd = account.subscription.renewsAt, periodEnd > now.timeIntervalSince1970 else { return false }
        return true
    }

    /// Historical billing status requires recent server verification. Local library features do not use this check.
    /// No subscription entitlement is persisted to disk.
    public static let maximumAge: TimeInterval = 120
    public static func hasVerifiedSubscription(_ account: SaveNestAccount?, verifiedAt: Date?, now: Date = Date()) -> Bool {
        guard let verifiedAt, now >= verifiedAt,
              now.timeIntervalSince(verifiedAt) < maximumAge else { return false }
        return hasCurrentSubscription(account, now: now)
    }

    /// Stripe can have an existing subscription whose price does not grant Pro.
    /// Recover or manage that record instead of creating a second subscription.
    public static func blocksNewCheckout(_ account: SaveNestAccount?) -> Bool {
        guard let account else { return false }
        return ["active", "past_due", "unpaid", "paused", "trialing", "incomplete"].contains(account.subscription.status)
    }
    public static func canManageBilling(_ account: SaveNestAccount?) -> Bool {
        guard let account else { return false }
        return account.subscription.plan != nil || ["active", "past_due", "unpaid", "paused", "trialing", "incomplete", "canceled", "incomplete_expired", "unavailable"].contains(account.subscription.status)
    }

    /// The callback must match this auth attempt exactly; reject duplicate query keys and other URL forms.
    public static func callbackCode(_ url: URL, expectedState: String) -> String? {
        guard let values = NativeCallback.parameters(url, host: "auth", path: "/callback", keys: ["code", "state"]),
              values["state"] == expectedState, let code = values["code"],
              NativeCallback.isNonce(code), NativeCallback.isNonce(expectedState) else { return nil }
        return code
    }

    /// Referral links are deliberately small and contain no email address or account data.
    public static func referralCode(_ url: URL) -> String? {
        guard let values = NativeCallback.parameters(url, host: "invite", path: "/redeem", keys: ["code"]),
              let raw = values["code"] else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.range(of: #"^SN[A-Z0-9]{8}$"#, options: .regularExpression) != nil else { return nil }
        return code
    }
}

public struct PendingEmailSignIn: Codable, Equatable {
    public let id: UUID
    public let verifier: String
    public let state: String
    public let email: String
    public let name: String
    public let createdAt: Date
    public let expiresAt: Date
    public private(set) var consumed: Bool
    public init(verifier: String, state: String, email: String, name: String, now: Date = Date()) {
        id = UUID(); self.verifier = verifier; self.state = state; self.email = email; self.name = name
        createdAt = now; expiresAt = now.addingTimeInterval(900); consumed = false
    }
    public func isValid(at now: Date = Date()) -> Bool {
        now >= createdAt && now < expiresAt && expiresAt.timeIntervalSince(createdAt) == 900 &&
        NativeCallback.isNonce(verifier) && NativeCallback.isNonce(state) && NativeCallback.normalizedEmail(email) == email
    }
    public mutating func consume(_ url: URL, now: Date = Date()) -> String? {
        guard !consumed, isValid(at: now), let code = AccountAccess.callbackCode(url, expectedState: state) else { return nil }
        consumed = true; return code
    }
}

public enum NativeBillingFlow: String, Codable { case checkout, billing }
public enum NativeBillingStatus: String, Codable { case success, cancelled, returned }
public struct NativeBillingReturn: Equatable {
    public let flow: NativeBillingFlow
    public let status: NativeBillingStatus
    public init(flow: NativeBillingFlow, status: NativeBillingStatus) {
        self.flow = flow
        self.status = status
    }
}

public struct PendingBillingReturn: Codable, Equatable {
    public let id: UUID
    public let state: String
    public let userID: String
    public let flow: NativeBillingFlow
    public let createdAt: Date
    public let expiresAt: Date
    public private(set) var consumed: Bool
    public init(state: String, userID: String, flow: NativeBillingFlow, now: Date = Date()) {
        id = UUID(); self.state = state; self.userID = userID; self.flow = flow
        createdAt = now; expiresAt = now.addingTimeInterval(24 * 3600); consumed = false
    }
    public func isValid(at now: Date = Date()) -> Bool {
        now >= createdAt && now < expiresAt && expiresAt.timeIntervalSince(createdAt) == 24 * 3600 &&
        NativeCallback.isNonce(state) && !userID.isEmpty
    }
    public mutating func consume(_ url: URL, userID: String, now: Date = Date()) -> NativeBillingReturn? {
        guard !consumed, isValid(at: now), self.userID == userID,
              let values = NativeCallback.parameters(url, host: "billing", path: "/return", keys: ["flow", "status", "state"]),
              values["state"] == state, values["flow"] == flow.rawValue,
              let status = NativeBillingStatus(rawValue: values["status"] ?? ""),
              (flow == .checkout && (status == .success || status == .cancelled)) || (flow == .billing && status == .returned) else { return nil }
        consumed = true; return NativeBillingReturn(flow: flow, status: status)
    }
}

public enum NativeCallback {
    public static func isNonce(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    public static func normalizedEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.count <= 254, !email.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { return nil }
        return email
    }
    public static func parameters(_ url: URL, host: String, path: String, keys: Set<String>) -> [String: String]? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "savenest", components.host == host, components.percentEncodedPath == path,
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == keys.count, Set(items.map(\.name)) == keys,
              items.allSatisfy({ $0.value != nil }) else { return nil }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
    }
}
