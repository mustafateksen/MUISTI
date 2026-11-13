import Foundation

/// Kişi 3's FastAPI server. Contract (plan §05):
///   POST {base}/ingest  IngestPayload → { "memory_id": 123 }
///   POST {base}/ask     { question, now, lat, lon } → AskResponse
struct APIClient: Sendable {
    let baseURL: URL
    var session: URLSession = .shared

    struct IngestResponse: Codable, Sendable {
        let memory_id: Int
    }

    struct AskRequest: Codable, Sendable {
        let question: String
        let now: String
        let lat: Double?
        let lon: Double?
    }

    struct AskResponse: Codable, Sendable {
        let answer: String
        let label: String          // GORDUM | WEBDEN | BILMIYORUM
        let evidence: [Evidence]
        let sources: [Source]

        struct Evidence: Codable, Sendable {
            let memory_id: Int
            let frame_url: String?
            let seen_at: String?
            let lat: Double?
            let lon: Double?
        }

        struct Source: Codable, Sendable {
            let title: String?
            let url: String
        }
    }

    enum APIError: Error, LocalizedError {
        case http(status: Int, body: String)

        var isRetryable: Bool {
            switch self {
            case .http(let status, _): return status == 408 || status == 429 || status >= 500
            }
        }

        var errorDescription: String? {
            switch self {
            case .http(let status, let body): return "Sunucu \(status): \(body.prefix(200))"
            }
        }
    }

    func ingest(_ payload: IngestPayload) async throws -> IngestResponse {
        try await post("ingest", body: payload, timeout: 20)
    }

    func ingest(rawJSON: Data) async throws -> IngestResponse {
        try await post("ingest", data: rawJSON, timeout: 20)
    }

    func ask(_ question: String, lat: Double?, lon: Double?, now: Date = Date()) async throws -> AskResponse {
        try await post(
            "ask",
            body: AskRequest(question: question, now: ISO8601.string(from: now), lat: lat, lon: lon),
            timeout: 60
        )
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, timeout: TimeInterval) async throws -> Response {
        try await post(path, data: JSONEncoder().encode(body), timeout: timeout)
    }

    private func post<Response: Decodable>(_ path: String, data: Data, timeout: TimeInterval) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, body: String(decoding: responseData, as: UTF8.self))
        }
        return try JSONDecoder().decode(Response.self, from: responseData)
    }
}
