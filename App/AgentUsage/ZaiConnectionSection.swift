import SwiftUI
import AgentUsageCore

struct ZaiConnectionSection: View {
    let slotID: AccountSlotID
    let statusModel: StatusModel
    var body: some View { InternalSection(slotID: slotID, statusModel: statusModel) }
}

private struct InternalSection: View {
    @StateObject private var viewModel: ZaiSectionViewModel
    let slotID: AccountSlotID
    init(slotID: AccountSlotID, statusModel: StatusModel) {
        self.slotID = slotID
        _viewModel = StateObject(wrappedValue: ZaiSectionViewModel(slotID: slotID, model: statusModel))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile connection").font(.headline)
            if viewModel.isConnected {
                HStack(spacing: 8) {
                    Label(viewModel.sourceName ?? "Z.ai auth file", systemImage: "doc.badge.ellipsis")
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
                Text("Select the opencode auth.json (zai-coding-plan) or a Z.ai token file. Only the 5-hour coding window is tracked. You can also enter the key manually.")
                    .font(.caption).foregroundStyle(.secondary)
                if viewModel.showingManualKey {
                    HStack {
                        SecureField("Z.ai API key", text: $viewModel.manualKey)
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
final class ZaiSectionViewModel: ObservableObject {
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
        self.isConnected = model.zaiManager?.isConnected(slotID) ?? false
        refreshDisplayState()
    }
    func refreshDisplayState() {
        guard let m = model.zaiManager else { sourceName = nil; identitySummary = nil; isConnected = false; return }
        if let c = m.connection(slotID) {
            sourceName = c.source.fileName
            identitySummary = "identity \(c.importedIdentity.fingerprint.prefix(8))… · imported \(c.importedAt.formatted(date: .abbreviated, time: .shortened))"
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
        switch model.connectZaiSlotManually(slotID, apiKey: raw) {
        case .success:
            statusMessage = nil; showingManualKey = false; manualKey = ""
            // Auto-refresh so the user isn't stuck on "Loading..." until they press Refresh Now
            Task { @MainActor in _ = await model.refreshZaiSlot(slotID); refreshDisplayState() }
        case .failure(let e): statusMessage = Self.manualMessage(for: e)
        }
        refreshDisplayState()
    }
    func cancelManualKey() { showingManualKey = false; manualKey = ""; statusMessage = nil }
    func testConnection() {
        Task { @MainActor in
            statusMessage = "Testing connection…"
            let o = await model.refreshZaiSlot(slotID)
            switch o {
            case .updated: statusMessage = "Connection works."
            case .authenticationRequired, .sourceIdentityChanged: statusMessage = "Credentials were rejected. Reconnect this account."
            case .failed: statusMessage = "Could not reach Z.ai. Check your network and try again."
            }
            refreshDisplayState()
        }
    }
    func refreshNow() { Task { @MainActor in _ = await model.refreshZaiSlot(slotID); refreshDisplayState() } }
    func disconnect() { model.disconnectZaiSlot(slotID); statusMessage = nil; showingManualKey = false; manualKey = ""; refreshDisplayState() }
    func handlePickerResult(_ r: Result<[URL], any Error>) {
        switch r { case let .success(urls): handlePickedFile(urls.first); case .failure: handlePickedFile(nil) }
    }
    func handlePickedFile(_ url: URL?) {
        guard let url else { return }
        switch model.connectZaiSlot(slotID, file: url) {
        case .success: statusMessage = nil
        case .failure(let e): statusMessage = Self.message(for: e)
        }
        refreshDisplayState()
    }
    static func message(for error: Error) -> String {
        switch error {
        case ZaiConnectionError.noUsableCredentials: return "That file has no readable Z.ai token (zai-coding-plan)."
        case ZaiConnectionError.selectionFailed: return "This file is already bound to another account."
        default: return "Could not connect that file."
        }
    }
    /// Manual-entry errors get a more actionable hint (paste the raw key or whole auth.json).
    static func manualMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == 513 {
            // Already handled in ZaiAccountController fallback; this path only reached if fallback also failed
            NSLog("[AgentUsage] Z.ai manual save 513 even after fallback: %@", String(describing: error))
            return "System blocked writing to the shared folder (Group Container). Fix: quit AgentUsage, run: rm -rf ~/Library/Group\\ Containers/group.com.juanlatorre.agent-usage && open /Applications/AgentUsage.app — then try Save again. The token itself is fine; it is a macOS Team container issue."
        }
        if let ke = error as? KeychainStoreError {
            NSLog("[AgentUsage] Z.ai manual save Keychain error: %@", String(describing: ke))
            return "Cannot save to Keychain: \(ke). If this persists after reinstalling the signed build, open Keychain Access → right-click login → Unlock."
        }
        switch error {
        case ZaiConnectionError.noUsableCredentials:
            return "That key doesn't look like a Z.ai token. Copy zai-coding-plan → key from auth.json (the 32-hex.suffix value) or paste the whole auth.json — we extract it. Avoid surrounding words or line breaks."
        case ZaiConnectionError.selectionFailed: return "That token is already bound to another account."
        default:
            NSLog("[AgentUsage] Z.ai manual save failed: %@", String(describing: error))
            return "Could not save that key: \(error). Check the token and try again."
        }
    }
}
