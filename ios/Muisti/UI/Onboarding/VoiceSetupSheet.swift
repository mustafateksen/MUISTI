import SwiftUI

/// First-run step (also in Settings › Voice): Apple's built-in voice sounds robotic and Siri
/// voices are closed to apps, so Muisti asks the user to download Ava (Premium) once in
/// Settings. Apps can't open that page or start the download; this sheet shows the steps and
/// notices by itself when Ava is installed (checked whenever the app comes back).
struct VoiceSetupSheet: View {
    let previewVoice: () async -> Void
    @State private var installed = VoicePicker.hasPremiumAva
    @State private var otherLanguage = VoiceSetupSheet.phoneLanguageNeedingVoice
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Give Muisti a natural voice")
                            .font(.title2.bold())
                        Text("The iPhone's built-in voice sounds robotic, and Siri voices can't be used by apps. Ava (Premium) is Apple's most natural English voice. It's free and works offline.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VoiceSetupStatus(installed: installed)

                    if !installed {
                        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                            VoiceSetupStep(number: 1, text: String(localized: "Open the Settings app › Accessibility › Spoken Content › Voices."))
                            VoiceSetupStep(number: 2, text: String(localized: "Choose English › Ava, then download Ava (Premium)."))
                            VoiceSetupStep(number: 3, text: String(localized: "Come back to Muisti. It switches to Ava by itself."))
                        }
                        .card(padding: Theme.Spacing.l)
                    }

                    if let otherLanguage {
                        Label(String(localized: "Muisti answers in the language you ask in. For \(otherLanguage), download a voice marked Premium or Enhanced in the same place."),
                              systemImage: "globe")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .safeAreaInset(edge: .bottom) { buttons }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private var buttons: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                Task { await previewVoice() }
            } label: {
                Label("Listen", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            Button {
                dismiss()
            } label: {
                Text(installed ? "Done" : "I'll do it now").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .buttonBorderShape(.capsule)
        .font(.body.weight(.semibold))
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    private func refresh() {
        withAnimation(Theme.Motion.standard) {
            installed = VoicePicker.hasPremiumAva
            otherLanguage = Self.phoneLanguageNeedingVoice
        }
    }

    /// The phone's language when it isn't English and has no Premium/Enhanced voice yet.
    static var phoneLanguageNeedingVoice: String? {
        guard let code = Locale.preferredLanguages.first.map(VoicePicker.languageCode), code != "en",
              !VoicePicker.hasNaturalVoice(for: code) else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)
    }
}
