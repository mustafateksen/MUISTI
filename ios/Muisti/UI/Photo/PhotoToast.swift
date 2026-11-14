/// Short result message after saving a photo.
enum PhotoToast: Equatable {
    case saved, denied, failed

    var text: String {
        switch self {
        case .saved: "Saved to Photos"
        case .denied: "No access to Photos.\nSettings > Muisti > Photos"
        case .failed: "Couldn't save. Try again."
        }
    }

    var symbol: String {
        switch self {
        case .saved: "checkmark.circle.fill"
        case .denied, .failed: "exclamationmark.triangle.fill"
        }
    }
}
