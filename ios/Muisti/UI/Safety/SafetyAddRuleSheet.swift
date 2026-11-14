import SwiftUI

/// "+" on the Safety page: the user types what to watch for in their own words, Muisti's AI
/// writes it up as a rule (a clean sentence plus when it fires), and the user adds it.
struct SafetyAddRuleSheet: View {
    let safety: SafetyMonitor
    let ai: NemotronClient

    private enum Stage: Equatable {
        case typing
        case writing
        case review(SafetyRule)
    }

    @State private var request = ""
    @State private var stage = Stage.typing
    @State private var error: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private let examples = [
        String(localized: "Stove left on when I leave"),
        String(localized: "Blood pressure pill at 8"),
        String(localized: "Milk on food labels"),
    ]

    private var trimmed: String { request.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    if case .review(let rule) = stage {
                        SafetyRulePreview(rule: rule)
                    } else {
                        editor
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.danger)
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.s)
                .animation(Theme.Motion.standard, value: stage)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { primaryButton }
            .navigationTitle("New rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            TextField("What should Muisti watch for?", text: $request, axis: .vertical)
                .lineLimit(3...6)
                .focused($focused)
                .disabled(stage == .writing)
                .padding(Theme.Spacing.m)
                .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.inner))
            FlowLayout(spacing: Theme.Spacing.xs) {
                ForEach(examples, id: \.self) { example in
                    Button(example) { request = example }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
            }
            .disabled(stage == .writing)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        Group {
            switch stage {
            case .typing:
                Button(action: write) {
                    Label("Write rule", systemImage: "sparkles").frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(trimmed.isEmpty)
            case .writing:
                Button(action: {}) {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView().tint(.white)
                        Text("Writing…")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(true)
            case .review(let rule):
                HStack(spacing: Theme.Spacing.s) {
                    Button { stage = .typing; focused = true } label: {
                        Text("Edit").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    Button { add(rule) } label: {
                        Text("Add rule").frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .font(.body.weight(.semibold))
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    private func write() {
        let text = trimmed
        guard !text.isEmpty else { return }
        error = nil
        focused = false
        stage = .writing
        Task {
            do {
                stage = .review(try await SafetyRuleWriter.draft(text, ai: ai))
            } catch {
                self.error = error.localizedDescription
                stage = .typing
            }
        }
    }

    private func add(_ rule: SafetyRule) {
        Task {
            // The same path a spoken rule takes once the user says yes.
            _ = await safety.handle(.createRule(rule))
            _ = await safety.handle(.confirm)
            dismiss()
        }
    }
}
