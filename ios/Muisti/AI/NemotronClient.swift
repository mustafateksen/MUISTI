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
    private var lastRequestAt: [String: ContinuousClock.Instant] = [:]
    /// ≥ 1.6 s between calls keeps a single key under ~40/min.
    private let minSpacing: Duration = .milliseconds(1600)

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
              route: Route = .primary, background: Bool = false) async throws -> String {
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
                                route: Route = .primary, background: Bool = false) async throws -> T {
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
            data = try await post(settings.effectiveEmbedURL.appendingPathComponent("embeddings"), json: body, key: settings.effectiveEmbedKey)
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
    func rerank(query: String, passages: [String]) async throws -> [Double] {
        guard rerankEnabled else { throw NemotronError.badResponse("reranking off") }
        guard !passages.isEmpty else { return [] }
        let model = rerankModelName
        do {
            return try await rerank(query: query, passages: passages, model: model)
        } catch NemotronError.http(let status, let message) where status == 404 || status == 410 {
            guard model != Self.fallbackRerankModel else {
                rerankUnavailable = true
                throw NemotronError.http(status, message)
            }
            Log.net.info("reranker \(model, privacy: .public) gone (\(status)); using \(Self.fallbackRerankModel, privacy: .public)")
            rerankOverride = Self.fallbackRerankModel
            return try await rerank(query: query, passages: passages, model: Self.fallbackRerankModel)
        }
    }

    private func rerank(query: String, passages: [String], model: String) async throws -> [Double] {
        let body: [String: Any] = [
            "model": model,
            "query": ["text": String(query.prefix(500))],
            "passages": passages.map { ["text": String($0.prefix(1200))] },
            "truncate": "END",
        ]
        let data = try await post(Self.rerankURL(model), json: body, key: settings.effectiveRerankKey, maxAttempts: 2)
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

    private func post(_ url: URL, json: [String: Any], key: String, maxAttempts: Int = 4, background: Bool = false) async throws -> Data {
        guard !key.isEmpty else { throw NemotronError.missingKey }
        let payload = try JSONSerialization.data(withJSONObject: json)
        var attempt = 0
        while true {
            attempt += 1
            await pace(host: url.host ?? "")
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
                guard error.isRetryable, attempt < maxAttempts else { throw error }
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

    /// Spacing per host, so embeddings on another host never wait behind chat calls.
    private func pace(host: String) async {
        if let last = lastRequestAt[host] {
            let elapsed = ContinuousClock.now - last
            if elapsed < minSpacing { try? await Task.sleep(for: minSpacing - elapsed) }
        }
        lastRequestAt[host] = .now
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
