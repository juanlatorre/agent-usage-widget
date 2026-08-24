import Foundation

#if canImport(ServiceManagement)
@preconcurrency import ServiceManagement
#endif

/// Owns the invisible login-session helper lifecycle (R1, §10).
/// No menu-bar item. Disabled background refresh does not disable manual refresh while app is open (R1).
public protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
    func status() -> LoginItemStatus
}

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case notSupported
    case unknown(String)
}

#if canImport(ServiceManagement)
/// Real implementation using SMAppService (macOS 13+, officially supported in 14).
public struct SMLoginItemController: LoginItemControlling, @unchecked Sendable {

    private let service: SMAppService?

    public init(bundleIdentifier: String = "com.juanlatorre.agent-usage.helper") {
        if #available(macOS 13.0, *) {
            self.service = SMAppService.loginItem(identifier: bundleIdentifier)
        } else {
            self.service = nil
        }
    }

    public var isEnabled: Bool {
        guard let service else { return false }
        if #available(macOS 13.0, *) {
            return service.status == .enabled
        }
        return false
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard let service else { throw LoginItemError.unavailable }
        if #available(macOS 13.0, *) {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } else {
            throw LoginItemError.unavailable
        }
    }

    public func status() -> LoginItemStatus {
        guard let service else { return .notSupported }
        if #available(macOS 13.0, *) {
            switch service.status {
            case .enabled: return .enabled
            case .notRegistered: return .disabled
            case .requiresApproval: return .requiresApproval
            case .notFound: return .notSupported
            @unknown default: return .unknown(String(describing: service.status))
            }
        }
        return .notSupported
    }
}

public enum LoginItemError: Error { case unavailable }

#else
public struct SMLoginItemController: LoginItemControlling, Sendable {
    public init(bundleIdentifier: String = "com.juanlatorre.agent-usage.helper") {}
    public var isEnabled: Bool { false }
    public func setEnabled(_ enabled: Bool) throws {}
    public func status() -> LoginItemStatus { .notSupported }
}
#endif

/// In-memory fake for tests and previews.
public final class FakeLoginItemController: LoginItemControlling, @unchecked Sendable {
    public private(set) var isEnabled: Bool
    public var forcedStatus: LoginItemStatus?
    public private(set) var calls: [Bool] = []
    public init(enabled: Bool = false) { self.isEnabled = enabled }
    public func setEnabled(_ enabled: Bool) throws { isEnabled = enabled; calls.append(enabled) }
    public func status() -> LoginItemStatus { forcedStatus ?? (isEnabled ? .enabled : .disabled) }
}
