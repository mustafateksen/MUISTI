import SwiftUI

/// Muisti Safety, one screen without scrolling in normal use: what needs an answer now (pending
/// question, open warnings or "All clear"), then the rules and home. Past warnings and what
/// Muisti last saw sit behind the History button. Photos are thumbnails that open full screen.
/// "+" adds a rule in the user's own words (the AI writes it up); rules can also be spoken.
struct SafetyView: View {
    let safety: SafetyMonitor
    let ai: NemotronClient
    @State private var addingRule = false
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false

    private var openAlerts: [SafetyAlert] { safety.alerts.filter { $0.response == nil } }

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

                Section {
                    if openAlerts.isEmpty {
                        Label(allClearText, systemImage: "checkmark.shield.fill")
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

                Section {
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
                    SafetyHomeRow(hasHome: safety.home != nil, setHomeHere: safety.setHomeHere)
                } header: {
                    Text("Rules")
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
            .listRowSpacing(4)
            .listSectionSpacing(.compact)
            .navigationTitle("Safety")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        SafetyHistoryView(safety: safety)
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
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

    /// "All clear · 3 rules on": the page's one-line status when nothing is open.
    private var allClearText: String {
        let on = safety.rules.filter(\.enabled).count
        return on == 0 ? String(localized: "All clear") : String(localized: "All clear · \(on) rules on")
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
