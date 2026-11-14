import SwiftUI

/// Muisti Safety as a plain list of small cards, top to bottom: open warnings, what Muisti last
/// saw of each watched object, the rules, home. Photos are thumbnails that open full screen.
/// "+" adds a rule in the user's own words (the AI writes it up); rules can also be spoken.
struct SafetyView: View {
    let safety: SafetyMonitor
    let ai: NemotronClient
    @State private var addingRule = false
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false

    private var openAlerts: [SafetyAlert] { safety.alerts.filter { $0.response == nil } }
    private var earlierAlerts: [SafetyAlert] { Array(safety.alerts.filter { $0.response != nil }.prefix(5)) }

    var body: some View {
        NavigationStack {
            List {
                if let pending = safety.pending {
                    Section {
                        SafetyPendingRow(pending: pending, frameURL: frameURL(of: pending)) { yes in
                            Task { _ = await safety.handle(yes ? .confirm : .cancel) }
                        }
                    }
                }

                Section("Warnings") {
                    if openAlerts.isEmpty {
                        Label("All clear", systemImage: "checkmark.shield.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.success)
                    }
                    ForEach(openAlerts) { alert in
                        SafetyAlertRow(alert: alert, url: url(alert.evidenceFrame)) { respond(alert, .dismissed) }
                            .swipeActions {
                                Button("Got it", systemImage: "checkmark") { respond(alert, .dismissed) }
                                    .tint(.brand)
                                Button("Later", systemImage: "clock") { respond(alert, .snoozed) }
                                    .tint(.attention)
                            }
                    }
                }

                if !safety.states.isEmpty {
                    Section("Last seen") {
                        ForEach(safety.states, id: \.object) { state in
                            SafetyStateRow(state: state, url: url(state.evidenceFrame))
                        }
                    }
                }

                Section("Rules") {
                    if safety.rules.isEmpty {
                        Button("Add your first rule", systemImage: "plus") { addingRule = true }
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach(safety.rules) { rule in
                        SafetyRuleRow(rule: rule) { on in Task { await safety.setEnabled(rule, on) } }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { Task { await safety.delete(rule) } }
                            }
                    }
                }

                if !earlierAlerts.isEmpty {
                    Section("Earlier") {
                        ForEach(earlierAlerts) { alert in
                            SafetyAlertRow(alert: alert, url: url(alert.evidenceFrame))
                        }
                    }
                }

                Section {
                    SafetyHomeRow(hasHome: safety.home != nil, setHomeHere: safety.setHomeHere)
                } footer: {
                    Text("Muisti complements a stove guard and smoke alarm; it never replaces them.")
                }

                if developerMode {
                    Section("Last observation") {
                        Text(safety.lastObservationText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .listRowSpacing(Theme.Spacing.xs)
            .navigationTitle("Safety")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add rule", systemImage: "plus") { addingRule = true }
                }
            }
            .sheet(isPresented: $addingRule) {
                SafetyAddRuleSheet(safety: safety, ai: ai)
            }
            .animation(Theme.Motion.standard, value: safety.alerts)
            .animation(Theme.Motion.standard, value: safety.rules)
            .refreshable { await safety.reload() }
            .task {
                #if DEBUG
                // `--safety-add`: open the add-rule sheet on launch (screenshots).
                if ProcessInfo.processInfo.arguments.contains("--safety-add") { addingRule = true }
                #endif
                await safety.reload()
            }
        }
    }

    private func url(_ frame: String?) -> URL? {
        frame.map(safety.store.frameURL)
    }

    private func respond(_ alert: SafetyAlert, _ response: SafetyAlert.Response) {
        Task { await safety.respond(alert, response) }
    }

    private func frameURL(of pending: SafetyPending) -> URL? {
        guard case .action(_, _, let frame?, _) = pending else { return nil }
        return safety.store.frameURL(frame)
    }
}
