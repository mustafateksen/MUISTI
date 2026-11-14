import SwiftUI

/// One rule: what kind of trigger it is, what it says, what it watches, on/off.
/// Long-press to delete.
struct SafetyRuleRow: View {
    let rule: SafetyRule
    let setEnabled: (Bool) -> Void
    let delete: () -> Void
    @State private var isOn: Bool

    init(rule: SafetyRule, setEnabled: @escaping (Bool) -> Void, delete: @escaping () -> Void) {
        self.rule = rule
        self.setEnabled = setEnabled
        self.delete = delete
        _isOn = State(initialValue: rule.enabled)
    }

    private var symbol: String {
        switch rule.trigger.type {
        case .context: "house.fill"
        case .schedule: "alarm.fill"
        case .event: "bell.fill"
        case .inactivity: "hourglass"
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.gray.opacity(0.5)), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.summary)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if !rule.watch.isEmpty {
                        Text(rule.watch.map(SafetyNames.display).joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s + 2)
        .contentShape(.rect)
        .contextMenu {
            Button("Delete rule", systemImage: "trash", role: .destructive, action: delete)
        }
        .onChange(of: isOn) { _, on in
            if on != rule.enabled { setEnabled(on) }
        }
        .onChange(of: rule.enabled) { _, enabled in isOn = enabled }
        .accessibilityAction(named: "Delete rule", delete)
    }
}
