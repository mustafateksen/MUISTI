import Photos

/// Saves a stored keyframe (already blurred) to the photo library, asking for add-only access.
enum PhotoSaver {
    enum Failure: Error {
        case denied, unreadable
    }

    static func save(contentsOf url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.denied }
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
        guard !data.isEmpty else { throw Failure.unreadable }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}
