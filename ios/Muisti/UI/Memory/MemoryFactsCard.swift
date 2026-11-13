import SwiftUI

/// The structured fields Nemotron extracted (only the ones that exist).
struct MemoryFactsCard: View {
    let record: MemoryRecord
    let showsTechnical: Bool

    private var facts: [(title: String, value: String, icon: String)] {
        var rows: [(String, String?, String)] = [
            ("Telefon", record.phone, "phone"),
            ("Saatler", record.hours, "clock"),
            ("Açıklama", record.caption, "text.quote"),
            ("Diğer yazı", record.otherText, "text.alignleft"),
        ]
        if showsTechnical {
            rows.append(("Anahtar kelimeler", record.keywords, "tag"))
            rows.append(("Güven", record.confidence.map { String(format: "%.2f", $0) }, "gauge.medium"))
            rows.append(("Durum", statusText, "gearshape"))
        }
        return rows.compactMap { title, value, icon in
            guard let value, !value.isEmpty else { return nil }
            return (title, value, icon)
        }
    }

    private var statusText: String {
        switch record.status {
        case .pending: return "Nemotron bekliyor"
        case .enriched: return "Yapılandırıldı"
        case .failed: return "Yapılandırılamadı (yalnız OCR)"
        }
    }

    var body: some View {
        if facts.isEmpty {
            if record.status == .pending {
                Label("Yapay zekâ bu kaydı henüz düzenlemedi. İnternet ve anahtar varken birazdan hazır olur.", systemImage: "sparkles")
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
