import Foundation

/// NVIDIA API (OpenAI-compatible) called straight from the phone.
/// - Chat + vision: `nvidia/nemotron-3.5-super-vl-120b-a12b`
/// - Embeddings: `nvidia/nemotron-3.5-embed-1b` (falls back to keyword search if unavailable)
/// Free tier is roughly 40 requests/min per key; calls are spaced and retried on 429/5xx.
actor NemotronClient {
    struct Settings: Sendable, Equatable {
        var baseURL = Provider.verda.baseURL
        var chatModel = Provider.verda.chatModel
        var embedModel = Provider.verda.embedModel   // empty = no embeddings, keyword search only
        var apiKey = ""
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
        var embedModel: String { self == .verda ? "" : "nvidia/nemotron-3.5-embed-1b" }
    }

    enum NemotronError: Error, LocalizedError {
        case missingKey
        case http(Int, String)
        case badResponse(String)

        var isRetryable: Bool {
            switch self {
            case .http(let status, _): return status == 429 || status >= 500
            case .badResponse: return true
            case .missingKey: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Nemotron API anahtarı yok (Ayarlar > Nemotron)."
            case .http(401, _), .http(403, _): return "Nemotron API anahtarı geçersiz."
            case .http(429, _): return "Nemotron istek sınırı doldu; biraz sonra tekrar denenecek."
            case .http(let code, let body): return "Nemotron \(code): \(body.prefix(160))"
            case .badResponse(let why): return "Nemotron yanıtı okunamadı: \(why)"
            }
        }
    }

    private var settings: Settings
    private let session: URLSession
    private var lastRequestAt: ContinuousClock.Instant?
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
        if settings.baseURL != self.settings.baseURL || settings.embedModel != self.settings.embedModel {
            embeddingsUnavailable = false
        }
        self.settings = settings
    }
    var hasKey: Bool { !settings.apiKey.isEmpty }
    /// Set after the host answers 404/400 for embeddings, so we stop spending calls on it.
    private var embeddingsUnavailable = false
    var embeddingsEnabled: Bool { !settings.embedModel.isEmpty && !embeddingsUnavailable }

    // MARK: Chat

    struct ImagePart: Sendable {
        let jpeg: Data
    }

    /// One chat turn. Returns the assistant text (reasoning disabled for latency).
    func chat(system: String, user: String, image: ImagePart? = nil, maxTokens: Int = 700, temperature: Double = 0.3) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": user]]
        if let image {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(image.jpeg.base64EncodedString())"],
            ])
        }
        let body: [String: Any] = [
            "model": settings.chatModel,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": content],
            ],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "top_p": 0.95,
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        let data = try await post("chat/completions", json: body)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String
        else { throw NemotronError.badResponse("choices[0].message.content yok") }
        return text
    }

    /// Chat whose answer must be a JSON object; tolerant of code fences / prose around it.
    func chatJSON<T: Decodable>(_ type: T.Type, system: String, user: String, image: ImagePart? = nil, maxTokens: Int = 700) async throws -> T {
        let text = try await chat(system: system, user: user, image: image, maxTokens: maxTokens)
        guard let json = Self.extractJSONObject(text) else {
            throw NemotronError.badResponse("JSON bulunamadı: \(text.prefix(120))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw NemotronError.badResponse("JSON çözülemedi: \(error.localizedDescription)")
        }
    }

    // MARK: Embeddings

    enum EmbedKind: String { case passage, query }

    func embed(_ text: String, as kind: EmbedKind) async throws -> [Float] {
        guard embeddingsEnabled else { throw NemotronError.badResponse("gömme kapalı") }
        let body: [String: Any] = [
            "model": settings.embedModel,
            "input": [String(text.prefix(4000))],
            "input_type": kind.rawValue,
            "encoding_format": "float",
            "truncate": "END",
        ]
        let data: Data
        do {
            data = try await post("embeddings", json: body)
        } catch NemotronError.http(let status, let message) where status == 404 || status == 400 || status == 422 {
            embeddingsUnavailable = true
            Log.net.info("embeddings unavailable on this host (\(status)); keyword search only")
            throw NemotronError.http(status, message)
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["data"] as? [[String: Any]],
            let vector = items.first?["embedding"] as? [Double]
        else { throw NemotronError.badResponse("embedding yok") }
        return vector.map(Float.init)
    }

    /// Cheap reachability + key check for Settings.
    func ping() async throws -> String {
        let reply = try await chat(system: "Reply with the single word OK.", user: "ping", maxTokens: 5, temperature: 0)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Transport

    private func post(_ path: String, json: [String: Any]) async throws -> Data {
        guard !settings.apiKey.isEmpty else { throw NemotronError.missingKey }
        let payload = try JSONSerialization.data(withJSONObject: json)
        var attempt = 0
        while true {
            attempt += 1
            await pace()
            var request = URLRequest(url: settings.baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = payload
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                let error = NemotronError.http(status, String(decoding: data, as: UTF8.self))
                guard error.isRetryable, attempt < 4 else { throw error }
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

    private func pace() async {
        if let last = lastRequestAt {
            let elapsed = ContinuousClock.now - last
            if elapsed < minSpacing { try? await Task.sleep(for: minSpacing - elapsed) }
        }
        lastRequestAt = .now
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
