/// The one thing the glasses island offers to do about the current state.
enum IslandAction: Equatable {
    case start, resume, retry, stop, register, permission

    var title: String {
        switch self {
        case .start: String(localized: "Start recording")
        case .resume: String(localized: "Resume")
        case .retry: String(localized: "Try again")
        case .stop: String(localized: "Stop")
        case .register: String(localized: "Connect")
        case .permission: String(localized: "Allow", comment: "Button: grant glasses camera access")
        }
    }

    var systemImage: String {
        switch self {
        case .start: "record.circle"
        case .resume: "play.fill"
        case .retry: "arrow.clockwise"
        case .stop: "stop.fill"
        case .register: "link"
        case .permission: "camera.fill"
        }
    }
}
