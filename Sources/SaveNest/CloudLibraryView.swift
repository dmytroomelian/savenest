import SwiftUI
import SaveNestCore

struct CloudLibraryView: View {
    @ObservedObject var cloud: CloudLibraryController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SaveNest Cloud").font(.system(size: 15, weight: .medium))
                Spacer()
                if cloud.isBusy { ProgressView().controlSize(.small) }
                Text(cloud.enabled ? "Backups on" : "Backups off").font(.system(size: 12)).foregroundStyle(Color.sage)
            }
            Text("Automatic library backups and recovery. Your local features stay free.")
                .font(.system(size: 13)).foregroundStyle(Color.muted)
            Text("Includes saved links, quick notes, tags, and collections. Obsidian files and offline articles stay on this Mac. Each Mac keeps separate backups; this is not live sync.")
                .font(.system(size: 12)).foregroundStyle(Color.muted)
            Text("Keeps up to 30 daily copies per Mac. Recovery remains available for 90 days after your subscription ends.")
                .font(.system(size: 12)).foregroundStyle(Color.muted)
            if cloud.needsLocalReview {
                Text("The previous local library was missing or could not be opened. Automatic backups are paused. Restore a cloud backup, or review this Mac’s current library before turning backups on.")
                    .font(.system(size: 12)).foregroundStyle(Color.muted)
            }
            if cloud.hasAccount {
                HStack {
                    Button("Refresh Cloud") { cloud.refresh() }.buttonStyle(QuietButton()).disabled(cloud.isBusy)
                    if cloud.enabled {
                        Button("Back up now") { cloud.backUpNow() }.buttonStyle(QuietButton()).disabled(cloud.isBusy)
                        Button("Turn off") { cloud.setEnabled(false) }.buttonStyle(.link).disabled(cloud.activity == .restoring)
                    } else if cloud.status?.enabled == true && cloud.status?.canUpload == true {
                        Button("Turn on backups") { cloud.setEnabled(true) }.buttonStyle(SageButton()).disabled(cloud.isBusy)
                    }
                }
                if let saved = cloud.lastSavedAt {
                    Text("Last backup from this Mac: \(saved.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(Color.muted)
                }
                if let end = cloud.status?.retentionEndsAt, cloud.status?.canUpload != true {
                    Text("Recovery available until \(end.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.system(size: 12)).foregroundStyle(Color.muted)
                }
                if cloud.status?.canRestore == true && !cloud.snapshots.isEmpty {
                    DisclosureGroup("Available backups (\(cloud.snapshots.count))") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(cloud.snapshots) { snapshot in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        Text("\(snapshot.linkCount) links · \(snapshot.deviceId == cloud.deviceID ? "This Mac" : "Another Mac")")
                                            .foregroundStyle(Color.muted)
                                    }
                                    Spacer()
                                    Button("Restore…") { Task { await cloud.restore(snapshot) } }
                                        .buttonStyle(QuietButton()).disabled(cloud.isBusy)
                                }.font(.system(size: 12))
                            }
                        }.padding(.top, 10)
                    }.font(.system(size: 13))
                }
            } else {
                Text("Sign in to check Cloud access. Signing in alone does not upload your library.")
                    .font(.system(size: 12)).foregroundStyle(Color.muted)
            }
            if let message = cloud.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cloud.recoveryFile != nil {
                Button("Show recovery copy") { cloud.revealRecoveryCopy() }.buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }.padding(20).nestSurface()
    }
}
