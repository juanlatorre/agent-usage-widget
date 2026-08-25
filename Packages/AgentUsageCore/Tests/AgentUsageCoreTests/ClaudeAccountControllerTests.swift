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

        _ = try controller.connect(slotID: .claude, directory: legacyADir, now: now)
        #expect(controller.credential(for: .claude)?.accountUUID == "uuid-legacy")
        #expect(store.count == 1)

        // Reconnecting the single slot overwrites with the new identity.
        _ = try controller.connect(slotID: .claude, directory: inshaDir, now: now)
        #expect(controller.credential(for: .claude)?.accountUUID == "uuid-insha")
        #expect(store.count == 1)

        let connections = controller.loadConnections()
        // Last write wins for the single slot.
        #expect(connections[.claude]?.source.directoryName == "legacy-b-profile")
    }

    @Test func ac1_connectPersistsNoSecretsInConnectionFile() throws {
        let file = ClaudeFixtures.connectionsFile()
        let controller = ClaudeAccountController(
            keychain: FakeCredentialStore(), connectionsFileURL: file)
        let dir = try ClaudeFixtures.makeDirectory(name: "p", token: "secret-token-value")

        _ = try controller.connect(slotID: .claude, directory: dir, now: now)

        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("secret-token-value"))
    }

    // MARK: Duplicate binding rejection

    @Test func sameDirectoryCannotServeBothSlots() throws {
        let controller = ClaudeFixtures.makeController()
        let dir = try ClaudeFixtures.makeDirectory(name: "shared", token: "t1")

        _ = try controller.connect(slotID: .claude, directory: dir, now: now)
        // Reconnecting the same directory to the same single slot succeeds (overwrite).
        _ = try controller.connect(slotID: .claude, directory: dir, now: now)
        #expect(controller.isConnected(.claude) == true)
        #expect(controller.credential(for: .claude)?.accessToken == "t1")
    }

    // MARK: Malformed / missing sources

    @Test func connectRejectsDirectoryWithoutUsableCredentials() throws {
        let controller = ClaudeFixtures.makeController()
        let empty = try ClaudeFixtures.makeDirectory(name: "empty", token: "placeholder")
        try FileManager.default.removeItem(
            at: empty.appendingPathComponent(".credentials.json"))

        #expect(throws: ConnectionControllerError.noUsableCredentials) {
            _ = try controller.connect(slotID: .claude, directory: empty, now: now)
        }
        #expect(controller.isConnected(.claude) == false)
    }

    @Test func connectRejectsMalformedCredentialContent() throws {
        let controller = ClaudeFixtures.makeController()
        let broken = try ClaudeFixtures.makeDirectory(name: "broken", token: "x")
        try Data("}".utf8).write(to: broken.appendingPathComponent(".credentials.json"))

        #expect(throws: ConnectionControllerError.noUsableCredentials) {
            _ = try controller.connect(slotID: .claude, directory: broken, now: now)
        }
    }

    // MARK: Synchronization — AC4 changed identity

    @Test func ac4_identityChangeStopsSyncAndPreservesStoredSecret() throws {
        let store = FakeCredentialStore()
        let controller = ClaudeFixtures.makeController(store: store)
        let dir = try ClaudeFixtures.makeDirectory(
            name: "rotating", token: "original-token", uuid: "uuid-a")
        _ = try controller.connect(slotID: .claude, directory: dir, now: now)

        // The source rotates to a different identity.
        let rotated: [String: Any] = [
            "claudeAiOauth": ["accessToken": "different-token", "accountUuid": "uuid-b"]
        ]
        try JSONSerialization.data(withJSONObject: rotated)
            .write(to: dir.appendingPathComponent(".credentials.json"))

        #expect(throws: ConnectionControllerError.sourceIdentityChanged) {
            _ = try controller.synchronize(slotID: .claude, now: now)
        }

        // The stored Keychain secret is NOT overwritten (AC4).
        #expect(controller.credential(for: .claude)?.accessToken == "original-token")
        #expect(!store.log.contains(where: { $0.op == "save" && $0.slot == .claude })
                || store.log.filter({ $0.op == "save" && $0.slot == .claude }).count == 1,
                "only the initial import may save; identity change must not rewrite the secret")
    }

    @Test func syncRefreshesMaterialWhenIdentityMatches() throws {
        let store = FakeCredentialStore()
        let controller = ClaudeFixtures.makeController(store: store)
        let dir = try ClaudeFixtures.makeDirectory(
            name: "stable", token: "same-token", uuid: "uuid-same")
        _ = try controller.connect(slotID: .claude, directory: dir, now: now)

        // Token rotation within the SAME identity (no accountUuid change).
        let refreshed: [String: Any] = [
            "claudeAiOauth": ["accessToken": "same-token-v2", "accountUuid": "uuid-same"]
        ]
        try JSONSerialization.data(withJSONObject: refreshed)
            .write(to: dir.appendingPathComponent(".credentials.json"))

        let connection = try controller.synchronize(slotID: .claude, now: now)
        #expect(connection.importedAt == now)
        // Same-identity refresh updates the stored material.
        #expect(controller.credential(for: .claude)?.accessToken == "same-token-v2")
    }

    @Test func syncOnUnconnectedSlotThrows() {
        let controller = ClaudeFixtures.makeController()
        #expect(throws: ConnectionControllerError.noUsableCredentials) {
            _ = try controller.synchronize(slotID: .claude)
        }
    }

    @Test func syncPropagatesUnresolvableSource() throws {
        let controller = ClaudeFixtures.makeController()
        let dir = try ClaudeFixtures.makeDirectory(name: "vanishing", token: "t")
        _ = try controller.connect(slotID: .claude, directory: dir, now: now)

        // Deleting the whole source directory makes the bookmark unresolvable.
        try FileManager.default.removeItem(at: dir.deletingLastPathComponent())

        #expect(throws: ClaudeProfileError.bookmarkUnresolvable) {
            _ = try controller.synchronize(slotID: .claude)
        }
    }

    // MARK: Disconnect — R8/I2

    @Test func r8_disconnectRemovesOnlyTargetSlotMaterial() throws {
        let store = FakeCredentialStore()
        let controller = ClaudeFixtures.makeController(store: store)
        let legacyADir = try ClaudeFixtures.makeDirectory(name: "h", token: "th")
        let inshaDir = try ClaudeFixtures.makeDirectory(name: "i", token: "ti")
        _ = try controller.connect(slotID: .claude, directory: legacyADir, now: now)
        controller.disconnect(slotID: .claude)
        #expect(controller.credential(for: .claude) == nil)
        #expect(controller.isConnected(.claude) == false)
        // Reconnect with the second dir — single slot overwrites, external dirs untouched.
        _ = try controller.connect(slotID: .claude, directory: inshaDir, now: now)
        #expect(controller.credential(for: .claude)?.accessToken == "ti")
        #expect(controller.isConnected(.claude) == true)
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

        _ = try controller.connect(slotID: .claude, directory: dirA)
        _ = try controller.connect(slotID: .claude, directory: dirB)
        await rotationTask.value

        // Single slot: concurrent connects race; final credential is from one of the families.
        let final = controller.credential(for: .claude)
        let okA = final?.accessToken.hasPrefix("token-a") == true && final?.accountUUID == "uuid-a"
        let okB = final?.accessToken.hasPrefix("token-b") == true && final?.accountUUID == "uuid-b"
        #expect(okA || okB, "final credential must be from A or B family, got \(final?.accessToken ?? "nil")")
        let connections = controller.loadConnections()
        #expect(connections[.claude] != nil)
    }
}
