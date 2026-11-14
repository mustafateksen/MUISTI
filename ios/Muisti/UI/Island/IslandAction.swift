/// The one thing the glasses island offers to do about the current state.
enum IslandAction: Equatable {
    case start, resume, retry, stop, register, permission

    var title: String {
        switch self {
        case .start: "Start recording"
        case .resume: "Resume"
        case .retry: "Try again"
        case .stop: "Stop"
        case .register: "Connect"
        case .permission: "Allow"
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
