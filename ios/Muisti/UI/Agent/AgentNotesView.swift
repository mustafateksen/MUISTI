import SwiftUI

/// What Muisti keeps for the user and what it brought up by itself: reminders, the destination,
/// named places, what the user told it, and the log of every time it spoke up or chose not to.
struct AgentNotesView: View {
    let controller: CaptureController
    private var agent: AgentCenter { controller.agent }

    var body: some View {
        List {
            Section {
                let open = agent.intents.filter { $0.status == .open }
                if open.isEmpty {
                    Text("Nothing yet. Say “remind me to…” or “I'm going to…”, or just let Muisti notice things.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(open) { intent in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(intent.placeName.map { "\(intent.text) · \($0)" } ?? intent.text, systemImage: icon(intent.kind))
                        Text(when(intent))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .leading) {
                        Button("Done", systemImage: "checkmark") { Task { await agent.markDone(intent) } }
                            .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await agent.remove(intent) } }
                    }
                }
            } header: {
                Text("Keeping in mind")
            } footer: {
                Text("Swipe right when it's done, left to remove it.")
            }

            if !agent.places.isEmpty {
                Section("Places") {
                    ForEach(agent.places) { place in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(place.name.capitalized, systemImage: place.id == "car" ? "car.fill" : "mappin.and.ellipse")
                            Text([place.detail, place.setAt.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("Delete", systemImage: "trash", role: .destructive) { Task { await agent.remove(place) } } }
                    }
                }
            }

            if !agent.facts.isEmpty {
                Section("What you told Muisti") {
                    ForEach(agent.facts) { fact in
                        Text(fact.text)
                            .swipeActions { Button("Delete", systemImage: "trash", role: .destructive) { Task { await agent.remove(fact) } } }
                    }
                }
            }

            Section {
                let log = agent.policy.recent.prefix(60)
                if log.isEmpty {
                    Text("Muisti hasn't brought anything up yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(log)) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(entry.text, systemImage: icon(entry.level))
                            .foregroundStyle(entry.level == .silent ? .secondary : .primary)
                        Text(detail(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Brought up by Muisti")
            } footer: {
                Text("Everything Muisti said on its own, and what it decided to keep to itself and why.")
            }
        }
        .navigationTitle("Assistant notes")
        .navigationBarTitleDisplayMode(.inline)
        .task { await agent.reload() }
    }

    private func icon(_ kind: Intent.Kind) -> String {
        switch kind {
        case .reminder: return "bell"
        case .todo: return "checklist"
        case .destination: return "location.north.line"
        case .watch: return "eye"
        case .parking: return "car"
        case .followup: return "note.text"
        }
    }

    private func icon(_ level: InterventionLevel) -> String {
        switch level {
        case .silent: return "speaker.slash"
        case .notification: return "bell.badge"
        case .chime: return "bell.and.waves.left.and.right"
        case .spoken: return "waveform"
        }
    }

    private func when(_ intent: Intent) -> String {
        var parts: [String] = []
        if let due = intent.cue.nextDue(after: intent.firedAt ?? intent.createdAt) { parts.append(due.formatted(date: .abbreviated, time: .shortened)) }
        if let place = intent.cue.place { parts.append(place) }
        if let sight = intent.cue.sight { parts.append(String(localized: "when seen: \(sight)")) }
        if intent.cue.on == "leaving_home" { parts.append(String(localized: "when leaving home")) }
        if intent.cue.on == "arriving_home" { parts.append(String(localized: "when arriving home")) }
        if intent.source == .agent { parts.append(String(localized: "noted by Muisti")) }
        return parts.isEmpty ? intent.createdAt.formatted(date: .abbreviated, time: .shortened) : parts.joined(separator: " · ")
    }

    private func detail(_ entry: Intervention) -> String {
        var parts = [entry.at.formatted(date: .omitted, time: .shortened), entry.topic.replacingOccurrences(of: "_", with: " ")]
        if let reason = entry.reason { parts.append(reason) }
        if let outcome = entry.outcome { parts.append(outcome.rawValue) }
        return parts.joined(separator: " · ")
    }
}
