import SwiftUI

/// "21 memories · 3 processing · Kept 7 days" under the large "Memory" title. On iOS 26 it is
/// the system navigation subtitle (aligned with the title and the search field by the system);
/// earlier systems show the same line as the first, plain row of the list.
struct MemorySummary: ViewModifier {
    let total: Int
    let pending: Int
    let retentionDays: Int
    let visible: Bool

    var text: String {
        var parts = [total == 1 ? String(localized: "1 memory") : String(localized: "\(total) memories")]
        if pending > 0 { parts.append(String(localized: "\(pending) processing")) }
        parts.append(retentionDays == 1 ? String(localized: "Kept 1 day") : String(localized: "Kept \(retentionDays) days"))
        return parts.joined(separator: " · ")
    }

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.navigationSubtitle(visible ? text : "")
        } else {
            content
        }
    }
}

extension View {
    func memorySummary(total: Int, pending: Int, retentionDays: Int, visible: Bool) -> some View {
        modifier(MemorySummary(total: total, pending: pending, retentionDays: retentionDays, visible: visible))
    }
}
