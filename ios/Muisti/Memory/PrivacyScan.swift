import Foundation
import Observation

/// Re-checks memories already on the phone with the current private-scene check (bathroom,
/// shower, PIN pad…) and deletes those that match: frames kept before the check existed, or
/// before it learned a case. On the phone only; nothing is sent. (Android `OldMemoryScan`.)
@Observable
@MainActor
final class PrivacyScan {
    private(set) var checked = 0
    private(set) var total = 0
    private(set) var removed = 0
    private(set) var running = false
    private var task: Task<Void, Never>?

    func start(store: MemoryStore, delete: @escaping @MainActor (Int64) async -> Void) {
        guard !running else { return }
        running = true
        checked = 0
        removed = 0
        task = Task {
            let records = await store.recent(limit: 100_000)
            total = records.count
            for record in records {
                if Task.isCancelled { break }
                let url = store.frameURL(record)
                let isPrivate = await Task.detached(priority: .utility) { () -> Bool in
                    guard let data = try? Data(contentsOf: url), let image = ImageData.thumbnail(data, maxPixel: 512) else { return false }
                    return PerceptionEngine.showsPrivateScene(image)
                }.value
                if isPrivate {
                    await delete(record.id)
                    removed += 1
                }
                checked += 1
            }
            Log.pipeline.info("privacy scan: \(self.checked) checked, \(self.removed) removed")
            running = false
        }
    }

    func cancel() {
        task?.cancel()
        running = false
    }
}
