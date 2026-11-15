import AudioToolbox
import Foundation
import MWDATCore
import MWDATSpeech
import Observation

/// Hands-free voice through the glasses (`MWDATSpeech`, experimental in DAT 1.0): the glasses
/// transcribe on their own chip and only text crosses the link, so the camera stream keeps its
/// bandwidth (the phone's Bluetooth HFP mic stalled it). Needs `Permission.microphone`, asked
/// once through Meta AI.
///
/// The wake word is the user's setting, matched loosely (the recogniser spells an unknown name
/// in different ways): a word within two edits of it and of similar length counts. After the
/// wake word, the rest of that sentence — or the next final sentence — is the question.
@Observable
@MainActor
final class GlassesSpeech {
    /// A question for Muisti, already without the wake word.
    @ObservationIgnored var onQuestion: (String) -> Void = { _ in }
    /// Muisti is thinking or talking: ignore what the mic hears (its own voice included).
    @ObservationIgnored var isBusy: () -> Bool = { false }
    /// The wake word was heard (a chime through the glasses).
    @ObservationIgnored var onWake: () -> Void = {}
    var wakeWord = "Muisti"
    /// How these glasses actually spell the wake word (learned from the user saying it, see
    /// `learnWakeWord`): an unknown name comes out as the nearest known word ("music").
    var aliases: [String] = []
    /// Learning in progress: collects what the glasses write for the wake word.
    private(set) var learning: [String]?
    @ObservationIgnored private var learnDone: (([String]) -> Void)?
    private var learnWanted = 3

    private(set) var isListening = false
    private(set) var lastHeard = ""
    private(set) var locale: String?

    @ObservationIgnored private var speech: Speech?
    @ObservationIgnored private var tokens: [any AnyListenerToken] = []
    private var wanted = false
    private var armedUntil: Date?
    /// When the wake word was acknowledged mid-sentence (so the final does not repeat it).
    private var acknowledgedAt: Date?
    private var reviveAttempts = 0

    func attach(to session: DeviceSession) {
        guard speech == nil else { return }
        wanted = true
        do throws(DeviceSessionError) {
            guard let newSpeech = try session.addSpeech() else {
                Log.glasses.info("glasses speech unavailable on this device")
                return
            }
            speech = newSpeech
            tokens.append(newSpeech.transcriptionPublisher.listen { [weak self] result in
                Task { @MainActor in self?.heard(result.text, isFinal: result.isFinal) }
            })
            tokens.append(newSpeech.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.stateChanged(state) }
            })
            tokens.append(newSpeech.errorPublisher.listen { error in
                Log.glasses.info("glasses speech error: \(error.description, privacy: .public)")
            })
            tokens.append(newSpeech.localePublisher.listen { [weak self] locale in
                Task { @MainActor in self?.locale = locale }
            })
            newSpeech.start()
            Log.glasses.info("glasses speech started")
        } catch {
            Log.glasses.info("glasses speech not added: \(error.description, privacy: .public)")
        }
    }

    func detach() {
        wanted = false
        speech?.stop()
        tokens.forEach { token in Task { await token.cancel() } }
        tokens = []
        speech = nil
        isListening = false
        armedUntil = nil
    }

    /// Muisti asked a yes/no question: the next sentence is the answer, no wake word needed.
    func expectReply(for seconds: TimeInterval = 10) {
        armedUntil = Date().addingTimeInterval(seconds)
    }

    private func stateChanged(_ state: SpeechState) {
        Log.glasses.info("glasses speech → \(state.description, privacy: .public)")
        switch state {
        case .started:
            isListening = true
            reviveAttempts = 0
        case .stopped:
            isListening = false
            // A photo capture or a hiccup stops listening; start again while we want it.
            guard wanted, let speech, reviveAttempts < 5 else { return }
            reviveAttempts += 1
            Task {
                try? await Task.sleep(for: .seconds(Double(self.reviveAttempts)))
                guard self.wanted else { return }
                speech.start()
            }
        default:
            break
        }
    }

    /// A finished utterance from the phone recogniser running on the glasses mic's audio.
    /// `better`: the same audio read by the more accurate model (Parakeet), when there is one.
    /// The wake word is still found in `text` (the recogniser biased to it); the question's
    /// words come from `better`.
    func utterance(_ text: String, source: String, better: String? = nil) {
        heard(text, isFinal: true, source: source, better: better)
    }

    /// This utterance will become a question (it holds the wake word, or the wake word was
    /// just said): worth reading again with the better model.
    func leadsToQuestion(_ text: String) -> Bool {
        guard !isBusy(), learning == nil else { return false }
        if let until = armedUntil, Date() < until { return true }
        return wakeIndex(in: Self.words(text)) != nil
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    /// A partial transcript from the phone recogniser (wake word acknowledgement only).
    func partial(_ text: String) {
        heard(text, isFinal: false, source: "phone")
    }

    private func heard(_ text: String, isFinal: Bool, source: String = "glasses", better: String? = nil) {
        lastHeard = text
        if isFinal { Log.glasses.info("\(source, privacy: .public) heard: “\(text, privacy: .public)”\(self.isBusy() ? " (busy, ignored)" : "")") }
        guard !isBusy() else { return }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        // Mid-sentence: answer "yes?" as soon as the wake word shows up; the question itself
        // is taken from the finished sentence.
        if !isFinal {
            if learning == nil, wakeIndex(in: words) != nil, Date().timeIntervalSince(lastWakeAt) > 6 {
                acknowledgedAt = Date()
                lastWakeAt = Date()
                onWake()
            }
            return
        }
        if var learned = learning {
            // Teaching: the user says only the wake word; keep how it was written.
            let phrase = Self.normalized(words).filter { !$0.isEmpty }.joined(separator: " ")
            if !phrase.isEmpty { learned.append(phrase) }
            learning = learned
            if learned.count >= learnWanted { finishLearning() }
            return
        }
        if let better, !better.isEmpty { Log.glasses.info("parakeet heard: “\(better, privacy: .public)”") }
        if let index = wakeIndex(in: words) {
            var rest = words[index...].joined(separator: " ")
            if let better, !better.isEmpty {
                // The question as the better model wrote it: after the wake word where that
                // model wrote one too, else after as many words as the wake word took.
                let again = Self.words(better)
                let start = wakeIndex(in: again) ?? min(index, again.count)
                rest = again[start...].joined(separator: " ")
            }
            // Heard only now (no partial showed it): the microphone opens for the question.
            if Date().timeIntervalSince(lastWakeAt) > 6 {
                lastWakeAt = Date()
                onWake()
                return
            }
            acknowledgedAt = nil
            if rest.split(separator: " ").count >= 2 {
                armedUntil = nil
                ask(rest)
            } else {
                armedUntil = Date().addingTimeInterval(8)
            }
            return
        }
        if let until = armedUntil, Date() < until {
            armedUntil = nil
            ask(better.flatMap { $0.isEmpty ? nil : $0 } ?? text)
        }
    }

    /// Index of the first word after the wake word or a learned spelling of it, if present.
    private func wakeIndex(in words: [String]) -> Int? {
        let norm = Self.normalized(words)
        for alias in aliases {
            let parts = alias.split(separator: " ").map(String.init)
            guard !parts.isEmpty, parts.count <= norm.count else { continue }
            for start in 0...(norm.count - parts.count) where Array(norm[start..<start + parts.count]) == parts {
                return start + parts.count
            }
        }
        // The wake word may be a phrase ("Hey Meta"): its words in a row, each matched loosely.
        let phrase = Self.normalized(wakeWord.split(separator: " ").map(String.init)).filter { !$0.isEmpty }
        guard !phrase.isEmpty, phrase.count <= norm.count else { return nil }
        for start in 0...(norm.count - phrase.count)
        where zip(norm[start..<start + phrase.count], phrase).allSatisfy({ Self.sounds($0, like: $1) }) {
            return start + phrase.count
        }
        return nil
    }

    /// When the wake phrase last opened the microphone (the glasses' recogniser and the
    /// phone's both hear it, a moment apart: one opening, not two).
    private var lastWakeAt = Date.distantPast

    /// What follows the wake phrase in `text` ("Hey Meta. Where is the lab?" → "Where is the
    /// lab?"); the text itself when the phrase is not in it. Empty: only the phrase was said.
    func afterWake(_ text: String) -> String {
        let words = Self.words(text)
        guard let index = wakeIndex(in: words) else { return text }
        // Cut the original text (with its punctuation) after that many words.
        var seen = 0, inWord = false
        for position in text.indices {
            let character = text[position]
            let isWord = character.isLetter || character.isNumber || character == "'"
            if isWord, !inWord { seen += 1 }
            if !isWord, inWord, seen == index {
                return String(text[position...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "?!")))
                    .replacingOccurrences(of: "^[?!\\s]+", with: "", options: .regularExpression)
            }
            inWord = isWord
        }
        return ""
    }

    /// The glasses' own recogniser and the phone's hear the same sentence: one question, not two.
    private var lastQuestionAt = Date.distantPast
    private func ask(_ question: String) {
        guard Date().timeIntervalSince(lastQuestionAt) > 4 else { return }
        lastQuestionAt = Date()
        onQuestion(question)
    }

    /// Teach the wake word: the next `count` sentences (the user saying only the wake word) are
    /// stored as its spellings. Ends after `timeout` with whatever was heard.
    func learnWakeWord(count: Int = 3, timeout: TimeInterval = 30, done: @escaping ([String]) -> Void) {
        learning = []
        learnWanted = count
        learnDone = done
        Task {
            try? await Task.sleep(for: .seconds(timeout))
            if self.learning != nil { self.finishLearning() }
        }
    }

    private func finishLearning() {
        let heard = learning ?? []
        learning = nil
        // Spellings heard at least once; the most frequent first. The wake word's own fuzzy
        // match still applies.
        var counts: [String: Int] = [:]
        heard.forEach { counts[$0, default: 0] += 1 }
        let spellings = counts.sorted { $0.value > $1.value }.map(\.key)
        Log.glasses.info("wake word learned as: \(spellings, privacy: .public)")
        learnDone?(spellings)
        learnDone = nil
    }

    static func normalized(_ words: [String]) -> [String] {
        words.map { $0.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter(\.isLetter) }
    }

    /// Loose match for a recognised word against the wake word: similar length, at most two
    /// edits (case and accents ignored).
    static func sounds(_ word: String, like wake: String) -> Bool {
        let a = Array(word.lowercased().folding(options: .diacriticInsensitive, locale: nil))
        let b = Array(wake.lowercased().folding(options: .diacriticInsensitive, locale: nil))
        guard a.count >= 3, abs(a.count - b.count) <= 1 else { return false }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count] <= (b.count >= 6 ? 2 : 1)
    }
}
