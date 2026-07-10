import CoreGraphics
import Foundation

enum PermissionReadiness: String, Equatable, Sendable {
    case granted
    case notDetermined
    case denied
    case unsupported

    var isReady: Bool {
        self == .granted || self == .unsupported
    }
}

enum ScreenAudioPermission {
    static var isSupported: Bool {
        if #available(macOS 15.0, *) {
            return true
        }

        return false
    }

    static func status() -> PermissionReadiness {
        guard isSupported else { return .unsupported }
        return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    static func requestAccess() -> Bool {
        guard isSupported else { return false }
        return CGRequestScreenCaptureAccess()
    }
}
