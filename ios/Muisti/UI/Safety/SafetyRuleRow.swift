import SwiftUI

/// One rule: trigger symbol, its sentence, when it fires, on/off.
struct SafetyRuleRow: View {
    let rule: SafetyRule
    let setEnabled: (Bool) -> Void
    @State private var isOn: Bool

    init(rule: SafetyRule, setEnabled: @escaping (Bool) -> Void) {
        self.rule = rule
        self.setEnabled = setEnabled
        _isOn = State(initialValue: rule.enabled)
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: rule.triggerSymbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.gray.opacity(0.45)), in: .rect(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.summary)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(rule.triggerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .onChange(of: isOn) { _, on in
            if on != rule.enabled { setEnabled(on) }
        }
        .onChange(of: rule.enabled) { _, enabled in isOn = enabled }
    }
}
