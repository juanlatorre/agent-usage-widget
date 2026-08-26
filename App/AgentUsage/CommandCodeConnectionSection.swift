import SwiftUI
import AgentUsageCore
import UniformTypeIdentifiers

struct CommandCodeConnectionSection: View {

    let slotID: AccountSlotID
    let statusModel: StatusModel

    var body: some View {
        InternalSection(slotID: slotID, statusModel: statusModel)
    }
}

private struct InternalSection: View {
    @StateObject private var viewModel: CommandCodeSectionViewModel
    let slotID: AccountSlotID
    init(slotID: AccountSlotID, statusModel: StatusModel) {
        self.slotID = slotID
        _viewModel = StateObject(wrappedValue: CommandCodeSectionViewModel(slotID: slotID, model: statusModel))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile connection").font(.headline)
            if viewModel.isConnected {
                HStack(spacing: 8) {
                    Label(viewModel.sourceName ?? "Command Code auth file", systemImage: "doc.badge.ellipsis")
                    Spacer()
                    Button("Reconnect") { viewModel.startReconnect() }
                    Button("Test Connection") { viewModel.testConnection() }
                    Button("Refresh Now") { viewModel.refreshNow() }
                    Button("Disconnect", role: .destructive) { viewModel.disconnect() }
                }
                if let summary = viewModel.identitySummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Connect") { viewModel.startConnect() }
                    Button("Or enter API key") { viewModel.showManualEntry() }
                    if viewModel.isPicking { ProgressView().controlSize(.small) }
                }
                Text("Select the Command Code auth.json (apiKey). Credentials are copied into your Keychain; the original file is never modified. You can also enter the key manually.")
                    .font(.caption).foregroundStyle(.secondary)
                if viewModel.showingManualKey {
                    HStack {
                        SecureField("Command Code apiKey", text: $viewModel.manualKey)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                        Button("Save key") { viewModel.saveManualKey() }
                            .disabled(viewModel.manualKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") { viewModel.cancelManualKey() }
                    }
                }
            }
            if let message = viewModel.statusMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .fileImporter(isPresented: $viewModel.showingFilePicker, allowedContentTypes: [.json],
                      allowsMultipleSelection: false, onCompletion: viewModel.handlePickerResult)
    }
}

@MainActor
final class CommandCodeSectionViewModel: ObservableObject {

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
        self.slotID = slotID; self.model = model
        self.isConnected = model.commandCodeManager?.isConnected(slotID) ?? false
        refreshDisplayState()
    }

    func refreshDisplayState() {
        guard let manager = model.commandCodeManager else {
            sourceName = nil; identitySummary = nil; isConnected = false; return
        }
        if let c = manager.connection(slotID) {
            sourceName = c.source.fileName
            identitySummary = "identity \(c.importedIdentity.fingerprint.prefix(8))…"
                + " · imported \(c.importedAt.formatted(date: .abbreviated, time: .shortened))"
            isConnected = true
        } else { sourceName = nil; identitySummary = nil; isConnected = false }
    }

    func startConnect() { statusMessage = nil; showingManualKey = false; showingFilePicker = true }
    func startReconnect() { statusMessage = nil; showingManualKey = false; showingFilePicker = true }
    func showManualEntry() { showingFilePicker = false; statusMessage = nil; showingManualKey = true }

    func saveManualKey() {
        showingFilePicker = false
        let raw = manualKey
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch model.connectCommandCodeSlotManually(slotID, apiKey: raw) {
        case .success:
            statusMessage = nil; showingManualKey = false; manualKey = ""
            Task { @MainActor in _ = await model.refreshCommandCodeSlot(slotID); refreshDisplayState() }
        case .failure(let error): statusMessage = Self.manualMessage(for: error)
        }
        refreshDisplayState()
    }
    func cancelManualKey() { showingManualKey = false; manualKey = ""; statusMessage = nil }

    func testConnection() {
        Task { @MainActor in
            statusMessage = "Testing connection…"
            let outcome = await model.refreshCommandCodeSlot(slotID)
            switch outcome {
            case .updated: statusMessage = "Connection works."
            case .unavailable: statusMessage = "Subscription is inactive or usage cannot be confirmed."
            case .authenticationRequired, .sourceIdentityChanged:
                statusMessage = "Credentials were rejected. Reconnect this account."
            case .rateLimited(let retryAfter):
                if let retryAfter {
                    let minutes = Int(ceil(retryAfter / 60))
                    statusMessage = "Command Code rate limited. Waiting \(minutes) min before retrying."
                } else {
                    statusMessage = "Command Code rate limited. Backing off before retrying."
                }
            case .failed: statusMessage = "Could not reach Command Code. Check your network and try again."
            }
            refreshDisplayState()
        }
    }
    func refreshNow() {
        Task { @MainActor in _ = await model.refreshCommandCodeSlot(slotID); refreshDisplayState() }
    }
    func disconnect() {
        model.disconnectCommandCodeSlot(slotID); statusMessage = nil; showingManualKey = false; manualKey = ""; refreshDisplayState()
    }
    func handlePickerResult(_ result: Result<[URL], any Error>) {
        switch result { case let .success(urls): handlePickedFile(urls.first); case .failure: handlePickedFile(nil) }
    }
    func handlePickedFile(_ url: URL?) {
        guard let url else { return }
        switch model.connectCommandCodeSlot(slotID, file: url) {
        case .success: statusMessage = nil
        case .failure(let error): statusMessage = Self.message(for: error)
        }
        refreshDisplayState()
    }
    static func message(for error: Error) -> String {
        switch error {
        case CommandCodeConnectionError.noUsableCredentials: return "That file has no readable Command Code apiKey (auth.json)."
        case CommandCodeConnectionError.selectionFailed: return "This file is already bound to another account."
        default:
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == 513 {
                return "System blocked writing to the shared folder (Group Container — Team change). Fix: quit AgentUsage, run: rm -rf ~/Library/Group\\ Containers/group.com.juanlatorre.agent-usage && open /Applications/AgentUsage.app — then try Save again."
            }
            NSLog("[AgentUsage] CommandCode connect failed: %@", String(describing: error))
            return "Could not connect that file: \(error)."
        }
    }
    static func manualMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == 513 {
            return "System blocked writing to the shared folder (Group Container — Team change). Fix: quit AgentUsage, run: rm -rf ~/Library/Group\\ Containers/group.com.juanlatorre.agent-usage && open /Applications/AgentUsage.app — then try Save again. The key itself is fine."
        }
        if let ke = error as? KeychainStoreError {
            NSLog("[AgentUsage] CommandCode manual Keychain error: %@", String(describing: ke))
            return "Cannot save to Keychain: \(ke). Unlock login keychain and try again."
        }
        switch error {
        case CommandCodeConnectionError.noUsableCredentials:
            return "That key doesn't look like a Command Code apiKey. Paste the apiKey value or the whole auth.json — we extract it. Avoid surrounding words or line breaks."
        case CommandCodeConnectionError.selectionFailed: return "That key is already bound to another account."
        default:
            NSLog("[AgentUsage] CommandCode manual save failed: %@", String(describing: error))
            return "Could not save that key: \(error). Check the token and try again."
        }
    }
}
