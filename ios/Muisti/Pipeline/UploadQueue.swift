import Foundation
import Network

struct UploadQueueStatus: Sendable, Equatable {
    var pending = 0
    var bytes: Int64 = 0
    var sent = 0
    var online = true
    var enabled = true
    var lastError: String?
    var lastMemoryId: Int?
}

/// Disk-backed `/ingest` queue that survives app kills and bad hall Wi-Fi.
///
/// - One JSON file per payload under `Application Support/queue/`, named
///   `<seenAtMillis>-<uuid>.json` so lexical order = capture order and `purge(since:)` is cheap.
/// - One worker, strictly in order. Exponential backoff 1, 2, 4 … 30 s on retryable failures.
/// - Does nothing while `NWPathMonitor` says offline.
/// - Bounded: 500 items or 200 MB, oldest dropped first.
/// - Non-retryable 4xx answers are moved to `queue-rejected/` for inspection.
actor UploadQueue {
    static let maxItems = 500
    static let maxBytes: Int64 = 200 * 1024 * 1024

    let statusStream: AsyncStream<UploadQueueStatus>
    private let statusContinuation: AsyncStream<UploadQueueStatus>.Continuation
    private(set) var status = UploadQueueStatus() {
        didSet { statusContinuation.yield(status) }
    }

    private let directory: URL
    private let rejectedDirectory: URL
    private var client: APIClient?
    private var worker: Task<Void, Never>?
    private var wakeup: CheckedContinuation<Void, Never>?
    private let monitor = NWPathMonitor()

    init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        directory = support.appendingPathComponent("queue", isDirectory: true)
        rejectedDirectory = support.appendingPathComponent("queue-rejected", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: rejectedDirectory, withIntermediateDirectories: true)
        (statusStream, statusContinuation) = AsyncStream.makeStream(of: UploadQueueStatus.self, bufferingPolicy: .bufferingNewest(1))
    }

    func start(baseURL: URL?, enabled: Bool) {
        client = baseURL.map { APIClient(baseURL: $0) }
        status.enabled = enabled
        refreshCounts()
        guard worker == nil else { return signal() }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { await self?.setOnline(online) }
        }
        monitor.start(queue: DispatchQueue(label: "fi.junction.muisti.netpath"))
        worker = Task { await self.run() }
    }

    func configure(baseURL: URL?, enabled: Bool) {
        client = baseURL.map { APIClient(baseURL: $0) }
        status.enabled = enabled
        status.lastError = nil
        signal()
    }

    // MARK: Producer side

    func enqueue(_ payload: IngestPayload, seenAt: Date) {
        do {
            let data = try JSONEncoder().encode(payload)
            let name = "\(Int64(seenAt.timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            enforceLimits()
            refreshCounts()
            signal()
        } catch {
            status.lastError = "Kuyruğa yazılamadı: \(error.localizedDescription)"
        }
    }

    /// "Unut": drop everything captured at or after `since` that has not been sent yet.
    @discardableResult
    func purge(since: Date) -> Int {
        let cutoff = Int64(since.timeIntervalSince1970 * 1000)
        var removed = 0
        for url in files() where (millis(of: url) ?? 0) >= cutoff {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        refreshCounts()
        return removed
    }

    func purgeAll() {
        for url in files() { try? FileManager.default.removeItem(at: url) }
        refreshCounts()
    }

    // MARK: Worker

    private func run() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            guard status.online, status.enabled, let client, let next = files().first else {
                await waitForWork()
                continue
            }
            do {
                let data = try Data(contentsOf: next)
                let response = try await client.ingest(rawJSON: data)
                try? FileManager.default.removeItem(at: next)
                status.sent += 1
                status.lastMemoryId = response.memory_id
                status.lastError = nil
                backoff = 1
                refreshCounts()
            } catch let error as APIClient.APIError where !error.isRetryable {
                // The server will never accept this one; keep it aside, do not block the line.
                let dest = rejectedDirectory.appendingPathComponent(next.lastPathComponent)
                try? FileManager.default.moveItem(at: next, to: dest)
                status.lastError = error.localizedDescription
                refreshCounts()
            } catch {
                status.lastError = "Gönderilemedi: \(error.localizedDescription)"
                Log.net.error("ingest failed, retry in \(backoff) s: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private func waitForWork() async {
        await withCheckedContinuation { continuation in
            wakeup = continuation
        }
    }

    private func signal() {
        wakeup?.resume()
        wakeup = nil
    }

    private func setOnline(_ online: Bool) {
        guard status.online != online else { return }
        status.online = online
        if online { signal() }
    }

    // MARK: Files

    private func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func millis(of url: URL) -> Int64? {
        url.lastPathComponent.split(separator: "-").first.flatMap { Int64($0) }
    }

    private func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func enforceLimits() {
        var all = files()
        var total = all.reduce(Int64(0)) { $0 + size(of: $1) }
        while !all.isEmpty, all.count > Self.maxItems || total > Self.maxBytes {
            let oldest = all.removeFirst()
            total -= size(of: oldest)
            try? FileManager.default.removeItem(at: oldest)
            Log.net.info("queue full, dropped \(oldest.lastPathComponent, privacy: .public)")
        }
    }

    private func refreshCounts() {
        let all = files()
        status.pending = all.count
        status.bytes = all.reduce(Int64(0)) { $0 + size(of: $1) }
    }
}
