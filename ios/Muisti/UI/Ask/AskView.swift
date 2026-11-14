import SwiftUI

/// Voice Q&A: push-to-talk, live transcript, an answer labelled "Gördüm" / "Emin değilim",
/// and the evidence frames (time, street, OCR text, map pin) under it.
struct AskView: View {
    let controller: CaptureController
    let config: AppConfig
    let voice: VoiceAssistant
    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    VStack(spacing: Theme.Spacing.s) {
                        Toggle("Hey Emir ile sor", isOn: Binding(
                            get: { voice.handsFree },
                            set: { enabled in Task { await voice.setHandsFree(enabled) } }
                        ))
                        if !voice.isBusy && !voice.openingMic {
                            Picker("Soru dili", selection: Binding(
                                get: { voice.localeIdentifier },
                                set: { config.voiceLocale = $0; voice.localeIdentifier = $0 }
                            )) {
                                Text("English").tag("en-US")
                                Text("Türkçe").tag("tr-TR")
                            }.pickerStyle(.segmented)
                        }
                        VoiceOrb(voice: voice, action: toggleListening)
                            .frame(height: voice.lastResult == nil ? 320 : 220)
                        if voice.waitingForWake {
                            Text("“Hey Emir” bekleniyor…")
                        } else {
                            AskPhaseText(phase: voice.phase, transcript: voice.transcript, showsHint: voice.lastResult == nil)
                        }
                    }

                    if let result = voice.lastResult {
                        AnswerCard(result: result, store: controller.store)
                            .id(result.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if !voice.isBusy {
                        SuggestionList(onSelect: ask)
                    }

                    if voice.history.count > 1 {
                        AskHistoryList(items: Array(voice.history.dropFirst()))
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.l)
                .animation(Theme.Motion.standard, value: voice.lastResult?.id)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(alignment: .top) {
                AskBackdrop(phase: voice.phase)
            }
            .safeAreaInset(edge: .bottom) {
                AskInputBar(text: $typed, focus: $typing, isBusy: voice.isBusy, onSend: send)
            }
            .navigationTitle("Sor")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.success, trigger: voice.lastResult?.id)
        }
    }

    private func toggleListening() {
        Task { await voice.toggleListening() }
    }

    private func ask(_ question: String) {
        Task { await voice.ask(question) }
    }

    private func send() {
        let question = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !voice.isBusy else { return }
        typed = ""
        typing = false
        ask(question)
    }
}
