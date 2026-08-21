import Foundation

/// Store-level decode error carrying a distinguishable unknown-schema case so
/// callers can quarantine records instead of silently dropping or trusting them.
struct StoreDecodeError: Error {
    enum Kind {
        case schemaVersionMismatch
    }
    let kind: Kind

    static let schemaVersionMismatch = StoreDecodeError(kind: .schemaVersionMismatch)

    var isSchemaVersionMismatch: Bool { kind == .schemaVersionMismatch }
}
