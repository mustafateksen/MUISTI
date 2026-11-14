#if DEBUG
import Foundation

/// Retrieval + answer evaluation on the simulator (DEBUG only).
///
/// `Documents/<folder>/eval.json`: `[{"q": question, "expect": [photo files], "must": [any of] | [] | null}]`
/// - `expect` empty and `must` null → a negative: the answer must not claim it was seen.
/// - otherwise: retrieval rank = best position of an expected photo among the ranked groups;
///   answer passes when it is "seen" and contains one of `must` (if any).
/// `Documents/<folder>/ids.json` (written by the ingest) maps photo files to record ids.
/// Results: `Documents/<folder>/eval_result.json` and one `EVAL` log line per case + summary.
@MainActor
enum EvalRunner {
    struct Case: Decodable {
        let q: String
        let expect: [String]
        let must: [String]?
    }

    struct Outcome: Encodable {
        let q: String
        let negative: Bool
        let rank: Int?          // 1-based group position of the first expected record
        let label: String
        let answer: String
        let pass: Bool
        let latencyMs: Int
        let trace: String?
    }

    static func run(controller: CaptureController, folder: String) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = documents.appendingPathComponent(folder, isDirectory: true)
        guard let casesData = try? Data(contentsOf: dir.appendingPathComponent("eval.json")),
              let cases = try? JSONDecoder().decode([Case].self, from: casesData) else {
            Log.pipeline.error("EVAL: no eval.json in \(dir.path, privacy: .public)")
            return
        }
        let ids = (try? Data(contentsOf: dir.appendingPathComponent("ids.json")))
            .flatMap { try? JSONDecoder().decode([String: Int64].self, from: $0) } ?? [:]

        var outcomes: [Outcome] = []
        for c in cases {
            let negative = c.expect.isEmpty && c.must == nil
            let result = await controller.queryEngine.ask(c.q, location: nil)
            let expected = Set(c.expect.compactMap { ids[$0] })
            let rank = result.ranked.firstIndex { group in group.contains { expected.contains($0) } }.map { $0 + 1 }
            let seen = result.label == .seen
            let answer = normalize(result.answer)
            let pass: Bool
            if negative {
                pass = !seen
            } else {
                let must = (c.must ?? []).map(normalize)
                pass = seen && (must.isEmpty || must.contains { answer.contains($0) })
            }
            let outcome = Outcome(q: c.q, negative: negative, rank: rank, label: result.label.rawValue,
                                  answer: result.answer, pass: pass, latencyMs: result.latencyMs, trace: result.trace)
            outcomes.append(outcome)
            Log.pipeline.info("EVAL \(pass ? "PASS" : "FAIL", privacy: .public) r=\(rank.map(String.init) ?? "-", privacy: .public) \(result.latencyMs) ms “\(c.q, privacy: .public)” → [\(result.label.rawValue, privacy: .public)] \(result.answer, privacy: .public)")
        }

        let positives = outcomes.filter { !$0.negative }
        let negatives = outcomes.filter(\.negative)
        func recall(_ k: Int) -> Int { positives.filter { ($0.rank ?? 99) <= k }.count }
        let latencies = outcomes.map(\.latencyMs).sorted()
        let summary = "EVAL SUMMARY answers \(positives.filter(\.pass).count)/\(positives.count) · negatives \(negatives.filter(\.pass).count)/\(negatives.count) · recall@1 \(recall(1)) @3 \(recall(3)) @8 \(recall(8)) of \(positives.count) · latency p50 \(latencies[latencies.count / 2]) ms p90 \(latencies[latencies.count * 9 / 10]) ms"
        Log.pipeline.info("\(summary, privacy: .public)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(outcomes) {
            try? data.write(to: dir.appendingPathComponent("eval_result.json"))
        }
        try? summary.write(to: dir.appendingPathComponent("eval_summary.txt"), atomically: true, encoding: .utf8)
    }

    /// Lower-case, accent-folded, punctuation as spaces, single spaces.
    static func normalize(_ s: String) -> String {
        let folded = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let mapped = String(folded.map { $0.isLetter || $0.isNumber || $0 == ":" ? $0 : " " })
        return mapped.split(separator: " ").joined(separator: " ")
    }
}
#endif
