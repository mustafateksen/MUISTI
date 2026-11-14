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
        /// The same model on build.nvidia.com as a second host when the team's own container
        /// fails. Off unless switched on: the container is the team's alone now and answers
        /// in 0.1–0.9 s, and pictures are only ever sent to it.
        var allowNvidiaFallback = false

        /// The team's own retrieval container goes with its chat container unless another host is set.
        var effectiveEmbedURL: URL { embedBaseURL ?? (baseURL == NemotronClient.muistiChatBase ? NemotronClient.muistiRetrievalBase : baseURL) }
        /// Embeddings and reranking on the team's Verda retrieval container (`/v2/embed`,
        /// `/classify`), which takes the same key as the chat container.
        var usesMuistiRetrieval: Bool { effectiveEmbedURL.host == NemotronClient.muistiRetrievalBase.host }
        var effectiveEmbedKey: String { usesMuistiRetrieval ? apiKey : (embedKey.isEmpty ? apiKey : embedKey) }
        /// NVIDIA keys work across build.nvidia.com models; a Verda key does not.
        var effectiveRerankKey: String { rerankKey.isEmpty ? embedKey : rerankKey }
    }

    /// The team's Verda containers (Finland), 14 Nov: chat 0.12–0.26 s, embed ~0.1 s, one rerank
    /// pair ~0.1 s and 20 pairs in parallel 0.37 s. Same models as on build.nvidia.com: text and
    /// image vectors came back identical (cosine 1.0000 / 0.9999), so stored vectors stay valid.
    static let muistiChatBase = URL(string: "https://containers.datacrunch.io/muisti-nemotron/v1")!
    static let muistiRetrievalBase = URL(string: "https://containers.datacrunch.io/muisti-retrieval")!
    static let muistiEmbedModel = "nemotron-3.5-embed"
    static let muistiRerankModel = "nemotron-3.5-rerank"

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
            case .verda: return NemotronClient.muistiChatBase
            case .nvidia: return URL(string: "https://integrate.api.nvidia.com/v1")!
            }
        }
        var chatModel: String { self == .verda ? "nemotron-3.5-super-vl" : "nvidia/nemotron-3.5-super-vl-120b-a12b" }
        /// The name stored next to each vector. Both hosts serve the same embedding model (the
        /// Verda container calls it `nemotron-3.5-embed`), so one name keeps their vectors together.
        var embedModel: String { "nvidia/nemotron-3.5-embed-1b" }   // single inputs only (batches 500 now and then)
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
            case .missingKey: return String(localized: "No Nemotron API key (Settings > Nemotron).")
            case .preempted: return String(localized: "Deferred for a question.", comment: "Background AI work was postponed so a question could run first")
            case .http(401, _), .http(403, _): return String(localized: "Nemotron API key is invalid.")
            case .http(429, _): return String(localized: "Nemotron rate limit reached; will retry shortly.")
            case .http(let code, let body): return String(localized: "Nemotron \(code): \(body.prefix(160))")
            case .badResponse(let why): return String(localized: "Couldn't read Nemotron response: \(why)")
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
            imageEmbeddingsUnavailable = false
        }
        self.settings = settings
    }
    var hasKey: Bool { !settings.apiKey.isEmpty }

    /// Questions in flight: telemetry only. Nothing waits for it and nothing is cancelled for
    /// it any more (pipeline v2): each kind of work has its own lane with its own capacity, so
    /// a question does not queue behind frame extraction and frame extraction does not stop
    /// while the user talks.
    private(set) var questionsInFlight = 0

    func beginQuestion() {
        questionsInFlight += 1
        Task { await Lane.shared(.background).answering(1) }
    }
    func endQuestion() {
        questionsInFlight = max(0, questionsInFlight - 1)
        Task { await Lane.shared(.background).answering(-1) }
    }
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
    var rerankEnabled: Bool {
        guard !settings.rerankModel.isEmpty, !rerankUnavailable else { return false }
        return settings.usesMuistiRetrieval ? !settings.apiKey.isEmpty : !settings.effectiveRerankKey.isEmpty
    }
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
        settings.allowNvidiaFallback && !settings.effectiveRerankKey.isEmpty && settings.baseURL.host != Provider.nvidia.baseURL.host
    }

    /// Several pictures in one request (frames of one moment, oldest first, `image` last) are
    /// only for the team's chat container, which takes up to 8; elsewhere it is a 400.
    var multiImageChat: Bool { settings.baseURL == Self.muistiChatBase }

    func chat(system: String, user: String, image: ImagePart? = nil, earlierImages: [ImagePart] = [],
              examples: [(user: String, assistant: String)] = [],
              jsonSchema: String? = nil, schemaName: String = "record",
              maxTokens: Int = 700, temperature: Double = 0,
              route requested: Route? = nil, background: Bool = false) async throws -> String {
        // A picture never goes to the second host, whatever the caller or the latency says.
        let route = image != nil || !fallbackAvailable ? .primary : (requested ?? preferredRoute())
        let baseURL = route == .primary ? settings.baseURL : Provider.nvidia.baseURL
        let model = route == .primary ? settings.chatModel : Provider.nvidia.chatModel
        let key = route == .primary ? settings.apiKey : settings.effectiveRerankKey
        // Every outgoing picture passes the on-device private-scene check (fails closed).
        let image = image.flatMap { OutgoingImageGate.allows($0.jpeg) ? $0 : nil }
        let earlierImages = image == nil ? [] : OutgoingImageGate.filter(earlierImages.map(\.jpeg)).map { ImagePart(jpeg: $0) }
        var content: [[String: Any]] = [["type": "text", "text": user]]
        if let image {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(image.jpeg.base64EncodedString())"],
            ])
        }
        if let image, !earlierImages.isEmpty {
            // Pictures in time order first, then the text that refers to them as image 1, 2, …
            content = (earlierImages.prefix(7) + [image]).map {
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.jpeg.base64EncodedString())"]]
            } + [["type": "text", "text": user]]
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
            // Thinking eats tokens before the answer: a call that asks for it gets room for both.
            "max_tokens": Reasoning.on ? max(maxTokens, 2500) : maxTokens,
            "temperature": temperature,
            "top_p": 0.95,
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": Reasoning.on],
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
        // With thinking on, a host may leave the reasoning inside the content: only what
        // follows it is the answer.
        if Reasoning.on, let end = text.range(of: "</think>", options: .backwards) { return String(text[end.upperBound...]) }
        return text
    }

    // MARK: Tools

    /// One function call the model asked for (`arguments` is its JSON object as text).
    struct ToolCall: Sendable {
        let name: String
        let arguments: String

        func decode<T: Decodable>(_ type: T.Type) -> T? {
            try? JSONDecoder().decode(T.self, from: Data(arguments.utf8))
        }
    }

    /// The model's turn: words for the user, or the tools it wants run (native tool calling,
    /// supported by both hosts: probe 14 Nov).
    struct ToolReply: Sendable {
        var text: String
        var calls: [ToolCall]
    }

    /// `tools` is the OpenAI `tools` array as JSON text. The model must call one of them
    /// (`required`): with `auto` it answered memory questions out of its head ("I don't have
    /// that in your memory") instead of searching — 9 of 29 eval turns, 14 Nov.
    func chatTools(system: String, user: String, tools: String, image: ImagePart? = nil, maxTokens: Int = 400,
                   temperature: Double = 0, route requested: Route? = nil, background: Bool = false) async throws -> ToolReply {
        let route = image != nil || !fallbackAvailable ? .primary : (requested ?? preferredRoute())
        let baseURL = route == .primary ? settings.baseURL : Provider.nvidia.baseURL
        guard let toolList = try? JSONSerialization.jsonObject(with: Data(tools.utf8)) else {
            throw NemotronError.badResponse("tools are not JSON")
        }
        var content: Any = user
        if let image, OutgoingImageGate.allows(image.jpeg) {
            content = [["type": "text", "text": user],
                       ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image.jpeg.base64EncodedString())"]]] as [[String: Any]]
        }
        let body: [String: Any] = [
            "model": route == .primary ? settings.chatModel : Provider.nvidia.chatModel,
            "messages": [["role": "system", "content": system], ["role": "user", "content": content]],
            "tools": toolList,
            "tool_choice": "required",
            "max_tokens": maxTokens,
            "temperature": temperature,
            "top_p": 0.95,
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        let sent = ContinuousClock.now
        var completed = false
        defer { noteLatency(route, seconds: (ContinuousClock.now - sent).seconds, completed: completed) }
        let data = try await post(baseURL.appendingPathComponent("chat/completions"), json: body,
                                  key: route == .primary ? settings.apiKey : settings.effectiveRerankKey, background: background)
        completed = true
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else { throw NemotronError.badResponse("missing choices[0].message") }
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> ToolCall? in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            if let text = function["arguments"] as? String { return ToolCall(name: name, arguments: text.isEmpty ? "{}" : text) }
            if let object = function["arguments"], let json = try? JSONSerialization.data(withJSONObject: object) {
                return ToolCall(name: name, arguments: String(decoding: json, as: UTF8.self))
            }
            return ToolCall(name: name, arguments: "{}")
        }
        let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !calls.isEmpty || !text.isEmpty else { throw NemotronError.badResponse("empty turn") }
        return ToolReply(text: text, calls: calls)
    }

    /// Chat whose answer must be a JSON object; tolerant of code fences / prose around it.
    func chatJSON<T: Decodable>(_ type: T.Type, system: String, user: String, image: ImagePart? = nil,
                                earlierImages: [ImagePart] = [],
                                examples: [(user: String, assistant: String)] = [], jsonSchema: String? = nil,
                                schemaName: String = "record", maxTokens: Int = 700, temperature: Double = 0,
                                route: Route? = nil, background: Bool = false) async throws -> T {
        let text = try await chat(system: system, user: user, image: image, earlierImages: earlierImages, examples: examples, jsonSchema: jsonSchema,
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

    /// One input on the team's retrieval container (`/v2/embed`): text, or a picture.
    private func muistiEmbed(content: [[String: Any]], kind: EmbedKind) async throws -> [Float] {
        let body: [String: Any] = [
            "model": Self.muistiEmbedModel,
            "input_type": kind == .query ? "query" : "document",
            "embedding_types": ["float"],
            "truncate": "END",
            "inputs": [["content": content]],
        ]
        let data = try await post(Self.muistiRetrievalBase.appendingPathComponent("v2/embed"), json: body, key: settings.apiKey)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let vector = ((root["embeddings"] as? [String: Any])?["float"] as? [[Double]])?.first, !vector.isEmpty
        else { throw NemotronError.badResponse("missing embedding") }
        return vector.map(Float.init)
    }

    func embed(_ text: String, as kind: EmbedKind) async throws -> [Float] {
        guard embeddingsEnabled else { throw NemotronError.badResponse("embeddings off") }
        if settings.usesMuistiRetrieval {
            do {
                return try await muistiEmbed(content: [["type": "text", "text": String(text.prefix(4000))]], kind: kind)
            } catch NemotronError.http(let status, let message) where status == 404 {
                embeddingsUnavailable = true
                Log.net.info("embeddings unavailable on the retrieval container (\(status)); keyword search only")
                throw NemotronError.http(status, message)
            }
        }
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

    /// Set when the host refuses image inputs (not NVIDIA's retriever API, or an older model).
    private var imageEmbeddingsUnavailable = false

    var imageEmbeddingsEnabled: Bool {
        embeddingsEnabled && !imageEmbeddingsUnavailable
            && (settings.usesMuistiRetrieval || settings.effectiveEmbedURL.host?.hasSuffix("nvidia.com") == true)
    }

    /// A keyframe as a passage vector. nemotron-3.5-embed-1b puts images in the same space as
    /// its text passages and (text-only) queries, so a question finds the picture itself, not
    /// only what the extraction happened to write about it.
    func embedImage(_ jpeg: Data) async throws -> [Float] {
        guard imageEmbeddingsEnabled else { throw NemotronError.badResponse("image embeddings off") }
        // A picture refused by the private-scene check is never sent (the worker marks it done).
        guard OutgoingImageGate.allows(jpeg) else { throw NemotronError.http(403, "private scene: not sent") }
        // The model's default longest edge is 1120 px.
        let image = ImageData.downscaledJPEG(jpeg, maxPixel: 1024, quality: 0.8)
        if settings.usesMuistiRetrieval {
            do {
                return try await muistiEmbed(content: [["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]]],
                                             kind: .passage)
            } catch NemotronError.http(let status, let message) where status == 404 {
                imageEmbeddingsUnavailable = true
                throw NemotronError.http(status, message)
            }
        }
        let url = settings.effectiveEmbedURL.appendingPathComponent("embeddings")
        let key = settings.effectiveEmbedKey
        // Verified on the live endpoint: images need input_type "passage" ("" is a 400).
        let body: [String: Any] = [
            "model": settings.embedModel,
            "input": ["data:image/jpeg;base64,\(image.base64EncodedString())"],
            "modality": ["image"],
            "input_type": "passage",
            "encoding_format": "float",
            "truncate": "END",
        ]
        let data: Data
        do {
            data = try await post(url, json: body, key: key, paced: true)
        } catch NemotronError.http(let status, let message) where status == 404 {
            // No such endpoint/model here. A 400 is about this one picture: the worker skips it.
            imageEmbeddingsUnavailable = true
            Log.net.info("image embeddings unavailable on this host (\(status)); text vectors only")
            throw NemotronError.http(status, message)
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["data"] as? [[String: Any]],
            let vector = items.first?["embedding"] as? [Double]
        else { throw NemotronError.badResponse("missing image embedding") }
        return vector.map(Float.init)
    }

    // MARK: Reranking

    /// Cross-encoder relevance of each passage to the query: one logit per passage, same order.
    func rerank(query: String, passages: [String], paced: Bool = false) async throws -> [Double] {
        guard rerankEnabled else { throw NemotronError.badResponse("reranking off") }
        guard !passages.isEmpty else { return [] }
        if settings.usesMuistiRetrieval { return try await muistiRerank(query: query, passages: passages) }
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

    /// The team's retrieval container scores one (query, passage) pair per request (`/classify`):
    /// all pairs go out at once and come back in about the time of one. A pair that fails keeps
    /// the lowest score; if every pair fails, the error is thrown.
    private func muistiRerank(query: String, passages: [String]) async throws -> [Double] {
        let url = Self.muistiRetrievalBase.appendingPathComponent("classify")
        let key = settings.apiKey
        let asked = String(query.prefix(500))
        var logits = [Double](repeating: -.infinity, count: passages.count)
        var lastError: Error?
        let results = await withTaskGroup(of: (Int, Result<Double, Error>).self) { group -> [(Int, Result<Double, Error>)] in
            for (index, passage) in passages.enumerated() {
                let body: [String: Any] = [
                    "model": Self.muistiRerankModel,
                    "add_special_tokens": false,
                    "use_activation": false,
                    "messages": [
                        ["role": "query", "content": [["type": "text", "text": asked]]],
                        ["role": "document", "content": [["type": "text", "text": String(passage.prefix(1200))]]],
                    ],
                ]
                let payload = try? JSONSerialization.data(withJSONObject: body)
                group.addTask {
                    do {
                        guard let payload else { throw NemotronError.badResponse("rerank body") }
                        let data = try await self.post(url, payload: payload, key: key, maxAttempts: 2)
                        guard
                            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                            let score = ((root["data"] as? [[String: Any]])?.first?["probs"] as? [Double])?.first
                        else { throw NemotronError.badResponse("missing rerank score") }
                        return (index, .success(score))
                    } catch { return (index, .failure(error)) }
                }
            }
            var all: [(Int, Result<Double, Error>)] = []
            for await item in group { all.append(item) }
            return all
        }
        for (index, result) in results {
            switch result {
            case .success(let score): logits[index] = score
            case .failure(let error): lastError = error
            }
        }
        if let lastError, logits.allSatisfy({ $0 == -.infinity }) { throw lastError }
        return logits
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
        try await post(url, payload: try JSONSerialization.data(withJSONObject: json), key: key, maxAttempts: maxAttempts,
                       background: background, paced: paced)
    }

    private func post(_ url: URL, payload: Data, key: String, maxAttempts: Int = 4, background: Bool = false,
                      paced: Bool = false) async throws -> Data {
        guard !key.isEmpty else { throw NemotronError.missingKey }
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
                // The request waits for a place in its lane (its kind of work's share of the
                // server), not for other kinds of work to finish.
                // Lanes are for the chat model. Embeddings and the reranker run on their own
                // container, take milliseconds and come in bursts of one request per pair
                // (20–30 at once for one question): they are not queued.
                let kind = LaneKind.current ?? (background || paced ? .background : .user)
                let lane = url.path.hasSuffix("chat/completions") ? Lane.shared(kind) : nil
                if let queued = await lane?.acquire(), queued.waitedMs >= 100 {
                    Trace.note("lane \(kind.rawValue): waited \(queued.waitedMs) ms behind \(queued.depth)")
                }
                let (data, response): (Data, URLResponse)
                do {
                    (data, response) = try await session.data(for: request)
                    await lane?.release()
                } catch {
                    await lane?.release()
                    throw error
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                let error = NemotronError.http(status, String(decoding: data, as: UTF8.self))
                let ownHost = !(url.host ?? "").hasSuffix("nvidia.com")
                // On NVIDIA's shared hosts a question never sits out a rate limit; the team's
                // own container gets a short backoff for everything (0.5, 1, 2 s).
                guard error.isRetryable, attempt < maxAttempts, ownHost || background || paced || status != 429 else { throw error }
                let wait = ownHost ? 0.5 * pow(2, Double(attempt - 1)) : (status == 429 ? 6.0 * Double(attempt) : 1.5 * Double(attempt))
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

/// Whether the model reasons before it answers (pipeline v2, §5.4). Off for everything that
/// runs per frame or decides a turn (it costs seconds); on for the few answers that need
/// working out — the turn decision says which.
enum Reasoning {
    @TaskLocal static var on = false
}

/// The kinds of work that share the model server, each with its own capacity (pipeline v2):
/// nobody cancels anybody, a request only waits behind requests of its own kind. Measured
/// capacity of the team's container: 128 picture requests at once; these add up to 32.
enum LaneKind: String, Sendable {
    /// Safety looks and danger sentences.
    case safety
    /// The user's turn: decision, answer, repair, live look.
    case user
    /// The agent's own judgement of what it noticed.
    case notice
    /// Enrichment, embeddings, summaries.
    case background

    /// The lane of the work running in this task (set by the caller of that work); nil means
    /// the request's own flags decide.
    @TaskLocal static var current: LaneKind?

    var limit: Int {
        switch self {
        case .safety: 6
        case .user: 8
        case .notice: 6
        case .background: 8
        }
    }

    /// While the user is being answered, background work starts at most this many new
    /// requests (nothing running is cancelled). Measured 15 Nov: with 12 frame analyses running
    /// at once the turn decision took 5 s instead of 0.8 s — the server slows everyone down
    /// long before it refuses anyone.
    static let backgroundWhileAnswering = 2
}

actor Lane {
    private static let all: [LaneKind: Lane] = [.safety: Lane(.safety), .user: Lane(.user), .notice: Lane(.notice), .background: Lane(.background)]
    static func shared(_ kind: LaneKind) -> Lane { all[kind]! }

    let kind: LaneKind
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// The background lane makes room while a question is answered.
    /// Questions being answered right now (counted, so begin and end may arrive in any order).
    private var questions = 0
    private var limit: Int { questions > 0 ? min(kind.limit, LaneKind.backgroundWhileAnswering) : kind.limit }

    func answering(_ change: Int) {
        questions = max(0, questions + change)
        if questions == 0 { admit() }
    }

    private func admit() {
        while !waiters.isEmpty, active < limit {
            active += 1
            waiters.removeFirst().resume()
        }
    }
    /// For the developer screen and the trace: requests running and waiting.
    var load: (active: Int, waiting: Int) { (active, waiters.count) }

    init(_ kind: LaneKind) { self.kind = kind }

    /// A place in the lane, first come first served. Returns how long the request waited and
    /// how many were ahead of it.
    func acquire() async -> (waitedMs: Int, depth: Int) {
        if active < limit {
            active += 1
            return (0, 0)
        }
        let depth = waiters.count + 1
        let began = ContinuousClock.now
        await withCheckedContinuation { waiters.append($0) }
        return ((ContinuousClock.now - began).milliseconds, depth)
    }

    /// The place goes to the next waiting request, if the lane has room for it right now.
    func release() {
        active = max(0, active - 1)
        admit()
    }
}

struct TimeoutError: Error, LocalizedError {
    let seconds: Double
    var errorDescription: String? { String(localized: "No response within \(Int(seconds)) s") }
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
