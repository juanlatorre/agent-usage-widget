import SwiftUI
import AgentUsageCore
import UniformTypeIdentifiers

/// Connect / Connected management section for one Claude slot.
///
/// Owns its observable connection state via `@StateObject` so identity is
/// stable across parent re-renders. Holds only non-secret display data:
/// directory name, sanitized identity, and the last action outcome. Credential
/// material never reaches this layer.
struct ClaudeConnectionSection: View {

    let slotID: AccountSlotID
    let statusModel: StatusModel

    var body: some View {
        InternalSection(slotID: slotID, statusModel: statusModel)
    }
}

private struct InternalSection: View {
    @StateObject private var viewModel: ViewModel

    let slotID: AccountSlotID

    init(slotID: AccountSlotID, statusModel: StatusModel) {
        self.slotID = slotID
        _viewModel = StateObject(wrappedValue: ViewModel(slotID: slotID, model: statusModel))
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
                HStack {
                    Button("Connect") { viewModel.startConnect() }
                    if viewModel.isPicking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text("Select the Claude profile directory to import. Credentials are "
                     + "copied into your Keychain; the original folder is never modified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

/// Observable view state for one Claude slot's connection section.
@MainActor
final class ViewModel: ObservableObject {

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
        self.isConnected = model.claudeManager?.isConnected(slotID) ?? false
        refreshDisplayState()
    }

    // MARK: - Display state

    func refreshDisplayState() {
        guard let manager = model.claudeManager else {
            sourceName = nil
            identitySummary = nil
            isConnected = false
            return
        }
        if let connection = manager.connection(slotID) {
            sourceName = connection.source.directoryName
            var parts: [String] = []
            if let uuid = connection.importedIdentity.accountUUID {
                parts.append("identity \(uuid.prefix(8))…")
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
            let outcome = await model.refreshClaudeSlot(slotID)
            switch outcome {
            case .updated:
                statusMessage = "Connection works."
            case .authenticationRequired, .sourceIdentityChanged:
                statusMessage = "Credentials were rejected. Reconnect this account."
            case .failed:
                statusMessage = "Could not reach Claude. Check your network and try again."
            }
            refreshDisplayState()
        }
    }

    /// Manual refresh (child spec manual-refresh surfaces).
    func refreshNow() {
        Task { @MainActor in
            _ = await model.refreshClaudeSlot(slotID)
            refreshDisplayState()
        }
    }

    /// Disconnect deletes only this slot's app-owned material (R8/I2).
    func disconnect() {
        model.disconnectClaudeSlot(slotID)
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
        switch model.connectClaudeSlot(slotID, directory: url) {
        case .success:
            statusMessage = nil
        case .failure(let error):
            statusMessage = Self.message(for: error)
        }
        refreshDisplayState()
    }

    static func message(for error: Error) -> String {
        switch error {
        case ConnectionControllerError.noUsableCredentials:
            return "That folder has no readable Claude credentials (.credentials.json)."
        case ConnectionControllerError.selectionFailed:
            return "This directory is already bound to the other Claude account."
        default:
            return "Could not connect that folder."
        }
    }
}
