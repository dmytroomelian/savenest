import SwiftUI
import SaveNestCore

struct CloudLibraryView: View {
    @ObservedObject var cloud: CloudLibraryController
    private var indicatorState: String { cloud.indicator.rawValue }
    private var needsAttention: Bool { ["offline", "attention"].contains(indicatorState) }
    private var canReviewRecovery: Bool {
        cloud.hasAccount && (indicatorState != "hidden" || cloud.status?.canRestore == true
            || cloud.requiresLocalReview || cloud.recoveryFile != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if indicatorState != "hidden" {
                SyncIndicatorView(state: indicatorState, label: cloud.indicator.label)
            }
            if canReviewRecovery {
                DisclosureGroup("Restore library") {
                    VStack(alignment: .leading, spacing: 12) {
                        if cloud.requiresLocalReview {
                            Text("Review this library or restore a saved copy to continue.")
                            if cloud.status?.enabled == true && cloud.status?.canUpload == true {
                                Button("Use this library…") { cloud.setEnabled(true) }
                                    .buttonStyle(QuietButton()).disabled(cloud.isBusy)
                            }
                        }
                        if needsAttention || (indicatorState == "hidden" && cloud.status?.canRestore == true), let message = cloud.message {
                            Text(message).fixedSize(horizontal: false, vertical: true)
                        }
                        if cloud.status?.canRestore == true {
                            if cloud.snapshots.isEmpty {
                                Text("No saved copies yet.")
                            } else {
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
                                    }
                                }
                            }
                        }
                        if let end = cloud.status?.retentionEndsAt, cloud.status?.canUpload != true {
                            Text("Recovery available until \(end.formatted(date: .abbreviated, time: .omitted)).")
                        }
                        if cloud.recoveryFile != nil {
                            Button("Show recovery copy") { cloud.revealRecoveryCopy() }.buttonStyle(.link)
                        }
                    }.font(.system(size: 12)).foregroundStyle(Color.muted).padding(.top, 8)
                }.font(.system(size: 12)).foregroundStyle(Color.muted)
            }
        }
    }
}

private struct SyncIndicatorView: View {
    let state: String
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var active: Bool { state == "active" }
    private var dotColor: Color {
        if active { return .green }
        if state == "attention" { return .orange }
        return Color.muted
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7)).foregroundStyle(dotColor)
                .symbolEffect(.pulse, options: .repeating.speed(0.5), isActive: active && !reduceMotion)
                .accessibilityHidden(true)
            Text(label).font(.system(size: 13)).foregroundStyle(Color.muted)
        }.accessibilityElement(children: .combine)
    }
}
