import AppKit
import CryptoKit
import SaveNestCore
import Security
import SwiftUI

enum AccountFailure: LocalizedError {
    case signIn, subscription, invalidResponse, callback, keychain, accountBusy, service(String)
    var errorDescription: String? {
        switch self {
        case .signIn: return "Sign in to manage this account. All local features work without signing in."
        case .subscription: return "SaveNest is free on your Mac. Cloud subscriptions are not available yet."
        case .invalidResponse: return "SaveNest couldn’t verify your account. Please try again in a moment."
        case .callback: return "This sign-in link doesn’t match your request. Start sign-in again in SaveNest."
        case .keychain: return "SaveNest couldn’t access your login in macOS Keychain. Unlock your keychain and try again."
        case .accountBusy: return "Another copy of SaveNest is updating your account. Please try again in a moment."
        case .service(let message): return message
        }
    }
}

/// Do not follow a server redirect while sending a native bearer credential.
private final class AccountTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class AccountController: NSObject, ObservableObject {
    struct ReferralSummary: Decodable {
        let eligible: Bool
        let successful: Int
        let queued: Int
        let sent: Int
        let remaining: Int
    }
    enum SignInStage { case idle, sending, waiting, verifying }
    enum BillingStage { case idle, preparing, waiting, checking }
    @Published private(set) var account: SaveNestAccount?
    @Published private(set) var isRefreshing = false
    @Published private(set) var signInStage: SignInStage = .idle
    @Published private(set) var billingStage: BillingStage = .idle
    @Published private(set) var hasLogin = false
    @Published private(set) var verifiedAt: Date?
    @Published private(set) var subscriptionUnavailable = false
    @Published private(set) var referral: ReferralSummary?
    @Published private(set) var isSendingInvite = false
    @Published private(set) var referralMessage: String?
    @Published private(set) var pendingReferralCode = UserDefaults.standard.string(forKey: "savenest.pending-referral-code")
    @Published private(set) var resendAvailableAt: Date?
    @Published var signInEmail = ""
    @Published var signInName = ""
    @Published var inviteEmail = ""
    @Published var message: String?
    var presentationWindow: (() -> NSWindow?)?
    var bringAccountForward: (() -> Void)?
    var onChange: (() -> Void)?
    private var accessToken: String?
    private var sessionGeneration = UUID()
    private var authAttempt = UUID()
    private var pendingSignIn: PendingEmailSignIn?
    private var signInRequestTask: Task<Void, Never>?
    private var pendingBilling: PendingBillingReturn?
    private var billingPoll: Task<Void, Never>?
    private var billingPollID = UUID()
    private struct RefreshFlight {
        let id: UUID
        let force: Bool
        let task: Task<SaveNestAccount, Error>
    }
    private var refreshFlight: RefreshFlight?
    private let transport = AccountTransport()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: transport, delegateQueue: nil)
    }()
    private let baseURL = AppRuntime.accountOrigin
    /// Only a trusted application bundle can choose the cloud service origin.
    /// User defaults, imported libraries, and renderer messages cannot redirect credentials.
    private var cloudBaseURL: URL {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SaveNestCloudBaseURL") as? String,
              let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return baseURL }
        return url
    }
    var cloudSessionID: UUID { sessionGeneration }

    /// Native credentials never leave this controller or cross the Electron bridge.
    func cloudRequest<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        guard path == "api/cloud/status" || path == "api/cloud/snapshots"
                || (path.hasPrefix("api/cloud/snapshots/") && UUID(uuidString: String(path.dropFirst("api/cloud/snapshots/".count))) != nil),
              let token = accessToken, let user = account?.user.id else { throw AccountFailure.signIn }
        let generation = sessionGeneration
        var request = URLRequest(url: cloudBaseURL.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            guard body.count <= CloudLibraryJSON.maximumBytes else { throw CloudLibraryFailure.tooLarge }
            request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard accessToken == token, sessionGeneration == generation, account?.user.id == user else {
            throw CloudLibraryFailure.accountChanged
        }
        guard let response = response as? HTTPURLResponse else { throw AccountFailure.invalidResponse }
        guard data.count <= CloudLibraryJSON.maximumBytes + 65_536 else { throw CloudLibraryFailure.tooLarge }
        if response.statusCode == 401 { throw AccountFailure.signIn }
        guard (200..<300).contains(response.statusCode) else {
            let reason = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            throw AccountFailure.service(reason.flatMap { $0.count <= 400 ? $0 : nil }
                ?? "Cloud backup is not available right now. Your local library is unchanged.")
        }
        do { return try CloudLibraryJSON.decoder().decode(T.self, from: data) }
        catch { throw AccountFailure.invalidResponse }
    }
    var isBusy: Bool { isRefreshing || billingStage == .preparing || billingStage == .checking }
    var isSigningIn: Bool { signInStage != .idle }
    var hasVerifiedSubscription: Bool { AccountAccess.hasVerifiedSubscription(account, verifiedAt: verifiedAt) }
    var isSandbox: Bool { account?.subscription.mode == "sandbox" }
    var hasExistingSubscription: Bool { AccountAccess.blocksNewCheckout(account) }
    var canManageBilling: Bool { AccountAccess.canManageBilling(account) }
    override init() {
        super.init()
        if AppRuntime.isPrivateBeta { signInEmail = "dima@omelabs.org" }
        guard !AppLaunch.isPreview else { return }
        do {
            accessToken = try AccountKeychain.token(); hasLogin = accessToken != nil
            restorePendingSignIn(try AccountKeychain.pending())
            pendingBilling = try AccountKeychain.billing()
            if pendingBilling != nil { billingStage = .waiting }
        } catch { message = error.localizedDescription }
    }
    var isUsageOwner: Bool { account?.user.email.lowercased() == "dima@omelabs.org" }
    func loadUsageReport() async throws -> UsageReport {
        guard let token = accessToken else { throw AccountFailure.signIn }
        return try await request("api/usage/report", token: token)
    }
    private struct AccountResponse: Decodable { let account: SaveNestAccount }
    private struct ExchangeResponse: Decodable { let accessToken: String; let account: SaveNestAccount }
    private struct URLResponse: Decodable { let url: URL }
    private struct ReferralResponse: Decodable { let email: String; let referral: ReferralSummary }
    private struct ReferralSummaryResponse: Decodable { let referral: ReferralSummary }
    private struct OKResponse: Decodable { let ok: Bool }
    private struct ErrorResponse: Decodable { let error: String? }
    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: String]? = nil, token: String? = nil, query: [String: String] = [:], timeout: TimeInterval = 15) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!); request.timeoutInterval = timeout
        request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AccountFailure.invalidResponse }
        if response.statusCode == 401 { throw AccountFailure.signIn }
        guard (200..<300).contains(response.statusCode) else {
            let reason = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            throw AccountFailure.service(reason.flatMap { $0.count <= 400 ? $0 : nil } ?? "SaveNest is temporarily unavailable. Try again shortly.")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw AccountFailure.invalidResponse }
    }
    @discardableResult func refresh(force: Bool = false, timeout: TimeInterval = 15) async -> Bool {
        guard let token = accessToken else { account = nil; verifiedAt = nil; onChange?(); return false }
        let generation = sessionGeneration
        if force, let existing = refreshFlight, !existing.force {
            _ = await refresh()
            guard accessToken == token, sessionGeneration == generation else { return false }
        }
        let flight: RefreshFlight
        if let existing = refreshFlight { flight = existing }
        else {
            flight = RefreshFlight(id: UUID(), force: force, task: Task {
                let result: AccountResponse = try await request("api/account", token: token, query: force ? ["refresh": "1"] : [:], timeout: timeout)
                return result.account
            })
            refreshFlight = flight; isRefreshing = true
        }
        defer { if refreshFlight?.id == flight.id { refreshFlight = nil; isRefreshing = false; onChange?() } }
        do {
            let value = try await flight.task.value
            guard accessToken == token, sessionGeneration == generation else { return false }
            guard refreshFlight?.id == flight.id else { return hasVerifiedSubscription }
            applyAccount(value); return hasVerifiedSubscription
        } catch {
            guard accessToken == token, sessionGeneration == generation, refreshFlight?.id == flight.id else { return false }
            verifiedAt = nil
            if case AccountFailure.signIn = error {
                try? AccountKeychain.clearToken(ifMatches: token); clearLocalLogin()
            } else { subscriptionUnavailable = true }
            if !(error is CancellationError) { message = friendly(error) }
            return false
        }
    }
    private func applyAccount(_ value: SaveNestAccount) {
        if value.subscription.status == "unavailable" {
            let previous = account?.user.id == value.user.id ? account?.subscription : nil
            account = SaveNestAccount(user: value.user, subscription: previous ?? value.subscription)
            verifiedAt = nil; subscriptionUnavailable = true
            message = "We couldn’t check your subscription right now. Try Refresh account again. All local features remain available."
        } else {
            account = value; verifiedAt = Date(); subscriptionUnavailable = false; message = nil
            if value.subscription.active, pendingReferralCode != nil { clearReferralCode() }
        }
        Task { await loadReferrals() }
    }

    func loadReferrals() async {
        guard let token = accessToken, account != nil else { referral = nil; return }
        do {
            let result: ReferralSummaryResponse = try await request("api/referrals", token: token)
            guard accessToken == token else { return }
            referral = result.referral
        } catch {
            guard accessToken == token else { return }
            referral = nil
        }
    }

    func sendReferralInvite() async {
        referralMessage = "Paid referral offers are paused. SaveNest is free on your Mac."
    }

    func clearReferralCode() {
        pendingReferralCode = nil
        UserDefaults.standard.removeObject(forKey: "savenest.pending-referral-code")
    }

    private func restorePendingSignIn(_ value: PendingEmailSignIn?) {
        guard let value else { return }
        pendingSignIn = value; authAttempt = value.id
        signInEmail = value.email; signInName = value.name
        signInStage = value.consumed ? .verifying : .waiting
    }
    func sendSignInEmail() {
        guard !hasLogin, signInStage != .sending, signInStage != .verifying else { return }
        guard let email = NativeCallback.normalizedEmail(signInEmail) else { message = "Enter a valid email address."; return }
        if let date = resendAvailableAt, date > Date() { return }
        do {
            let name = String(signInName.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            let attempt: PendingEmailSignIn
            if let existing = pendingSignIn, existing.email == email, existing.isValid(), !existing.consumed,
               try AccountKeychain.pending()?.id == existing.id { attempt = existing }
            else {
                attempt = PendingEmailSignIn(verifier: try randomSecret(), state: try randomSecret(), email: email, name: name)
                try AccountKeychain.save(attempt)
            }
            pendingSignIn = attempt; authAttempt = attempt.id; signInEmail = email
            signInStage = .sending; message = nil
            signInRequestTask?.cancel()
            signInRequestTask = Task { @MainActor in
                do {
                    let challenge = Data(SHA256.hash(data: Data(attempt.verifier.utf8))).base64URL
                    let result: OKResponse = try await request("api/auth/native/request", method: "POST", body: ["email": email, "name": attempt.name, "client": "mac", "challenge": challenge, "state": attempt.state])
                    guard result.ok else { throw AccountFailure.invalidResponse }
                    guard authAttempt == attempt.id, pendingSignIn?.id == attempt.id, signInStage == .sending else { return }
                    guard let stored = try AccountKeychain.pending(), stored.id == attempt.id, !stored.consumed else { await synchronizeLogin(); return }
                    signInStage = .waiting; resendAvailableAt = Date().addingTimeInterval(30)
                    message = "Open the sign-in email on this Mac. SaveNest will finish signing you in automatically."
                } catch {
                    guard authAttempt == attempt.id, signInStage == .sending else { return }
                    // Keep the attempt: a timed-out request may still have delivered the email.
                    signInStage = .waiting; resendAvailableAt = nil; message = friendly(error)
                }
            }
        } catch { message = friendly(error) }
    }
    func cancelSignIn() {
        let id = pendingSignIn?.id
        authAttempt = UUID(); signInRequestTask?.cancel(); signInRequestTask = nil
        pendingSignIn = nil; signInStage = .idle; resendAvailableAt = nil; message = nil
        do { try AccountKeychain.cancelSignIn(id: id) } catch { message = friendly(error) }
    }
    func handleIncomingURL(_ receivedURL: URL) {
        guard let url = AppRuntime.canonicalCallback(receivedURL) else { return }
        if AccountAccess.referralCode(url) != nil {
            clearReferralCode()
            message = "SaveNest is now free on your Mac. Paid referral offers are paused while Cloud is being developed."
            showAccount(); return
        }
        guard url.scheme == "savenest", ["auth", "billing"].contains(url.host ?? "") else { return }
        Task { @MainActor in
            await synchronizeLogin(refreshExisting: false)
            if url.host == "auth" { await finishSignIn(url) }
            else { await finishBilling(url) }
        }
    }
    private func finishSignIn(_ url: URL) async {
        do {
            if hasLogin && account == nil {
                _ = await refresh()
                guard !hasLogin || account != nil else { message = "Check your current account first, then open this sign-in link again."; showAccount(); return }
            }
            guard let (attempt, code) = try AccountKeychain.claimSignIn(url, currentEmail: account?.user.email) else {
                message = "This sign-in link expired, was already used, or belongs to another account. Request a fresh link here if you still need to sign in."
                showAccount(); return
            }
            authAttempt = attempt.id; pendingSignIn = attempt; signInEmail = attempt.email; signInName = attempt.name
            signInRequestTask?.cancel(); signInStage = .verifying; message = "Signing you in…"; showAccount()
            defer { if authAttempt == attempt.id { signInStage = .idle; pendingSignIn = nil; onChange?() } }
            do {
                let response: ExchangeResponse = try await request("api/auth/exchange", method: "POST", body: ["code": code, "verifier": attempt.verifier, "state": attempt.state])
                guard NativeCallback.isNonce(response.accessToken), response.account.user.email.lowercased() == attempt.email else { throw AccountFailure.invalidResponse }
                guard authAttempt == attempt.id else { revoke(response.accessToken); return }
                do {
                    guard try AccountKeychain.completeSignIn(attempt, token: response.accessToken) else { revoke(response.accessToken); message = "Sign-in was cancelled in another copy of SaveNest. Send a fresh link to continue."; return }
                } catch { revoke(response.accessToken); throw error }
                sessionGeneration = UUID(); refreshFlight?.task.cancel(); refreshFlight = nil; isRefreshing = false
                accessToken = response.accessToken; hasLogin = true; applyAccount(response.account)
                showAccount()
            } catch {
                try? AccountKeychain.cancelSignIn(id: attempt.id)
                if authAttempt == attempt.id { message = friendly(error) }
            }
        } catch { message = friendly(error); showAccount() }
    }
    /// A second installed copy may receive the callback. Adopt only a verified shared login,
    /// and never silently replace an already-known signed-in account with a different user.
    func synchronizeLogin(refreshExisting: Bool = true) async {
        let generation = sessionGeneration, previousToken = accessToken
        do {
            let sharedToken = try AccountKeychain.token()
            if sharedToken == previousToken {
                if refreshExisting && hasLogin && billingStage != .checking && billingPoll == nil { _ = await refresh(force: true) }
            } else if let sharedToken {
                let response: AccountResponse = try await request("api/account", token: sharedToken)
                guard sessionGeneration == generation, accessToken == previousToken, try AccountKeychain.token() == sharedToken else { return }
                if previousToken != nil, account?.user.id != response.account.user.id {
                    message = "Another copy of SaveNest signed in to a different account. Sign out here before switching."; return
                }
                sessionGeneration = UUID(); accessToken = sharedToken; hasLogin = true
                refreshFlight?.task.cancel(); refreshFlight = nil; isRefreshing = false
                applyAccount(response.account); signInStage = .idle; pendingSignIn = nil
            } else if previousToken != nil {
                clearLocalLogin(); message = "You signed out in another copy of SaveNest."
            }
            if !hasLogin, signInStage != .sending {
                let stored = try AccountKeychain.pending()
                if let stored { restorePendingSignIn(stored) }
                else if signInStage == .waiting || signInStage == .verifying { pendingSignIn = nil; signInStage = .idle }
            }
            if billingStage != .preparing && billingStage != .checking && billingPoll == nil {
                let stored = try AccountKeychain.billing()
                if let stored, stored.userID == account?.user.id, let token = accessToken {
                    pendingBilling = stored
                    startAccessCheck(nil, token: token, pendingID: stored.id)
                }
                else { pendingBilling = nil; billingStage = .idle }
            }
            onChange?()
        } catch { if sessionGeneration == generation { message = friendly(error) } }
    }
    func checkout(plan: String) async {
        guard ["monthly", "yearly"].contains(plan) else { return }
        guard hasLogin else { message = "Sign in before choosing a Cloud plan."; showAccount(); return }
        _ = await refresh(force: true)
        guard !subscriptionUnavailable, account?.subscription.billingReady == true else {
            message = "Cloud checkout is temporarily unavailable. Try Refresh account again."; return
        }
        guard !hasExistingSubscription else {
            message = "You already have a subscription. Use Manage subscription to update it."; return
        }
        await startBilling(flow: .checkout, plan: plan)
    }
    func openBilling() async { await startBilling(flow: .billing, plan: nil) }
    private func startBilling(flow: NativeBillingFlow, plan: String?) async {
        guard billingStage == .idle, let token = accessToken, let userID = account?.user.id else { return }
        let generation = sessionGeneration
        billingStage = .preparing; message = nil
        var created: PendingBillingReturn?
        do {
            let attempt = PendingBillingReturn(state: try randomSecret(), userID: userID, flow: flow)
            try AccountKeychain.saveBilling(attempt); pendingBilling = attempt; created = attempt
            var body = ["client": "mac", "state": attempt.state]
            if let plan { body["plan"] = plan }
            if flow == .checkout, plan == "monthly", let pendingReferralCode { body["referralCode"] = pendingReferralCode }
            let result: URLResponse = try await request(flow == .checkout ? "api/billing/checkout" : "api/billing/portal", method: "POST", body: body, token: token)
            guard sessionGeneration == generation, accessToken == token, pendingBilling?.id == attempt.id else { return }
            guard try AccountKeychain.billing()?.id == attempt.id else { pendingBilling = nil; billingStage = .idle; message = "This billing request was cancelled in another copy of SaveNest."; return }
            let host = flow == .checkout ? "checkout.stripe.com" : "billing.stripe.com"
            guard result.url.scheme == "https", result.url.host == host, result.url.user == nil, result.url.password == nil,
                  result.url.port == nil || result.url.port == 443 else { throw AccountFailure.invalidResponse }
            guard NSWorkspace.shared.open(result.url) else { throw AccountFailure.service("Your browser couldn’t open Stripe. Check your default browser, then try again.") }
            startAccessCheck(nil, token: token, pendingID: attempt.id)
            message = flow == .checkout ? "Finish payment in Stripe. Your access will update automatically." : "Make your changes in Stripe, then return to SaveNest."
        } catch {
            if let created { try? AccountKeychain.cancelBilling(id: created.id) }
            guard sessionGeneration == generation else { return }
            pendingBilling = nil; billingStage = .idle; message = friendly(error)
            if let existing = try? AccountKeychain.billing(), existing.userID == userID { pendingBilling = existing; billingStage = .waiting }
        }
    }
    private func finishBilling(_ url: URL) async {
        if account == nil && hasLogin { _ = await refresh(force: true) }
        guard let userID = account?.user.id, let token = accessToken else { message = "Sign in to the account you used for payment, then refresh your account here."; showAccount(); return }
        do {
            guard let result = try AccountKeychain.claimBilling(url, userID: userID) else {
                message = hasVerifiedSubscription ? "Your Cloud subscription is active. Turn on backups when you’re ready." : "This billing return has expired, was already used, or belongs to another account. You can refresh your account here safely."
                showAccount(); return
            }
            pendingBilling = nil; startAccessCheck(result, token: token); showAccount()
        } catch { message = friendly(error); showAccount() }
    }
    private func startAccessCheck(_ returned: NativeBillingReturn?, token: String, pendingID: UUID? = nil) {
        billingPoll?.cancel(); let id = UUID(); billingPollID = id
        let generation = sessionGeneration
        let waitingForPortal = returned == nil && pendingBilling?.flow == .billing
        billingStage = returned == nil ? .waiting : .checking
        message = returned?.status == .cancelled ? "Checking your account…" : "Checking your payment and subscription…"
        billingPoll = Task { @MainActor in
            let deadline = Date().addingTimeInterval(returned == nil ? 15 * 60 : 60)
            let completed = await BillingAccessPoll.run(until: deadline) {
                guard self.billingPollID == id, self.accessToken == token, self.sessionGeneration == generation, !Task.isCancelled else { return true }
                let active = await self.refresh(force: true, timeout: min(10, max(1, deadline.timeIntervalSinceNow)))
                guard self.billingPollID == id, self.accessToken == token, self.sessionGeneration == generation, !Task.isCancelled else { return true }
                // An already-active account entering the portal must keep its return state.
                if active && !waitingForPortal {
                    if let pendingID { try? AccountKeychain.cancelBilling(id: pendingID) }
                    self.pendingBilling = nil
                    self.message = "Your Cloud subscription is active. Turn on backups when you’re ready."
                    return true
                }
                if returned?.status == .cancelled {
                    self.message = "Checkout was cancelled. You can subscribe when you’re ready."
                    return true
                }
                if returned?.flow == .billing && !self.subscriptionUnavailable {
                    self.message = "Your billing changes are up to date."
                    return true
                }
                self.message = self.subscriptionUnavailable ? "We couldn’t check your subscription yet. Retrying…" : waitingForPortal ? "Your subscription updates automatically while billing is open." : "Waiting for Stripe to confirm your payment…"
                return false
            }
            guard self.billingPollID == id, self.accessToken == token, self.sessionGeneration == generation, !Task.isCancelled else { return }
            self.billingPoll = nil
            self.billingStage = completed ? .idle : (self.pendingBilling == nil ? .idle : .waiting)
            if !completed { self.message = "Still waiting for payment confirmation. We’ll check again when you return to SaveNest." }
        }
    }
    func cancelBilling() {
        billingPollID = UUID(); billingPoll?.cancel(); billingPoll = nil
        let id = pendingBilling?.id; pendingBilling = nil; billingStage = .idle
        do { try AccountKeychain.cancelBilling(id: id); message = "Stopped waiting. Any payment already completed in Stripe is unchanged. You can refresh your account here anytime." }
        catch { message = friendly(error) }
    }
    func signOut() {
        let token = accessToken
        cancelSignIn(); cancelBilling(); clearLocalLogin(); message = nil
        do { try AccountKeychain.signOut(token: token) } catch { message = friendly(error) }
        if let token { revoke(token) }
    }
    private func revoke(_ token: String) {
        Task {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/logout")); request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await session.data(for: request)
        }
    }
    private func clearLocalLogin() {
        sessionGeneration = UUID(); accessToken = nil; hasLogin = false; account = nil; verifiedAt = nil; subscriptionUnavailable = false; referral = nil; referralMessage = nil
        refreshFlight?.task.cancel(); refreshFlight = nil; isRefreshing = false
        billingPollID = UUID(); billingPoll?.cancel(); billingPoll = nil; pendingBilling = nil; billingStage = .idle
        onChange?()
    }
    private func showAccount() {
        if let bringAccountForward { bringAccountForward() }
        else { presentationWindow?()?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    private func friendly(_ error: Error) -> String {
        if error is URLError { return "SaveNest couldn’t connect. Check your internet connection and try again. Your saved library is still available." }
        return error.localizedDescription
    }
    private func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AccountFailure.invalidResponse }
        return Data(bytes).base64URL
    }
}

private extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
