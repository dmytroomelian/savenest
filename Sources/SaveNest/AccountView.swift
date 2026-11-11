import SwiftUI

struct AccountView: View {
    @ObservedObject var account: AccountController
    @ObservedObject var cloud: CloudLibraryController
    @State private var promoCode = ""
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
                friendInvitation
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
                if let code = account.pendingReferralCode {
                    Text("Invitation \(code): $1.99 for your first month, then $4.99/month if eligible.")
                        .font(.system(size: 12)).foregroundStyle(Color.sage)
                    Button("Remove invitation") { account.clearReferralCode() }.buttonStyle(.link)
                }
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
                            .buttonStyle(QuietButton()).disabled(account.pendingReferralCode != nil)
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
    private var friendInvitation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invite a friend. You both get a $1.99 month of Pro.")
                .font(.system(size: 17, weight: .semibold))
            Text("A friend new to paid Savenest gets their first month for $1.99. After they pay, you get $3 off your first monthly checkout or a monthly renewal. Then $4.99/month, plus tax. One discounted month per account; yearly plans are excluded. Cancel anytime.")
                .font(.system(size: 12)).foregroundStyle(Color.muted)
            if account.hasLogin {
                TextField("Friend’s email address", text: $account.inviteEmail)
                    .textFieldStyle(.roundedBorder).textContentType(.emailAddress)
                if !account.inviteEmail.isEmpty && !account.validInviteEmail {
                    Text("Enter your friend’s valid email address.").font(.system(size: 12)).foregroundStyle(Color.muted)
                }
                Button(account.isSendingInvite ? "Sending…" : "Send invitation") {
                    Task { await account.sendReferralInvite() }
                }.buttonStyle(SageButton())
                    .disabled(!account.validInviteEmail || account.isSendingInvite || account.referral?.eligible != true || account.referral?.remaining == 0)
                if account.referral == nil {
                    Text("Refresh your account to check invitation availability.")
                        .font(.system(size: 12)).foregroundStyle(Color.muted)
                } else if account.referral?.eligible == false || account.referral?.remaining == 0 {
                    Text("Invitations aren’t available for this account right now.")
                        .font(.system(size: 12)).foregroundStyle(Color.muted)
                }
                if let message = account.referralMessage {
                    Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                if let queued = account.referral?.queued, queued > 0 {
                    Text("Your friend paid. Your eligible monthly checkout or renewal gets the discount automatically.")
                        .font(.system(size: 12)).foregroundStyle(Color.sage)
                }
                if !account.hasExistingSubscription {
                    DisclosureGroup("Have an invitation code?") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Promo code from your invitation", text: $promoCode).textFieldStyle(.roundedBorder)
                            Button("Apply code") { account.setReferralCode(promoCode) }
                                .buttonStyle(QuietButton()).disabled(promoCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(.top, 8)
                    }.font(.system(size: 12))
                }
            } else {
                Text("Sign in to send or use an invitation.").font(.system(size: 12)).foregroundStyle(Color.muted)
            }
            Text("Invitations and rewards for a first checkout expire after 30 days.")
                .font(.system(size: 11)).foregroundStyle(Color.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).nestSurface()
    }
    private var billingButton: some View {
        Button("Manage billing ↗") { Task { await account.openBilling() } }
            .buttonStyle(QuietButton()).disabled(account.isBusy)
    }
}
