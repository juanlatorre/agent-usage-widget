import SwiftUI
import AgentUsageCore
import UniformTypeIdentifiers

/// Connect / Connected management section for the OpenCode GO slot.
///
/// Owns its observable connection state via `@StateObject` so identity is
/// stable across parent re-renders. Holds only non-secret display data:
/// file name, sanitized identity, and the last action outcome. Key material
/// never reaches this layer.
struct OpenCodeConnectionSection: View {

    let slotID: AccountSlotID
    let statusModel: StatusModel

    var body: some View {
        InternalSection(slotID: slotID, statusModel: statusModel)
    }
}

private struct InternalSection: View {
    @StateObject private var viewModel: OpenCodeSectionViewModel

    let slotID: AccountSlotID

    init(slotID: AccountSlotID, statusModel: StatusModel) {
        self.slotID = slotID
        _viewModel = StateObject(wrappedValue: OpenCodeSectionViewModel(slotID: slotID, model: statusModel))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile connection")
                .font(.headline)

            if viewModel.isConnected {
                HStack(alignment: .center, spacing: 8) {
                    Label(viewModel.sourceName ?? "OpenCode auth file",
                          systemImage: "doc.badge.ellipsis")
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
                HStack(spacing: 8) {
                    Button("Connect") { viewModel.startConnect() }
                    Button("Or enter API key") { viewModel.showingManualKey = true }
                    if viewModel.isPicking {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("Select the OpenCode auth.json to import the opencode-go key. "
                     + "Credentials are copied into your Keychain; the original file "
                     + "is never modified. You can also enter the key manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if viewModel.showingManualKey {
                    HStack {
                        SecureField("opencode-go key", text: $viewModel.manualKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                        Button("Save key") { viewModel.saveManualKey() }
                            .disabled(viewModel.manualKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") { viewModel.cancelManualKey() }
                    }
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
            isPresented: $viewModel.showingFilePicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: viewModel.handlePickerResult)
    }
}

@MainActor
final class OpenCodeSectionViewModel: ObservableObject {

    let slotID: AccountSlotID
    private let model: StatusModel

    @Published private(set) var sourceName: String?
    @Published private(set) var identitySummary: String?
    @Published private(set) var isConnected: Bool
    @Published var statusMessage: String?
    @Published var showingFilePicker = false
    @Published var showingManualKey = false
    @Published var manualKey = ""
    var isPicking: Bool { showingFilePicker }

    init(slotID: AccountSlotID, model: StatusModel) {
        self.slotID = slotID
        self.model = model
        self.isConnected = model.openCodeManager?.isConnected(slotID) ?? false
        refreshDisplayState()
    }

    func refreshDisplayState() {
        guard let manager = model.openCodeManager else {
            sourceName = nil; identitySummary = nil; isConnected = false; return
        }
        if let connection = manager.connection(slotID) {
            sourceName = connection.source.fileName
            identitySummary = "identity \(connection.importedIdentity.fingerprint.prefix(8))…"
                + " · imported \(connection.importedAt.formatted(date: .abbreviated, time: .shortened))"
            isConnected = true
        } else {
            sourceName = nil; identitySummary = nil; isConnected = false
        }
    }

    func startConnect() {
        statusMessage = nil
        showingManualKey = false
        showingFilePicker = true
    }

    func startReconnect() {
        statusMessage = nil
        showingManualKey = false
        showingFilePicker = true
    }

    func saveManualKey() {
        let key = manualKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        switch model.connectOpenCodeSlotManually(slotID, apiKey: key) {
        case .success:
            statusMessage = nil
            showingManualKey = false
            manualKey = ""
        case .failure(let error):
            statusMessage = Self.message(for: error)
        }
        refreshDisplayState()
    }

    func cancelManualKey() {
        showingManualKey = false
        manualKey = ""
    }

    func testConnection() {
        Task { @MainActor in
            statusMessage = "Testing connection…"
            let outcome = await model.refreshOpenCodeSlot(slotID)
            switch outcome {
            case .updated:
                statusMessage = "Connection works."
            case .authenticationRequired, .sourceIdentityChanged:
                statusMessage = "Credentials were rejected. Reconnect this account."
            case .failed:
                statusMessage = "Could not reach OpenCode. Check your network and try again."
            }
            refreshDisplayState()
        }
    }

    func refreshNow() {
        Task { @MainActor in
            _ = await model.refreshOpenCodeSlot(slotID)
            refreshDisplayState()
        }
    }

    func disconnect() {
        model.disconnectOpenCodeSlot(slotID)
        statusMessage = nil
        showingManualKey = false
        manualKey = ""
        refreshDisplayState()
    }

    func handlePickerResult(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls): handlePickedFile(urls.first)
        case .failure: handlePickedFile(nil)
        }
    }

    func handlePickedFile(_ url: URL?) {
        guard let url else { return }
        switch model.connectOpenCodeSlot(slotID, file: url) {
        case .success: statusMessage = nil
        case .failure(let error): statusMessage = Self.message(for: error)
        }
        refreshDisplayState()
    }

    static func message(for error: Error) -> String {
        switch error {
        case OpenCodeConnectionError.noUsableCredentials:
            return "That file has no readable opencode-go key (auth.json)."
        case OpenCodeConnectionError.selectionFailed:
            return "This file is already bound to another account."
        default:
            return "Could not connect that file."
        }
    }
}
