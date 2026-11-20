import SwiftUI

/// Where the NUEDIT tower is, and whether it answers. Leave the address blank to use this
/// machine's SSOT (`api_url` in ~/.nuhandoff/hub.toml); the editor works fully without a tower.
struct BackendPane: View {
    @AppStorage(NUEDITBackendSettingsStore.baseURLOverrideKey) private var baseURLOverride = ""

    @State private var keyDraft = ""
    @State private var keyError: String?
    @State private var resolved: NUEDITBackendSettings?
    @State private var reachability: Reachability = .unknown
    @State private var keyCheck: NUEDITBackendClient.AgentKeyCheck?
    @State private var probe: Task<Void, Never>?

    private enum Reachability: Equatable { case unknown, checking, reachable, unreachable }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: "NUEDIT tower") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    addressField
                    agentKeyField
                    status
                }
            }
        }
        .task { await refresh() }
        .onChange(of: baseURLOverride) { _, _ in scheduleRefresh() }
        .onDisappear { probe?.cancel() }
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            fieldTitle("Address")
            TextField(resolved?.baseURL?.absoluteString ?? "Not configured", text: $baseURLOverride)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm).monospaced())
            fieldHelp("Blank uses this machine's api_url from ~/.nuhandoff/hub.toml.")
        }
    }

    private var hasStoredKey: Bool { resolved?.agentKey != nil }

    private var agentKeyField: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            fieldTitle("Agent key")
            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(hasStoredKey ? "Stored in the Keychain" : "Not set", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.sm).monospaced())
                    .onSubmit { storeKey(keyDraft) }
                Button("Save") { storeKey(keyDraft) }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasStoredKey {
                    Button("Remove") { storeKey("") }
                }
            }
            if let keyError {
                Text(keyError)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            } else {
                fieldHelp("Mint one on the tower with POST /api/v1/agent/keys. Held in the Keychain.")
            }
        }
    }

    private func fieldTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.md))
            .foregroundStyle(AppTheme.Text.primaryColor)
    }

    private func fieldHelp(_ help: String) -> some View {
        Text(help)
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
    }

    private var status: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: AppTheme.IconSize.xs / 2, height: AppTheme.IconSize.xs / 2)
            Text(statusText)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Spacer(minLength: 0)
            Button("Check") { scheduleRefresh() }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Accent.primary)
                .disabled(reachability == .checking)
        }
    }

    private var statusColor: Color {
        switch reachability {
        case .reachable:
            switch keyCheck {
            case .accepted: AppTheme.Status.successColor
            case .rejected: AppTheme.Status.errorColor
            case .missing, .unknown, nil: AppTheme.Status.warningColor
            }
        case .unreachable: AppTheme.Status.warningColor
        case .unknown, .checking: AppTheme.Text.tertiaryColor
        }
    }

    private var statusText: String {
        guard resolved?.isConfigured == true else {
            return "No tower configured — the editor works locally; ingest stays on this Mac."
        }
        switch reachability {
        case .checking: return "Checking…"
        case .unreachable: return "No answer. Footage stays local and registers later."
        case .unknown: return " "
        case .reachable:
            switch keyCheck {
            case .accepted: return "Connected. Agent key accepted."
            case .missing: return "Connected. Add an agent key to register footage."
            case .rejected: return "Connected, but the tower rejected this key. Re-authorize this Mac."
            case .unknown(let reason): return "Connected. Agent key not checked: \(reason)"
            case nil: return "Connected."
            }
        }
    }

    private func storeKey(_ key: String) {
        probe?.cancel()
        probe = Task { @MainActor in
            do {
                try await NUEDITBackendSettingsStore.storeAgentKey(key)
                keyDraft = ""
                keyError = nil
            } catch {
                keyError = error.localizedDescription
            }
            await refresh()
        }
    }

    private func scheduleRefresh() {
        probe?.cancel()
        probe = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))   // typing a host shouldn't probe per keystroke
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func refresh() async {
        await NUEDITBackendClient.shared.invalidateSettings()
        let settings = await NUEDITBackendClient.shared.currentSettings()
        resolved = settings
        keyCheck = nil
        guard settings.isConfigured else {
            reachability = .unknown
            return
        }
        reachability = .checking
        let reachable = await NUEDITBackendClient.shared.isReachable()
        guard !Task.isCancelled else { return }
        guard reachable else {
            reachability = .unreachable
            return
        }
        let check = await NUEDITBackendClient.shared.checkAgentKey()
        guard !Task.isCancelled else { return }
        keyCheck = check
        reachability = .reachable
    }
}
