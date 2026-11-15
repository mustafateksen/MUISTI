@preconcurrency import AVFoundation
import os
import SwiftUI

/// Settings › Microphone test: one recording from the microphone a question would be heard
/// on, played back and read by every speech engine side by side, so the best one for this
/// voice and this microphone can be picked. Everything runs on the phone.
struct MicTestView: View {
    let controller: CaptureController

    struct Reading: Identifiable {
        let id: String
        let title: String
        var text: String?
        var seconds: Double?
        var engine: SpeechEngine?
    }

    @State private var engine = SpeechSettings.engine
    @State private var neuralEndpoint = SpeechSettings.neuralEndpoint
    @State private var voiceProcessing = SpeechSettings.voiceProcessing
    @State private var endSilence = SpeechSettings.endSilence
    @State private var recording = false
    @State private var working = false
    @State private var input = ""
    @State private var message: String?
    @State private var samples: [Float] = []
    @State private var readings: [Reading] = []
    @State private var speechNote: String?
    @State private var capture: MicCapture?
    @State private var player: AVAudioPlayer?
    @State private var stopTask: Task<Void, Never>?
    private let box = SampleBox()
    private var status: SpeechModelStatus { SpeechModelStatus.shared }

    var body: some View {
        Form {
            Section {
                Picker("Speech engine", selection: $engine) {
                    Text("Automatic").tag(SpeechEngine.automatic)
                    Text("Parakeet").tag(SpeechEngine.parakeet)
                    Text("Apple").tag(SpeechEngine.apple)
                }
                .onChange(of: engine) {
                    SpeechSettings.engine = engine
                    if engine != .apple { Task { await SpeechLab.shared.prepareParakeet(controller.voice.localeIdentifier) } }
                }
                LabeledContent("Parakeet", value: label(status.parakeet, bundled: SpeechLab.parakeetBundled(controller.voice.localeIdentifier)))
                LabeledContent("Speech detector", value: label(status.endpoint, bundled: SpeechLab.endpointBundled))
                LabeledContent("Question language", value: controller.voice.localeIdentifier)
            } header: {
                Text("Engine")
            } footer: {
                Text("Automatic uses Parakeet when it is in the app and reads the question language (an English-only model for English; Finnish and 23 other European languages with a second one), Apple's model otherwise. Every engine runs on this iPhone: the audio of a question is not sent anywhere.")
            }

            Section {
                Toggle("Tell speech from noise with a model", isOn: $neuralEndpoint)
                    .onChange(of: neuralEndpoint) { SpeechSettings.neuralEndpoint = neuralEndpoint }
                Stepper("Stop after \(endSilence, specifier: "%.1f") s of silence", value: $endSilence, in: 0.6...2.5, step: 0.1)
                    .onChange(of: endSilence) { SpeechSettings.endSilence = endSilence }
                Toggle("iOS noise suppression (phone or headset mic)", isOn: $voiceProcessing)
                    .onChange(of: voiceProcessing) { SpeechSettings.voiceProcessing = voiceProcessing }
            } header: {
                Text("When to stop listening")
            } footer: {
                Text("With the model, a street, a fan or music no longer counts as you still speaking. The silence setting applies to Parakeet; Apple's model keeps its own longer pauses.")
            }

            Section {
                Button(recording ? String(localized: "Stop") : String(localized: "Record a sentence"),
                       systemImage: recording ? "stop.circle.fill" : "mic.circle.fill") {
                    Task { recording ? await stopRecording() : await startRecording() }
                }
                .disabled(working)
                if !input.isEmpty { LabeledContent("Microphone", value: input) }
                if let message { Text(message).foregroundStyle(.secondary) }
                if !samples.isEmpty, !recording {
                    Button("Play it back", systemImage: "play.circle") { play() }
                    if let speechNote { Text(speechNote).font(.footnote).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Test")
            } footer: {
                Text("Say a question the way you would ask it, up to 15 seconds. Play it back to hear what the microphone caught; below, each engine's reading of the same recording.")
            }

            if !readings.isEmpty {
                Section("Readings") {
                    ForEach(readings) { reading in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(reading.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                if let seconds = reading.seconds {
                                    Text("\(seconds, specifier: "%.2f") s").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            if let text = reading.text {
                                Text(text.isEmpty ? String(localized: "(nothing heard)") : text)
                                    .textSelection(.enabled)
                            } else {
                                ProgressView()
                            }
                            if let choice = reading.engine, reading.text != nil {
                                Button(engine == choice ? String(localized: "In use") : String(localized: "Use this engine")) {
                                    engine = choice
                                }
                                .disabled(engine == choice)
                                .font(.footnote)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Microphone test")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await SpeechLab.shared.prepareEndpoint()
            if engine != .apple { await SpeechLab.shared.prepareParakeet(controller.voice.localeIdentifier) }
        }
        .onDisappear {
            stopTask?.cancel()
            capture?.stop()
            player?.stop()
            controller.voice.closeTestMicrophone()
        }
    }

    private func label(_ phase: SpeechModelStatus.Phase, bundled: Bool) -> String {
        guard bundled else { return String(localized: "Not in this build") }
        switch phase {
        case .missing: return String(localized: "In the app, not loaded yet")
        case .loading: return String(localized: "Loading…")
        case .ready: return String(localized: "Ready")
        case .failed(let why): return String(localized: "Failed: \(why)")
        }
    }

    private func startRecording() async {
        player?.stop()
        message = nil
        readings = []
        speechNote = nil
        do {
            let opened = try await controller.voice.openTestMicrophone()
            input = opened.input
            box.reset()
            let box = box
            try opened.capture.start(onSamples: { box.append($0) }, onFrame: { _ in })
            capture = opened.capture
            recording = true
            stopTask = Task {
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled { await stopRecording() }
            }
        } catch {
            message = error.localizedDescription
            controller.voice.closeTestMicrophone()
        }
    }

    private func stopRecording() async {
        guard recording else { return }
        recording = false
        stopTask?.cancel()
        capture?.stop()
        capture = nil
        controller.voice.closeTestMicrophone()
        samples = box.take()
        guard samples.count >= 8_000 else {
            message = String(localized: "Nothing was recorded. Is the microphone allowed?")
            return
        }
        working = true
        defer { working = false }
        let locale = controller.voice.localeIdentifier
        let audio = samples
        // How much of it the speech detector calls speech, and where the speech ends.
        let trace = await SpeechLab.shared.speechTrace(audio)
        if !trace.isEmpty {
            let voiced = trace.filter { $0 >= VoiceGate.threshold }.count
            let last = trace.lastIndex { $0 >= VoiceGate.threshold }.map { Double($0 + 1) * 0.256 }
            let total = Double(audio.count) / 16_000
            let level = 20 * log10(max(sqrt(audio.reduce(0) { $0 + $1 * $1 } / Float(audio.count)), 1e-7))
            speechNote = String(localized: "\(total, specifier: "%.1f") s recorded, \(Double(voiced) * 0.256, specifier: "%.1f") s of it speech\(last.map { String(localized: ", ending at \($0, specifier: "%.1f") s") } ?? ""). Level \(level, specifier: "%.0f") dBFS.")
        }
        readings = [
            Reading(id: "parakeet", title: "Parakeet", engine: .parakeet),
            Reading(id: "apple", title: String(localized: "Apple (general model)"), engine: .apple),
            Reading(id: "dictation", title: String(localized: "Apple (dictation model)")),
            Reading(id: "legacy", title: String(localized: "Apple (older recogniser)")),
        ]
        await read("parakeet") {
            guard await SpeechLab.shared.prepareParakeet(locale) else { return nil }
            return await SpeechLab.shared.transcribe(audio, localeIdentifier: locale)
        }
        await read("apple") { await AppleSpeechTest.modern(audio, localeIdentifier: locale, dictation: false) }
        await read("dictation") { await AppleSpeechTest.modern(audio, localeIdentifier: locale, dictation: true) }
        await read("legacy") { await AppleSpeechTest.legacy(audio, localeIdentifier: locale) }
    }

    private func read(_ id: String, _ run: @Sendable () async -> String?) async {
        let began = Date()
        let text = await run()
        guard let index = readings.firstIndex(where: { $0.id == id }) else { return }
        readings[index].text = text ?? String(localized: "(not available on this phone)")
        readings[index].seconds = text == nil ? nil : Date().timeIntervalSince(began)
        if text == nil { readings[index].engine = nil }
    }

    private func play() {
        guard let buffer = Resampler16k.buffer(samples) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-test.wav")
        try? FileManager.default.removeItem(at: url)
        do {
            // Scope the file so it is closed (and its header written) before it is played.
            do {
                let file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                ])
                try file.write(from: buffer)
            }
            try? VoiceAssistant.activatePlaybackSession()
            let made = try AVAudioPlayer(contentsOf: url)
            made.play()
            player = made
        } catch {
            message = error.localizedDescription
        }
    }
}

/// The samples of the recording in progress (filled on the audio thread).
private final class SampleBox: @unchecked Sendable {
    private let samples = OSAllocatedUnfairLock(initialState: [Float]())
    func reset() { samples.withLock { $0 = [] } }
    func append(_ more: [Float]) { samples.withLock { if $0.count < 16_000 * 20 { $0 += more } } }
    func take() -> [Float] { samples.withLock { $0 } }
}
