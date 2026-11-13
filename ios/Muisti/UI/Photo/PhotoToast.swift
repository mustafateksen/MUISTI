/// Short result message after saving a photo.
enum PhotoToast: Equatable {
    case saved, denied, failed

    var text: String {
        switch self {
        case .saved: "Fotoğraflara kaydedildi"
        case .denied: "Fotoğraflar izni yok.\nAyarlar > Muisti > Fotoğraflar"
        case .failed: "Kaydedilemedi, tekrar dene."
        }
    }

    var symbol: String {
        switch self {
        case .saved: "checkmark.circle.fill"
        case .denied, .failed: "exclamationmark.triangle.fill"
        }
    }
}
