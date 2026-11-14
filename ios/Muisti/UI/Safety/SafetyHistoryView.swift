import SwiftUI

/// Everything that already happened, off the main Safety page: every warning (answered ones
/// too) and what Muisti last saw of each watched object.
struct SafetyHistoryView: View {
    let safety: SafetyMonitor

    private enum Tab: Hashable { case warnings, lastSeen }
    @State private var tab = Tab.warnings

    var body: some View {
        List {
            Section {
                switch tab {
                case .warnings:
                    if safety.alerts.isEmpty {
                        Text("No warnings yet.").foregroundStyle(.secondary)
                    }
                    ForEach(safety.alerts) { alert in
                        SafetyAlertRow(alert: alert, url: alert.evidenceFrame.map(safety.store.frameURL))
                    }
                case .lastSeen:
                    if safety.states.isEmpty {
                        Text("Nothing watched has been seen yet.").foregroundStyle(.secondary)
                    }
                    ForEach(safety.states, id: \.object) { state in
                        SafetyStateRow(state: state, url: state.evidenceFrame.map(safety.store.frameURL))
                    }
                }
            } header: {
                Picker("Show", selection: $tab) {
                    Text("Warnings").tag(Tab.warnings)
                    Text("Last seen").tag(Tab.lastSeen)
                }
                .pickerStyle(.segmented)
                .textCase(nil)
                .padding(.bottom, Theme.Spacing.xs)
            } footer: {
                if tab == .lastSeen {
                    Text("What Muisti saw, not what is true now.")
                }
            }
        }
        .listRowSpacing(4)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await safety.reload() }
    }
}
