import Foundation

struct DesktopPlaybackDevice: Decodable, Equatable, Identifiable {
    struct State: Decodable, Equatable {
        let track: Track?
        let position: Double
        let duration: Double
        let playing: Bool
        let loading: Bool
    }

    let id: String
    let name: String
    let state: State
    let acknowledged: UInt64
}

enum DesktopPlaybackAction: Encodable {
    case start([Track], at: Double)
    case toggle, pause, next, previous
    case seek(Double)

    private enum Key: String, CodingKey { case kind, tracks, position }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        switch self {
        case .start(let tracks, let position):
            try values.encode("start", forKey: .kind)
            try values.encode(tracks, forKey: .tracks)
            try values.encode(position, forKey: .position)
        case .seek(let position):
            try values.encode("seek", forKey: .kind)
            try values.encode(position, forKey: .position)
        case .toggle: try values.encode("toggle", forKey: .kind)
        case .pause: try values.encode("pause", forKey: .kind)
        case .next: try values.encode("next", forKey: .kind)
        case .previous: try values.encode("previous", forKey: .kind)
        }
    }
}

struct DesktopPlaybackRequest: Encodable {
    let kind: String
    var device: String?
    var action: DesktopPlaybackAction?

    static let devices = Self(kind: "devices")

    static func command(_ action: DesktopPlaybackAction, to device: String) -> Self {
        Self(kind: "command", device: device, action: action)
    }
}

struct DesktopPlaybackReply: Decodable {
    let devices: [DesktopPlaybackDevice]?
    let sequence: UInt64?
}
