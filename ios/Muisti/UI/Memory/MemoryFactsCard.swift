import SwiftUI

/// The structured fields Nemotron extracted (only the ones that exist).
struct MemoryFactsCard: View {
    let record: MemoryRecord
    let showsTechnical: Bool

    private var facts: [(title: String, value: String, icon: String)] {
        var rows: [(String, String?, String)] = [
            ("Phone", record.phone, "phone"),
            ("Hours", record.hours, "clock"),
            ("Description", record.caption, "text.quote"),
            ("Other text", record.otherText, "text.alignleft"),
        ]
        if showsTechnical {
            rows.append(("Keywords", record.keywords, "tag"))
            rows.append(("Confidence", record.confidence.map { String(format: "%.2f", $0) }, "gauge.medium"))
            rows.append(("Status", statusText, "gearshape"))
        }
        return rows.compactMap { title, value, icon in
            guard let value, !value.isEmpty else { return nil }
            return (title, value, icon)
        }
    }

    private var statusText: String {
        switch record.status {
        case .pending: return "Waiting for Nemotron"
        case .enriched: return "Structured"
        case .failed: return "Couldn't structure (OCR only)"
        }
    }

    var body: some View {
        if facts.isEmpty {
            if record.status == .pending {
                Label("AI hasn't processed this memory yet. It will be ready shortly once there's internet and an API key.", systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .card()
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(facts, id: \.title) { fact in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                        Image(systemName: fact.icon)
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(fact.value)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .card()
        }
    }
}
