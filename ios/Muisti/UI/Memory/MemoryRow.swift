import SwiftUI

struct MemoryRow: View {
    let record: MemoryRecord
    let store: MemoryStore

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            KeyframeImage(url: store.frameURL(record), maxPixel: 200)
                .frame(width: 60, height: 76)
                .clipShape(.rect(cornerRadius: Theme.Radius.small))
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(record.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if record.phone != nil || record.hours != nil || record.status == .pending {
                    FlowLayout {
                        if let phone = record.phone {
                            InfoChip(text: phone, systemImage: "phone.fill", tint: .success)
                        }
                        if let hours = record.hours {
                            InfoChip(text: hours, systemImage: "clock.fill", tint: .brandSky)
                        }
                        if record.status == .pending {
                            InfoChip(text: String(localized: "Processing"), systemImage: "sparkles", tint: .brandBlue)
                        }
                    }
                    .padding(.top, Theme.Spacing.xxs)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([record.title, subtitle, record.phone, record.hours].compactMap { $0 }.joined(separator: ", "))
    }

    private var subtitle: String {
        let time = record.seenAt.formatted(date: .omitted, time: .shortened)
        return record.street.map { "\(time) · \($0)" } ?? time
    }
}
