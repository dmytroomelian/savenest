import SwiftUI

struct AccountView: View {
    @ObservedObject var account: AccountController
    @ObservedObject var cloud: CloudLibraryController
    var onBack: () -> Void = {}
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button { onBack() } label: { Label("Library", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted)
                HStack(spacing: 10) { NestMark().frame(width: 30, height: 30); Text("savenest").font(.system(size: 23, weight: .semibold)) }
                if AppRuntime.isPrivateBeta {
                    Text("AWS beta · Separate test library").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.sage)
                }
                sheetHeading("Free on your Mac.", subtitle: "Every local feature. No account or subscription required.")
                VStack(alignment: .leading, spacing: 9) {
                    Label("SaveNest Free", systemImage: "checkmark.circle.fill").foregroundStyle(Color.sage)
                    Text("Save, search, annotate, organize, import, export, and share your links. Your library stays on this Mac, including when you’re offline or signed out.")
                        .font(.system(size: 13)).foregroundStyle(Color.muted)
                }.padding(20).nestSurface()
                CloudLibraryView(cloud: cloud)
                cloudSubscription
                if let details = account.account {
                    Text(details.user.email).font(.system(size: 13)).textSelection(.enabled)
                    if account.canManageBilling {
                        Button("Manage subscription ↗") { Task { await account.openBilling() } }.buttonStyle(QuietButton()).disabled(account.isBusy)
                    }
                }
                if !account.hasLogin {
                    DisclosureGroup("Sign in to your account") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("We’ll email a sign-in link. Signing in is optional and does not upload your library.").font(.system(size: 12)).foregroundStyle(Color.muted)
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
                        Button("Refresh account") { Task { await account.refresh(force: true) } }.buttonStyle(QuietButton()).disabled(account.isBusy)
                        if account.billingStage == .waiting || account.billingStage == .checking { Button("Stop waiting") { account.cancelBilling() }.buttonStyle(.link) }
                        if account.isBusy { ProgressView().controlSize(.small) }
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
    @ViewBuilder private var cloudSubscription: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let subscription = account.account?.subscription, account.hasVerifiedSubscription {
                Label("Cloud active", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Color.sage)
                Text(subscription.plan == "yearly" ? "Yearly plan" : "Monthly plan")
                    .font(.system(size: 13))
                if let end = subscription.renewsAt {
                    Text("\(subscription.cancelAtPeriodEnd ? "Access until" : "Renews") \(Date(timeIntervalSince1970: end).formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 12)).foregroundStyle(Color.muted)
                }
            } else if account.hasExistingSubscription {
                Text("Review your Cloud subscription").font(.system(size: 15, weight: .medium))
                Text("Manage your existing subscription to check payment details or restore Cloud access. Local features stay free.")
                    .font(.system(size: 12)).foregroundStyle(Color.muted)
            } else {
                Text("Add Cloud backup").font(.system(size: 15, weight: .medium))
                Text("$4.99 / month or $49.90 / year")
                    .font(.system(size: 14, weight: .medium))
                Text("USD. Renews automatically. Cancel anytime in Manage subscription. Signing in or subscribing does not upload your library; turn on backups when you’re ready.")
                    .font(.system(size: 12)).foregroundStyle(Color.muted)
                if account.account?.subscription.billingReady == true && !account.subscriptionUnavailable {
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
            }
            if account.isSandbox {
                Text("Test mode · No real charge").font(.system(size: 11)).foregroundStyle(Color.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).nestSurface()
    }

}
