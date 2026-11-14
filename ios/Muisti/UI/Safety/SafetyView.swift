import SwiftUI

/// Muisti Safety: open warnings as large photo cards (the frame is the evidence, so it leads),
/// what Muisti last saw of each watched object as a strip of photo tiles, the user's rules,
/// and home. Rules are created by voice ("warn me if I leave the stove on").
struct SafetyView: View {
    let safety: SafetyMonitor
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false

    /// The system's list margin on iPhone, so cards line up with the large title.
    static let margin: CGFloat = 16

    private var openAlerts: [SafetyAlert] { safety.alerts.filter { $0.response == nil } }
    private var earlierAlerts: [SafetyAlert] { safety.alerts.filter { $0.response != nil } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    if let pending = safety.pending {
                        SafetyPendingCard(pending: pending, frameURL: frameURL(of: pending)) { yes in
                            Task { _ = await safety.handle(yes ? .confirm : .cancel) }
                        }
                    }

                    SafetySection("Warnings") {
                        if openAlerts.isEmpty {
                            SafetyAllClearCard(hasRules: !safety.rules.isEmpty)
                        }
                        ForEach(openAlerts) { alert in
                            SafetyAlertCard(alert: alert, frameURL: alert.evidenceFrame.map(safety.store.frameURL)) { response in
                                Task { await safety.respond(alert, response) }
                            }
                        }
                    }

                    if !safety.states.isEmpty {
                        SafetySection("Last seen", footer: "What Muisti saw, not what is true now. “You said” means you told Muisti; it didn't see it.") {
                            SafetyStateStrip(states: safety.states, frameURL: safety.store.frameURL)
                        }
                    }

                    SafetySection("Your rules") {
                        SafetyRulesCard(rules: safety.rules) { rule, on in
                            Task { await safety.setEnabled(rule, on) }
                        } delete: { rule in
                            Task { await safety.delete(rule) }
                        }
                    }

                    if !earlierAlerts.isEmpty {
                        SafetySection("Earlier") {
                            SafetyHistoryCard(alerts: earlierAlerts, frameURL: safety.store.frameURL)
                        }
                    }

                    SafetySection("Home") {
                        SafetyHomeCard(hasHome: safety.home != nil, setHomeHere: safety.setHomeHere)
                    }

                    Label("Muisti complements a stove guard and smoke alarm; it does not replace them. It only knows what the glasses saw, and it gives no medical advice.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if developerMode {
                        Text(safety.lastObservationText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, Self.margin)
                .padding(.top, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.xl)
                .animation(Theme.Motion.standard, value: safety.alerts)
                .animation(Theme.Motion.standard, value: safety.pending)
            }
            .navigationTitle("Safety")
            .refreshable { await safety.reload() }
            .task { await safety.reload() }
        }
    }

    private func frameURL(of pending: SafetyPending) -> URL? {
        guard case .action(_, _, let frame?, _) = pending else { return nil }
        return safety.store.frameURL(frame)
    }
}
