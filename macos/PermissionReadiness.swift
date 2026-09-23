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

    /// macOS shows the screen-recording prompt only once and has no API to
    /// tell "never asked" from "refused", so a remembered request stands in:
    /// after it, the only way forward is System Settings.
    private static let didRequestKey = "ScreenAudioPermission.didRequest"

    static func status() -> PermissionReadiness {
        guard isSupported else { return .unsupported }
        if CGPreflightScreenCaptureAccess() { return .granted }
        return UserDefaults.standard.bool(forKey: didRequestKey) ? .denied : .notDetermined
    }

    static func requestAccess() -> Bool {
        guard isSupported else { return false }
        UserDefaults.standard.set(true, forKey: didRequestKey)
        return CGRequestScreenCaptureAccess()
    }
}
