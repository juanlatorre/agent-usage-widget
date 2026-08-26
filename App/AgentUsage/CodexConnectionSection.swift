import SwiftUI
import AgentUsageCore
import UniformTypeIdentifiers

/// Connect / Connected management section for one profile-sourced slot
/// (Claude children 02 and Codex child 03).
///
/// Owns its observable connection state via `@StateObject` so identity is
/// stable across parent re-renders. Holds only non-secret display data:
/// directory name, sanitized identity, and the last action outcome. Credential
/// material never reaches this layer.
struct ProfileConnectionSection: View {

    let slotID: AccountSlotID
    let statusModel: StatusModel

    /// Which connection backend this slot routes to (connection routing only,
    /// never presentation branching).
    private var family: ProviderFamily {
        AccountCatalog.slot(for: slotID)?.provider ?? .claude
    }

    var body: some View {
        switch family {
        case .claude:
            ClaudeConnectionSection(slotID: slotID, statusModel: statusModel)
        case .gpt:
            CodexConnectionSection(slotID: slotID, statusModel: statusModel)
        default:
            EmptyView()
        }
    }
}

/// Connect / Connected management section for the GPT Personal slot.
struct CodexConnectionSection: View {

    let slotID: AccountSlotID
    let statusModel: StatusModel

    var body: some View {
        InternalSection(slotID: slotID, statusModel: statusModel)
    }
}

private struct InternalSection: View {
    @StateObject private var viewModel: CodexSectionViewModel

    let slotID: AccountSlotID

    init(slotID: AccountSlotID, statusModel: StatusModel) {
        self.slotID = slotID
        _viewModel = StateObject(wrappedValue: CodexSectionViewModel(slotID: slotID, model: statusModel))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile connection")
                .font(.headline)

            if viewModel.isConnected {
                HStack(alignment: .center, spacing: 8) {
                    Label(viewModel.sourceName ?? "Profile directory",
                          systemImage: "folder.badge.person.crop")
                    Spacer()
                    Button("Reconnect") { viewModel.startReconnect() }
                    Button("Test Connection") { viewModel.testConnection() }
                    Button("Refresh Now") { viewModel.refreshNow() }
                    Button("Disconnect", role: .destructive) { viewModel.disconnect() }
                }
                if let summary = viewModel.identitySummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button("Connect ~/.codex") { viewModel.connectDefault() }
                    Button("Or choose folder") { viewModel.startConnect() }
                    if viewModel.isPicking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text("\u{201c}Connect ~/.codex\u{201d} uses your local Codex session directly. \u{201c}Choose folder\u{201d} is for alternate profile dirs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let message = viewModel.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .fileImporter(
            isPresented: $viewModel.showingDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: viewModel.handlePickerResult)
    }
}

/// Observable view state for one Codex slot's connection section.
@MainActor
final class CodexSectionViewModel: ObservableObject {

    let slotID: AccountSlotID
    private let model: StatusModel

    @Published private(set) var sourceName: String?
    @Published private(set) var identitySummary: String?
    @Published private(set) var isConnected: Bool
    @Published var statusMessage: String?
    @Published var showingDirectoryPicker = false
    var isPicking: Bool { showingDirectoryPicker }

    init(slotID: AccountSlotID, model: StatusModel) {
        self.slotID = slotID
        self.model = model
        self.isConnected = model.codexManager?.isConnected(slotID) ?? false
        refreshDisplayState()
    }

    // MARK: - Display state

    func refreshDisplayState() {
        guard let manager = model.codexManager else {
            sourceName = nil
            identitySummary = nil
            isConnected = false
            return
        }
        if let connection = manager.connection(slotID) {
            sourceName = connection.source.directoryName
            var parts: [String] = []
            if let accountID = connection.importedIdentity.accountID {
                parts.append("identity \(accountID.prefix(8))…")
            } else {
                parts.append("identity \(connection.importedIdentity.fingerprint.prefix(8))…")
            }
            parts.append("imported \(connection.importedAt.formatted(date: .abbreviated, time: .shortened))")
            identitySummary = parts.joined(separator: " · ")
            isConnected = true
        } else {
            sourceName = nil
            identitySummary = nil
            isConnected = false
        }
    }

    // MARK: - Actions

    func connectDefault() {
        switch model.connectCodexDefault(slotID) {
        case .success: statusMessage = nil
        case .failure(let error): statusMessage = Self.message(for: error)
        }
        refreshDisplayState()
    }

    /// Open the directory picker for a fresh connection.
    func startConnect() {
        statusMessage = nil
        showingDirectoryPicker = true
    }

    /// Open the directory picker to replace the existing binding (Reconnect).
    func startReconnect() {
        statusMessage = nil
        showingDirectoryPicker = true
    }

    /// Non-destructive credential check through the live transport.
    func testConnection() {
        Task { @MainActor in
            statusMessage = "Testing connection…"
            let outcome = await model.refreshCodexSlot(slotID)
            switch outcome {
            case .updated:
                statusMessage = "Connection works."
            case .authenticationRequired, .sourceIdentityChanged:
                statusMessage = "Credentials were rejected. Reconnect this account."
            case .rateLimited(let retryAfter):
                if let retryAfter {
                    let minutes = Int(ceil(retryAfter / 60))
                    statusMessage = "Codex rate limited. Waiting \(minutes) min before retrying."
                } else {
                    statusMessage = "Codex rate limited. Backing off before retrying."
                }
            case .failed:
                statusMessage = "Could not reach ChatGPT. Check your network and try again."
            }
            refreshDisplayState()
        }
    }

    /// Manual refresh (parent manual-refresh surfaces).
    func refreshNow() {
        Task { @MainActor in
            _ = await model.refreshCodexSlot(slotID)
            refreshDisplayState()
        }
    }

    /// Disconnect deletes only this slot's app-owned material (R7).
    func disconnect() {
        model.disconnectCodexSlot(slotID)
        statusMessage = nil
        refreshDisplayState()
    }

    /// Picker callback: bind the selected directory to the slot.
    func handlePickerResult(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls): handlePickedDirectory(urls.first)
        case .failure: handlePickedDirectory(nil)
        }
    }

    /// Picker callback: bind the selected directory to the slot.
    func handlePickedDirectory(_ url: URL?) {
        guard let url else { return }
        switch model.connectCodexSlot(slotID, directory: url) {
        case .success:
            statusMessage = nil
        case .failure(let error):
            statusMessage = Self.message(for: error)
        }
        refreshDisplayState()
    }

    static func message(for error: Error) -> String {
        switch error {
        case CodexConnectionError.noUsableCredentials:
            return "That folder has no readable Codex credentials (auth.json)."
        case CodexConnectionError.selectionFailed(let msg):
            if msg.lowercased().contains("already bound") {
                return "This directory is already bound to another account."
            }
            if msg.lowercased().contains("unreadable") || msg.lowercased().contains("bookmark") {
                return "Could not access that folder. Use “Or choose folder” and pick ~/.codex manually to grant access."
            }
            return "Could not connect that folder: \(msg)"
        case CodexProfileError.directoryUnreadable:
            return "Could not access that folder. Use “Or choose folder” and pick ~/.codex manually to grant access."
        case CodexProfileError.authFileMissing:
            return "That folder has no auth.json. Is this ~/.codex with a ChatGPT login?"
        case CodexProfileError.credentialsMalformed:
            return "auth.json exists but has no usable ChatGPT token. Try re-logging in with Codex."
        default:
            return "Could not connect that folder: \(String(describing: error))"
        }
    }
}
