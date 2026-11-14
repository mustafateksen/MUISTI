import SwiftUI

/// Answered warnings, small: thumbnail, message, when, and how it was answered.
struct SafetyHistoryCard: View {
    let alerts: [SafetyAlert]
    let frameURL: (String) -> URL

    var body: some View {
        VStack(spacing: 0) {
            ForEach(alerts.prefix(20)) { alert in
                SafetyHistoryRow(alert: alert, url: alert.evidenceFrame.map(frameURL))
                if alert.id != alerts.prefix(20).last?.id {
                    Divider().padding(.leading, 84)
                }
            }
        }
        .card(padding: 0)
    }
}
