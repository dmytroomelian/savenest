import SwiftUI

struct AccountView: View {
    @ObservedObject var account: AccountController
    @ObservedObject var cloud: CloudLibraryController
    var onBack: () -> Void = {}
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { onBack() } label: { Label("Library", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted)
                HStack(spacing: 10) { NestMark().frame(width: 30, height: 30); Text("Savenest").font(.system(size: 23, weight: .semibold)) }
                if AppRuntime.isPrivateBeta {
                    Text("AWS beta · Separate test library").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.sage)
                }
                proSubscription
                if let details = account.account {
                    Text(details.user.email).font(.system(size: 13)).textSelection(.enabled)
                }
                if !account.hasLogin {
                    DisclosureGroup("Sign in to your account") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("We’ll email you a sign-in link.").font(.system(size: 12)).foregroundStyle(Color.muted)
                            TextField("Email", text: $account.signInEmail).textFieldStyle(.roundedBorder).textContentType(.emailAddress)
                            TextField("Name (optional)", text: $account.signInName).textFieldStyle(.roundedBorder).textContentType(.name)
                            HStack {
                                Button(account.signInStage == .waiting ? "Resend sign-in email" : "Email me a sign-in link") { account.sendSignInEmail() }
                                    .buttonStyle(SageButton()).disabled(account.signInStage == .sending || account.signInStage == .verifying)
                                if account.isSigningIn { Button("Cancel") { account.cancelSignIn() }.buttonStyle(.link) }
                            }
                        }.padding(.top, 12)
                    }.font(.system(size: 13))
                } else {
                    HStack {
                        Button("Refresh account") {
                            Task { await account.refresh(force: true); cloud.refresh() }
                        }.buttonStyle(QuietButton()).disabled(account.isBusy || cloud.isBusy)
                        if account.billingStage == .waiting || account.billingStage == .checking { Button("Stop waiting") { account.cancelBilling() }.buttonStyle(.link) }
                        if account.isBusy || cloud.isBusy { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Sign out") { account.signOut() }.buttonStyle(.link).disabled(account.isBusy)
                    }
                }
                if let message = account.message { Text(message).font(.system(size: 12)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true) }
                Divider()
                HStack {
                    Link("Privacy policy ↗", destination: URL(string: "https://savenest.app/privacy")!)
                    Spacer()
                    Link("Contact support", destination: URL(string: "mailto:dima@omelabs.org")!)
                }.font(.system(size: 12))
            }.padding(30)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.paper).foregroundStyle(Color.ink).nestAppearance()
    }
    @ViewBuilder private var proSubscription: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Savenest Pro").font(.system(size: 17, weight: .semibold))
            CloudLibraryView(cloud: cloud)
            if account.hasVerifiedSubscription {
                DisclosureGroup("Membership") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let subscription = account.account?.subscription {
                            Text(subscription.plan == "yearly" ? "Yearly plan" : "Monthly plan")
                            if let end = subscription.renewsAt {
                                Text("\(subscription.cancelAtPeriodEnd ? "Access until" : "Renews") \(Date(timeIntervalSince1970: end).formatted(date: .abbreviated, time: .omitted))")
                                    .foregroundStyle(Color.muted)
                            }
                        }
                        if account.canManageBilling { billingButton }
                    }.font(.system(size: 12)).padding(.top, 8)
                }.font(.system(size: 12)).foregroundStyle(Color.muted)
            } else if account.subscriptionUnavailable {
                Text("Couldn’t verify Pro. Refresh your account to try again.")
                    .font(.system(size: 12)).foregroundStyle(Color.muted)
                if account.canManageBilling { billingButton }
            } else if account.hasExistingSubscription {
                Text(account.account?.subscription.plan == nil
                     ? "Your existing plan doesn’t include Pro. Manage billing or contact support."
                     : "Check your billing to restore Pro access.")
                    .font(.system(size: 12)).foregroundStyle(Color.muted)
                if account.canManageBilling { billingButton }
            } else {
                Text("Everything saved, automatically.")
                    .font(.system(size: 13)).foregroundStyle(Color.muted)
                Text("$4.99 / month or $49.90 / year")
                    .font(.system(size: 14, weight: .medium))
                Text("USD + tax. Auto-renews. Cancel anytime.")
                    .font(.system(size: 12)).foregroundStyle(Color.muted)
                if account.account?.subscription.billingReady == true {
                    HStack(spacing: 10) {
                        Button("Choose monthly") { Task { await account.checkout(plan: "monthly") } }
                            .buttonStyle(SageButton())
                        Button("Choose yearly") { Task { await account.checkout(plan: "yearly") } }
                            .buttonStyle(QuietButton())
                    }.disabled(account.isBusy)
                } else {
                    Text(account.hasLogin ? "Refresh your account to check plan availability." : "Sign in below to choose a plan.")
                        .font(.system(size: 12)).foregroundStyle(Color.muted)
                }
                Text("Local features stay free.")
                    .font(.system(size: 12)).foregroundStyle(Color.muted)
            }
            if account.isSandbox {
                Text("Test mode · No real charge").font(.system(size: 11)).foregroundStyle(Color.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).nestSurface()
    }
    private var billingButton: some View {
        Button("Manage billing ↗") { Task { await account.openBilling() } }
            .buttonStyle(QuietButton()).disabled(account.isBusy)
    }
}
