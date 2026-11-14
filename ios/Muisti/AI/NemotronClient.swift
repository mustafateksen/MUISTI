import Foundation

/// NVIDIA API (OpenAI-compatible) called straight from the phone.
/// - Chat + vision: `nvidia/nemotron-3.5-super-vl-120b-a12b`
/// - Embeddings: `nvidia/nemotron-3.5-embed-1b` (falls back to keyword search if unavailable)
/// - Reranking: `nvidia/nemotron-3.5-rerank-8b` (fallback `llama-nemotron-rerank-vl-1b-v2`)
/// Free tier is roughly 40 requests/min per key; calls are spaced and retried on 429/5xx.
actor NemotronClient {
    struct Settings: Sendable, Equatable {
        var baseURL = Provider.verda.baseURL
        var chatModel = Provider.verda.chatModel
        var embedModel = Provider.verda.embedModel   // empty = no embeddings, keyword search only
        var apiKey = ""
        /// Embeddings may live on another host (NVIDIA build, own Verda container). nil/empty = same as chat.
        var embedBaseURL: URL?
        var embedKey = ""
        /// Empty = no reranking (fused order is used as is).
        var rerankModel = NemotronClient.defaultRerankModel
        var rerankKey = ""

        var effectiveEmbedURL: URL { embedBaseURL ?? baseURL }
        var effectiveEmbedKey: String { embedKey.isEmpty ? apiKey : embedKey }
        /// NVIDIA keys work across build.nvidia.com models; a Verda key does not.
        var effectiveRerankKey: String { rerankKey.isEmpty ? embedKey : rerankKey }
    }

    static let defaultRerankModel = "nvidia/nemotron-3.5-rerank-8b"
    static let fallbackRerankModel = "nvidia/llama-nemotron-rerank-vl-1b-v2"
    static func rerankURL(_ model: String) -> URL {
        URL(string: "https://ai.api.nvidia.com/v1/retrieval/\(model)/reranking")!
    }

    /// Two known OpenAI-compatible hosts for Nemotron 3.5 Super VL.
    enum Provider: String, CaseIterable, Sendable, Identifiable {
        case verda, nvidia
        var id: String { rawValue }
        var label: String { self == .verda ? "Verda (Junction)" : "NVIDIA build.nvidia.com" }
        var baseURL: URL {
            switch self {
            case .verda: return URL(string: "https://containers.datacrunch.io/nemotron-3-5-super-vl-b300/v1")!
            case .nvidia: return URL(string: "https://integrate.api.nvidia.com/v1")!
            }
        }
        var chatModel: String { self == .verda ? "nemotron-3.5-super-vl" : "nvidia/nemotron-3.5-super-vl-120b-a12b" }
        /// Verda serves only the VL model (no /embeddings).
        var embedModel: String { self == .verda ? "" : "nvidia/nemotron-3.5-embed-1b" }   // single inputs only (batches 500 now and then)
    }

    enum NemotronError: Error, LocalizedError {
        case missingKey
        /// A background request cancelled so a question could go first; retry later, not a failure.
        case preempted
        case http(Int, String)
        case badResponse(String)

        var isRetryable: Bool {
            switch self {
            case .http(let status, _): return status == 429 || status >= 500
            case .badResponse: return true
            case .missingKey, .preempted: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .missingKey: return "No Nemotron API key (Settings > Nemotron)."
            case .preempted: return "Deferred for a question."
            case .http(401, _), .http(403, _): return "Nemotron API key is invalid."
            case .http(429, _): return "Nemotron rate limit reached; will retry shortly."
            case .http(let code, let body): return "Nemotron \(code): \(body.prefix(160))"
            case .badResponse(let why): return "Couldn't read Nemotron response: \(why)"
            }
        }
    }

    private var settings: Settings
    private let session: URLSession
    /// Next free send slot per host, for paced (background, NVIDIA free tier) requests.
    private var nextSlot: [String: ContinuousClock.Instant] = [:]
    /// ≥ 1.6 s between background calls keeps a single NVIDIA key under ~40/min, with room left
    /// for questions (which are never paced). The team's own Verda container has no such limit.
    private let minSpacing: Duration = .milliseconds(1600)

    // MARK: Route latency

    /// How long chat calls took on each host lately (seconds, smoothed). The shared Verda
    /// container went from ~0.5 s to 6–14 s per call when it was busy (probe, 14 Nov) while the
    /// same model on NVIDIA build answered in ~0.8 s; calls follow the host that is fast now.
    private var routeLatency: [Route: (seconds: Double, at: ContinuousClock.Instant)] = [:]
    /// A measurement older than this says nothing: the host is tried again.
    private static let latencyMemory: Duration = .seconds(90)
    /// Above this the configured host counts as slow.
    private static let slowSeconds = 2.5

    private func recentLatency(_ route: Route) -> Double? {
        guard let entry = routeLatency[route], ContinuousClock.now - entry.at < Self.latencyMemory else { return nil }
        return entry.seconds
    }

    /// `completed` false = the call was cancelled or failed after `seconds`: the host is at least that slow.
    private func noteLatency(_ route: Route, seconds: Double, completed: Bool) {
        let known = recentLatency(route)
        if completed {
            routeLatency[route] = (known.map { $0 * 0.5 + seconds * 0.5 } ?? seconds, .now)
        } else if seconds > (known ?? 0) {
            routeLatency[route] = (seconds, .now)
        }
    }

    /// The host a call goes to when the caller does not say: the configured one unless it is
    /// slow right now and the other is not.
    private func preferredRoute() -> Route {
        guard fallbackAvailable, let primary = recentLatency(.primary), primary > Self.slowSeconds,
              (recentLatency(.fallback) ?? 0) < primary else { return .primary }
        return .fallback
    }

    /// Order for a question call that races both hosts: the first starts now, the second after
    /// `hedgeAfter` seconds if the first has not answered.
    struct QuestionPlan: Sendable {
        var first: Route
        var second: Route?
        var hedgeAfter: Double
    }

    func questionPlan() -> QuestionPlan {
        guard fallbackAvailable else { return QuestionPlan(first: .primary, second: nil, hedgeAfter: 0) }
        let primary = recentLatency(.primary)
        if preferredRoute() == .fallback { return QuestionPlan(first: .fallback, second: .primary, hedgeAfter: 1.5) }
        return QuestionPlan(first: .primary, second: .fallback, hedgeAfter: min(2.0, max(0.8, (primary ?? 0.8) * 1.6)))
    }

    /// For the trace: "verda 0.6 s · nvidia 0.8 s".
    var latencySummary: String {
        [Route.primary, .fallback].compactMap { route in
            recentLatency(route).map { "\(route == .primary ? "primary" : "fallback") \(String(format: "%.1f", $0)) s" }
        }.joined(separator: " · ")
    }

    init(settings: Settings) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func update(_ settings: Settings) {
        if settings.rerankModel != self.settings.rerankModel || settings.effectiveRerankKey != self.settings.effectiveRerankKey {
            rerankOverride = nil
            rerankUnavailable = false
        }
        if settings.effectiveEmbedURL != self.settings.effectiveEmbedURL || settings.embedModel != self.settings.embedModel
            || settings.effectiveEmbedKey != self.settings.effectiveEmbedKey {
            embeddingsUnavailable = false
        }
        self.settings = settings
    }
    var hasKey: Bool { !settings.apiKey.isEmpty }

    /// Questions in flight. Background enrichment waits while > 0, so a spoken question never
    /// queues behind frame extraction on the same (sometimes slow) Verda endpoint.
    private(set) var questionsInFlight = 0
    /// Background (enrichment) requests in flight; a question cancels them so it is served first.
    private var backgroundRequests: [UUID: Task<(Data, URLResponse), Error>] = [:]

    func beginQuestion() {
        questionsInFlight += 1
        if !backgroundRequests.isEmpty {
            Log.net.info("question: pre-empting \(self.backgroundRequests.count) background request(s)")
            backgroundRequests.values.forEach { $0.cancel() }
            backgroundRequests.removeAll()
        }
    }
    func endQuestion() { questionsInFlight = max(0, questionsInFlight - 1) }
    /// Set after the host answers 404/400 for embeddings, so we stop spending calls on it.
    private var embeddingsUnavailable = false
    var embeddingsEnabled: Bool {
        !settings.embedModel.isEmpty && !settings.effectiveEmbedKey.isEmpty && !embeddingsUnavailable
    }
    /// Model name stored next to each vector (vectors of different models never mix).
    var embedModelName: String { settings.embedModel }

    /// Set when the configured reranker is gone (404/410) and the fallback answered instead.
    private var rerankOverride: String?
    private var rerankUnavailable = false
    var rerankEnabled: Bool { !settings.rerankModel.isEmpty && !settings.effectiveRerankKey.isEmpty && !rerankUnavailable }
    var rerankModelName: String { rerankOverride ?? settings.rerankModel }

    // MARK: Chat

    struct ImagePart: Sendable {
        let jpeg: Data
    }

    /// Hosts that rejected `response_format: json_schema`; they get `json_object` instead.
    private var schemaUnsupportedHosts: Set<String> = []

    /// One chat turn: system → few-shot user/assistant pairs → user text (then the image).
    /// Returns the assistant text. Reasoning is disabled: it eats `max_tokens` and can leave
    /// `content` empty (team measurement: 6.3 s → 0.44 s per frame, same accuracy).
    /// `jsonSchema` (JSON text) turns on guided decoding.
    /// Where a chat call goes: the configured host (Verda) or the NVIDIA build fallback.
    enum Route: Sendable { case primary, fallback }

    /// Same Nemotron 3.5 Super VL on build.nvidia.com, with the NVIDIA key (rerank/embed key).
    var fallbackAvailable: Bool {
        !settings.effectiveRerankKey.isEmpty && settings.baseURL.host != Provider.nvidia.baseURL.host
    }

    func chat(system: String, user: String, image: ImagePart? = nil, examples: [(user: String, assistant: String)] = [],
              jsonSchema: String? = nil, schemaName: String = "record",
              maxTokens: Int = 700, temperature: Double = 0,
              route requested: Route? = nil, background: Bool = false) async throws -> String {
        let route = requested ?? preferredRoute()
        let baseURL = route == .primary ? settings.baseURL : Provider.nvidia.baseURL
        let model = route == .primary ? settings.chatModel : Provider.nvidia.chatModel
        let key = route == .primary ? settings.apiKey : settings.effectiveRerankKey
        var content: [[String: Any]] = [["type": "text", "text": user]]
        if let image {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(image.jpeg.base64EncodedString())"],
            ])
        }
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for example in examples {
            messages.append(["role": "user", "content": example.user])
            messages.append(["role": "assistant", "content": example.assistant])
        }
        messages.append(["role": "user", "content": content])
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "top_p": 0.95,
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        let host = baseURL.host ?? ""
        let url = baseURL.appendingPathComponent("chat/completions")
        let sent = ContinuousClock.now
        var completed = false
        defer { noteLatency(route, seconds: (ContinuousClock.now - sent).seconds, completed: completed) }
        var data: Data
        if let jsonSchema, !schemaUnsupportedHosts.contains(host),
           let schema = try? JSONSerialization.jsonObject(with: Data(jsonSchema.utf8)) {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": schemaName, "schema": schema]]
            do {
                data = try await post(url, json: body, key: key, background: background)
            } catch NemotronError.http(let status, _) where status == 400 || status == 422 {
                schemaUnsupportedHosts.insert(host)
                Log.net.info("json_schema rejected by \(host, privacy: .public) (\(status)); using json_object")
                body["response_format"] = ["type": "json_object"]
                data = try await post(url, json: body, key: key, background: background)
            }
        } else {
            if jsonSchema != nil { body["response_format"] = ["type": "json_object"] }
            data = try await post(url, json: body, key: key, background: background)
        }
        completed = true
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String
        else { throw NemotronError.badResponse("missing choices[0].message.content") }
        return text
    }

    /// Chat whose answer must be a JSON object; tolerant of code fences / prose around it.
    func chatJSON<T: Decodable>(_ type: T.Type, system: String, user: String, image: ImagePart? = nil,
                                examples: [(user: String, assistant: String)] = [], jsonSchema: String? = nil,
                                schemaName: String = "record", maxTokens: Int = 700, temperature: Double = 0,
                                route: Route? = nil, background: Bool = false) async throws -> T {
        let text = try await chat(system: system, user: user, image: image, examples: examples, jsonSchema: jsonSchema,
                                  schemaName: schemaName, maxTokens: maxTokens, temperature: temperature,
                                  route: route, background: background)
        guard let json = Self.extractJSONObject(text) else {
            throw NemotronError.badResponse("no JSON found: \(text.prefix(120))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw NemotronError.badResponse("couldn't decode JSON: \(error.localizedDescription)")
        }
    }

    // MARK: Embeddings

    enum EmbedKind: String { case passage, query }

    func embed(_ text: String, as kind: EmbedKind) async throws -> [Float] {
        guard embeddingsEnabled else { throw NemotronError.badResponse("embeddings off") }
        var body: [String: Any] = [
            "model": settings.embedModel,
            "input": [String(text.prefix(4000))],
            "encoding_format": "float",
        ]
        if settings.effectiveEmbedURL.host?.hasSuffix("nvidia.com") == true {
            // NVIDIA's retriever API wants the query/passage role explicitly.
            body["input_type"] = kind.rawValue
            body["truncate"] = "END"
        } else {
            // vLLM & co.: express the role the way retrieval embedders are trained.
            body["input"] = ["\(kind == .query ? "query" : "passage"): \(text.prefix(4000))"]
        }
        let data: Data
        do {
            data = try await post(settings.effectiveEmbedURL.appendingPathComponent("embeddings"), json: body, key: settings.effectiveEmbedKey,
                                  paced: kind == .passage)
        } catch NemotronError.http(let status, let message) where status == 404 || status == 400 || status == 422 {
            embeddingsUnavailable = true
            Log.net.info("embeddings unavailable on this host (\(status)); keyword search only")
            throw NemotronError.http(status, message)
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["data"] as? [[String: Any]],
            let vector = items.first?["embedding"] as? [Double]
        else { throw NemotronError.badResponse("missing embedding") }
        return vector.map(Float.init)
    }

    // MARK: Reranking

    /// Cross-encoder relevance of each passage to the query: one logit per passage, same order.
    func rerank(query: String, passages: [String], paced: Bool = false) async throws -> [Double] {
        guard rerankEnabled else { throw NemotronError.badResponse("reranking off") }
        guard !passages.isEmpty else { return [] }
        let model = rerankModelName
        do {
            return try await rerank(query: query, passages: passages, model: model, paced: paced)
        } catch NemotronError.http(let status, let message) where status == 404 || status == 410 {
            guard model != Self.fallbackRerankModel else {
                rerankUnavailable = true
                throw NemotronError.http(status, message)
            }
            Log.net.info("reranker \(model, privacy: .public) gone (\(status)); using \(Self.fallbackRerankModel, privacy: .public)")
            rerankOverride = Self.fallbackRerankModel
            return try await rerank(query: query, passages: passages, model: Self.fallbackRerankModel, paced: paced)
        }
    }

    private func rerank(query: String, passages: [String], model: String, paced: Bool) async throws -> [Double] {
        let body: [String: Any] = [
            "model": model,
            "query": ["text": String(query.prefix(500))],
            "passages": passages.map { ["text": String($0.prefix(1200))] },
            "truncate": "END",
        ]
        let data = try await post(Self.rerankURL(model), json: body, key: settings.effectiveRerankKey, maxAttempts: 2, paced: paced)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rankings = root["rankings"] as? [[String: Any]]
        else { throw NemotronError.badResponse("missing rankings") }
        var logits = [Double](repeating: -.infinity, count: passages.count)
        for item in rankings {
            guard let index = (item["index"] as? NSNumber)?.intValue, logits.indices.contains(index) else { continue }
            logits[index] = (item["logit"] as? NSNumber)?.doubleValue ?? -.infinity
        }
        return logits
    }

    /// Cheap reachability + key check for Settings.
    func ping() async throws -> String {
        let reply = try await chat(system: "Reply with the single word OK.", user: "ping", maxTokens: 5, temperature: 0)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Transport

    private func post(_ url: URL, json: [String: Any], key: String, maxAttempts: Int = 4, background: Bool = false,
                      paced: Bool = false) async throws -> Data {
        guard !key.isEmpty else { throw NemotronError.missingKey }
        let payload = try JSONSerialization.data(withJSONObject: json)
        var attempt = 0
        while true {
            attempt += 1
            if background || paced { await pace(host: url.host ?? "") }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = payload
            do {
                let (data, response): (Data, URLResponse)
                if background {
                    let id = UUID()
                    let session = self.session
                    let request = request
                    let task = Task { try await session.data(for: request) }
                    backgroundRequests[id] = task
                    defer { backgroundRequests[id] = nil }
                    do {
                        (data, response) = try await task.value
                    } catch is CancellationError {
                        throw NemotronError.preempted
                    } catch let error as URLError where error.code == .cancelled {
                        throw NemotronError.preempted
                    }
                } else {
                    (data, response) = try await session.data(for: request)
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                let error = NemotronError.http(status, String(decoding: data, as: UTF8.self))
                // A question never sits out a rate limit: the caller has the other host.
                guard error.isRetryable, attempt < maxAttempts, background || paced || status != 429 else { throw error }
                let wait = status == 429 ? 6.0 * Double(attempt) : 1.5 * Double(attempt)
                Log.net.info("nemotron \(status), retry \(attempt) in \(wait) s")
                try await Task.sleep(for: .seconds(wait))
            } catch let error as NemotronError {
                throw error
            } catch let error as URLError where attempt < 3 && error.code == .timedOut {
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Spacing per host for background work on NVIDIA's rate-limited hosts. The slot is taken
    /// before sleeping, so calls that arrive together still leave one after another.
    private func pace(host: String) async {
        guard host.hasSuffix("nvidia.com") else { return }
        let now = ContinuousClock.now
        let slot = max(now, nextSlot[host] ?? now)
        nextSlot[host] = slot + minSpacing
        if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
    }

    /// First balanced `{...}` in the text (ignores ``` fences and stray prose).
    static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in text[start...].indices {
            let ch = text[index]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            default: break
            }
        }
        return nil
    }
}

struct TimeoutError: Error, LocalizedError {
    let seconds: Double
    var errorDescription: String? { "No response within \(Int(seconds)) s" }
}

/// A question call raced over both hosts (`NemotronClient.questionPlan`): the first host starts
/// now, the second joins if the first is still silent after the plan's delay; the first success
/// wins and the other request is cancelled. All failed or `seconds` passed: the last error.
func hedged<T: Sendable>(_ ai: NemotronClient, seconds: Double,
                         _ operation: @escaping @Sendable (NemotronClient.Route) async throws -> T) async -> (result: Result<T, Error>, route: NemotronClient.Route?) {
    let plan = await ai.questionPlan()
    typealias Outcome = (route: NemotronClient.Route?, result: Result<T, Error>)
    return await withTaskGroup(of: Outcome.self) { group in
        group.addTask {
            do { return (plan.first, .success(try await operation(plan.first))) } catch { return (plan.first, .failure(error)) }
        }
        var racing = 1
        if let second = plan.second {
            racing = 2
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(plan.hedgeAfter))
                    return (second, .success(try await operation(second)))
                } catch { return (second, .failure(error)) }
            }
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return (nil, .failure(TimeoutError(seconds: seconds)))
        }
        var last: Outcome = (nil, .failure(TimeoutError(seconds: seconds)))
        for await outcome in group {
            if case .success = outcome.result {
                group.cancelAll()
                return (outcome.result, outcome.route)
            }
            guard outcome.route != nil else {
                group.cancelAll()
                return (outcome.result, nil)
            }
            last = outcome
            racing -= 1
            if racing == 0 { break }
        }
        group.cancelAll()
        return (last.result, last.route)
    }
}

/// Like `withTimeout`, but keeps the error (shown in the answer note and logged).
func withTimeoutResult<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
    await withTaskGroup(of: Result<T, Error>?.self) { group in
        group.addTask {
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? .failure(TimeoutError(seconds: seconds))
    }
}

/// Runs `operation`, giving up after `seconds` (the result is then nil). Used on the question
/// path so a cold-starting hosted model degrades the answer instead of stalling it.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
