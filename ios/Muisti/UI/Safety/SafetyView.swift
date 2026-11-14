import SwiftUI

/// Muisti Turva: warnings with their evidence frame, what Muisti last saw of each watched
/// object, and the user's rules. Rules are created by voice ("warn me if I leave the stove on").
struct SafetyView: View {
    let safety: SafetyMonitor
    @State private var homeMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if case .some(let pending) = safety.pending {
                    Section("Waiting for your answer") {
                        Text(pending.prompt)
                            .font(.subheadline)
                        HStack {
                            Button("Yes") { Task { _ = await safety.handle(.confirm) } }
                                .buttonStyle(.borderedProminent)
                            Button("No", role: .cancel) { Task { _ = await safety.handle(.cancel) } }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                Section {
                    if safety.alerts.isEmpty {
                        Text("No warnings yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(safety.alerts) { alert in
                        AlertRow(alert: alert, url: alert.evidenceFrame.map(safety.store.frameURL)) { response in
                            Task { await safety.respond(alert, response) }
                        }
                    }
                } header: {
                    Text("Warnings")
                }

                Section {
                    if safety.states.isEmpty {
                        Text("Nothing watched has been seen yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(safety.states, id: \.object) { state in
                        StateRow(state: state, url: state.evidenceFrame.map(safety.store.frameURL))
                    }
                } header: {
                    Text("Last seen")
                } footer: {
                    Text("What Muisti saw, not what is true now. \"Your words\" means you told Muisti; it did not see it.")
                }

                Section {
                    if safety.rules.isEmpty {
                        Text("Say for example: “Warn me if I leave home with the stove on”, “Remind me to take my blood pressure pill at 8”, “Warn me about milk on product labels”.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(safety.rules) { rule in
                        Toggle(isOn: Binding(get: { rule.enabled }, set: { on in Task { await safety.setEnabled(rule, on) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.summary)
                                Text(rule.watch.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { Task { await safety.delete(rule) } }
                        }
                    }
                } header: {
                    Text("Your rules")
                }

                Section {
                    Button(safety.home == nil ? "This is my home" : "Move home here", systemImage: "house") {
                        homeMessage = safety.setHomeHere() ? "Home saved." : "No location yet. Start recording first."
                    }
                    if let homeMessage {
                        Text(homeMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(safety.lastObservationText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                } footer: {
                    Text("Muisti complements a stove guard and smoke alarm; it does not replace them. It only knows what the glasses saw, and it gives no medical advice.")
                }
            }
            .navigationTitle("Safety")
            .task { await safety.reload() }
        }
    }
}

private struct AlertRow: View {
    let alert: SafetyAlert
    let url: URL?
    let respond: (SafetyAlert.Response) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: alert.severity == .high ? "exclamationmark.triangle.fill" : "bell.fill")
                    .foregroundStyle(alert.severity == .high ? Color.red : Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(alert.message)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(alert.at.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let url { EvidenceThumb(url: url) }
            if alert.response == nil {
                HStack {
                    Button("OK") { respond(.dismissed) }
                    Button("Later") { respond(.snoozed) }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            } else if let response = alert.response {
                Text(response.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StateRow: View {
    let state: ObjectState
    let url: URL?

    var body: some View {
        HStack(spacing: 12) {
            if let url { EvidenceThumb(url: url, height: 56).frame(width: 74) }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.object.replacingOccurrences(of: ":", with: " · ")): \(state.state)")
                    .font(.body.weight(.medium))
                Text("Last seen \(state.lastStateSeen.formatted(date: .omitted, time: .shortened))"
                     + (state.place.map { " · \($0)" } ?? "")
                     + (state.source == .vision ? "" : " · your words"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A blurred evidence frame from the safety folder.
private struct EvidenceThumb: View {
    let url: URL
    var height: CGFloat = 140
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Evidence frame")
        .task(id: url) {
            let url = url
            image = await Task.detached { (try? Data(contentsOf: url)).flatMap(UIImage.init(data:)) }.value
        }
    }
}
