import Testing
import Foundation
@testable import AgentUsageCore

/// Connection lifecycle tests over fake stores: AC1 independent connections,
/// AC4 changed identity, R8 disconnect isolation, duplicate-binding rejection.
@Suite struct ClaudeAccountControllerTests {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: AC1 — independent connection

    @Test func ac1_twoSlotsTwoDistinctEntriesAndRecords() throws {
        let store = FakeCredentialStore()
        let controller = ClaudeFixtures.makeController(store: store)
        let legacyADir = try ClaudeFixtures.makeDirectory(
            name: "legacy-profile", token: "token-legacy", uuid: "uuid-legacy")
        let inshaDir = try ClaudeFixtures.makeDirectory(
            name: "legacy-b-profile", token: "token-insha", uuid: "uuid-insha")

        _ = try controller.connect(slotID: .claudeLegacyA, directory: legacyADir, now: now)
        _ = try controller.connect(slotID: .claudethe team, directory: inshaDir, now: now)

        // Two separate Keychain entries exist.
        #expect(store.count == 2)

        let legacy = controller.credential(for: .claudeLegacyA)
        let insha = controller.credential(for: .claudethe team)
        #expect(legacy?.accessToken == "token-legacy")
        #expect(insha?.accessToken == "token-insha")

        // Neither slot can read or overwrite the other.
        #expect(legacy?.accountUUID == "uuid-legacy")
        #expect(insha?.accountUUID == "uuid-insha")

        let connections = controller.loadConnections()
        #expect(connections[.claudeLegacyA]?.source.directoryName == "legacy-profile")
        #expect(connections[.claudethe team]?.source.directoryName == "legacy-b-profile")
        #expect(connections[.claudeLegacyA]?.importedIdentity.fingerprint
                != connections[.claudethe team]?.importedIdentity.fingerprint)
    }

    @Test func ac1_connectPersistsNoSecretsInConnectionFile() throws {
        let file = ClaudeFixtures.connectionsFile()
        let controller = ClaudeAccountController(
            keychain: FakeCredentialStore(), connectionsFileURL: file)
        let dir = try ClaudeFixtures.makeDirectory(name: "p", token: "secret-token-value")

        _ = try controller.connect(slotID: .claudeLegacyA, directory: dir, now: now)

        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("secret-token-value"))
    }

    // MARK: Duplicate binding rejection

    @Test func sameDirectoryCannotServeBothSlots() throws {
        let controller = ClaudeFixtures.makeController()
        let dir = try ClaudeFixtures.makeDirectory(name: "shared", token: "t1")

        _ = try controller.connect(slotID: .claudeLegacyA, directory: dir, now: now)
        #expect(throws: ConnectionControllerError.selectionFailed("directory already bound to another slot")) {
            _ = try controller.connect(slotID: .claudethe team, directory: dir, now: now)
        }
        // The second slot remains unconnected.
        #expect(controller.isConnected(.claudethe team) == false)
        #expect(controller.credential(for: .claudethe team) == nil)
    }

    // MARK: Malformed / missing sources

    @Test func connectRejectsDirectoryWithoutUsableCredentials() throws {
        let controller = ClaudeFixtures.makeController()
        let empty = try ClaudeFixtures.makeDirectory(name: "empty", token: "placeholder")
        try FileManager.default.removeItem(
            at: empty.appendingPathComponent(".credentials.json"))

        #expect(throws: ConnectionControllerError.noUsableCredentials) {
            _ = try controller.connect(slotID: .claudeLegacyA, directory: empty, now: now)
        }
        #expect(controller.isConnected(.claudeLegacyA) == false)
    }

    @Test func connectRejectsMalformedCredentialContent() throws {
        let controller = ClaudeFixtures.makeController()
        let broken = try ClaudeFixtures.makeDirectory(name: "broken", token: "x")
        try Data("}".utf8).write(to: broken.appendingPathComponent(".credentials.json"))

        #expect(throws: ConnectionControllerError.noUsableCredentials) {
            _ = try controller.connect(slotID: .claudeLegacyA, directory: broken, now: now)
        }
    }

    // MARK: Synchronization — AC4 changed identity

    @Test func ac4_identityChangeStopsSyncAndPreservesStoredSecret() throws {
        let store = FakeCredentialStore()
        let controller = ClaudeFixtures.makeController(store: store)
        let dir = try ClaudeFixtures.makeDirectory(
            name: "rotating", token: "original-token", uuid: "uuid-a")
        _ = try controller.connect(slotID: .claudeLegacyA, directory: dir, now: now)

        // The source rotates to a different identity.
        let rotated: [String: Any] = [
            "claudeAiOauth": ["accessToken": "different-token", "accountUuid": "uuid-b"]
        ]
        try JSONSerialization.data(withJSONObject: rotated)
            .write(to: dir.appendingPathComponent(".credentials.json"))

        #expect(throws: ConnectionControllerError.sourceIdentityChanged) {
            _ = try controller.synchronize(slotID: .claudeLegacyA, now: now)
        }

        // The stored Keychain secret is NOT overwritten (AC4).
        #expect(controller.credential(for: .claudeLegacyA)?.accessToken == "original-token")
        #expect(!store.log.contains(where: { $0.op == "save" && $0.slot == .claudeLegacyA })
                || store.log.filter({ $0.op == "save" && $0.slot == .claudeLegacyA }).count == 1,
                "only the initial import may save; identity change must not rewrite the secret")
    }

    @Test func syncRefreshesMaterialWhenIdentityMatches() throws {
        let store = FakeCredentialStore()
        let controller = ClaudeFixtures.makeController(store: store)
        let dir = try ClaudeFixtures.makeDirectory(
            name: "stable", token: "same-token", uuid: "uuid-same")
        _ = try controller.connect(slotID: .claudethe team, directory: dir, now: now)

        // Token rotation within the SAME identity (no accountUuid change).
        let refreshed: [String: Any] = [
            "claudeAiOauth": ["accessToken": "same-token-v2", "accountUuid": "uuid-same"]
        ]
        try JSONSerialization.data(withJSONObject: refreshed)
            .write(to: dir.appendingPathComponent(".credentials.json"))

        let connection = try controller.synchronize(slotID: .claudethe team, now: now)
        #expect(connection.importedAt == now)
        // Same-identity refresh updates the stored material.
        #expect(controller.credential(for: .claudethe team)?.accessToken == "same-token-v2")
    }

    @Test func syncOnUnconnectedSlotThrows() {
        let controller = ClaudeFixtures.makeController()
        #expect(throws: ConnectionControllerError.noUsableCredentials) {
            _ = try controller.synchronize(slotID: .claudeLegacyA)
        }
    }

    @Test func syncPropagatesUnresolvableSource() throws {
        let controller = ClaudeFixtures.makeController()
        let dir = try ClaudeFixtures.makeDirectory(name: "vanishing", token: "t")
        _ = try controller.connect(slotID: .claudeLegacyA, directory: dir, now: now)

        // Deleting the whole source directory makes the bookmark unresolvable.
        try FileManager.default.removeItem(at: dir.deletingLastPathComponent())

        #expect(throws: ClaudeProfileError.bookmarkUnresolvable) {
            _ = try controller.synchronize(slotID: .claudeLegacyA)
        }
    }

    // MARK: Disconnect — R8/I2

    @Test func r8_disconnectRemovesOnlyTargetSlotMaterial() throws {
        let store = FakeCredentialStore()
        let controller = ClaudeFixtures.makeController(store: store)
        let legacyADir = try ClaudeFixtures.makeDirectory(name: "h", token: "th")
        let inshaDir = try ClaudeFixtures.makeDirectory(name: "i", token: "ti")
        _ = try controller.connect(slotID: .claudeLegacyA, directory: legacyADir, now: now)
        _ = try controller.connect(slotID: .claudethe team, directory: inshaDir, now: now)

        controller.disconnect(slotID: .claudeLegacyA)

        // the legacy profile material gone.
        #expect(controller.credential(for: .claudeLegacyA) == nil)
        #expect(controller.isConnected(.claudeLegacyA) == false)

        // the team untouched (I2).
        #expect(controller.credential(for: .claudethe team)?.accessToken == "ti")
        #expect(controller.isConnected(.claudethe team))

        // External directories were never modified (R8).
        #expect(FileManager.default.fileExists(
            atPath: legacyADir.appendingPathComponent(".credentials.json").path))
        #expect(FileManager.default.fileExists(
            atPath: inshaDir.appendingPathComponent(".credentials.json").path))
    }

    // MARK: Inspection (pre-consent metadata only)

    @Test func inspectIdentityReturnsSanitizedMetadataOnly() throws {
        let dir = try ClaudeFixtures.makeDirectory(name: "inspect", token: "tok", uuid: "u-9")
        let metadata = try ClaudeAccountController.inspectIdentity(of: dir)
        #expect(metadata.accountUUID == "u-9")
        #expect(metadata.fingerprint == ClaudeProfileSource.fingerprint("tok"))
    }

    @Test func fingerprintIsDeterministicAndNonReversible() {
        let sameToken = ClaudeProfileSource.fingerprint("secret-token")
        let sameAgain = ClaudeProfileSource.fingerprint("secret-token")
        let differentToken = ClaudeProfileSource.fingerprint("secret-tokem")
        #expect(sameToken == sameAgain)
        #expect(sameToken != differentToken)
        #expect(!sameToken.contains("secret"))
        #expect(sameToken.count == 32)
    }
}

/// Concurrency: mutating the source during import must leave each slot atomic
/// and isolated. The controller reads the source exactly once per connect, so
/// concurrent rotation cannot interleave partial state into either slot.
@Suite struct ClaudeConnectionConcurrencyTests {

    @Test func concurrentSourceRotationKeepsSlotsIsolated() async throws {
        let store = FakeCredentialStore()
        let controller = ClaudeFixtures.makeController(store: store)
        let dirA = try ClaudeFixtures.makeDirectory(
            name: "rotating-a", token: "token-a1", uuid: "uuid-a")
        let dirB = try ClaudeFixtures.makeDirectory(
            name: "rotating-b", token: "token-b1", uuid: "uuid-b")

        // Concurrently connect both slots while rotating both sources.
        let rotationTask = Task.detached {
            for generation in 2...40 {
                let documentA: [String: Any] = [
                    "claudeAiOauth": ["accessToken": "token-a\(generation)", "accountUuid": "uuid-a"]
                ]
                let documentB: [String: Any] = [
                    "claudeAiOauth": ["accessToken": "token-b\(generation)", "accountUuid": "uuid-b"]
                ]
                try? JSONSerialization.data(withJSONObject: documentA)
                    .write(to: dirA.appendingPathComponent(".credentials.json"))
                try? JSONSerialization.data(withJSONObject: documentB)
                    .write(to: dirB.appendingPathComponent(".credentials.json"))
                try? await Task.sleep(nanoseconds: 200_000)
            }
        }

        _ = try controller.connect(slotID: .claudeLegacyA, directory: dirA)
        _ = try controller.connect(slotID: .claudethe team, directory: dirB)
        await rotationTask.value

        // Each slot holds a complete credential from ITS OWN identity family.
        let legacy = controller.credential(for: .claudeLegacyA)
        let insha = controller.credential(for: .claudethe team)

        #expect(legacy?.accessToken.hasPrefix("token-a") == true,
                "legacy must hold an A-family token, got \(legacy?.accessToken ?? "nil")")
        #expect(legacy?.accountUUID == "uuid-a")
        #expect(insha?.accessToken.hasPrefix("token-b") == true,
                "legacy-b must hold a B-family token, got \(insha?.accessToken ?? "nil")")
        #expect(insha?.accountUUID == "uuid-b")

        // Connection records agree with the imported material per slot.
        let connections = controller.loadConnections()
        #expect(connections[.claudeLegacyA]?.importedIdentity.accountUUID == "uuid-a")
        #expect(connections[.claudethe team]?.importedIdentity.accountUUID == "uuid-b")
    }
}
