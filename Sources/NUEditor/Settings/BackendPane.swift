import SwiftUI

/// Where the NUEDIT tower is, and whether it answers. Leave the address blank to use this
/// machine's SSOT (`api_url` in ~/.nuhandoff/hub.toml); the editor works fully without a tower.
struct BackendPane: View {
    @AppStorage(NUEDITBackendSettingsStore.baseURLOverrideKey) private var baseURLOverride = ""
    @AppStorage(NUEDITBackendSettingsStore.tokenKey) private var token = ""

    @State private var resolved: NUEDITBackendSettings?
    @State private var reachability: Reachability = .unknown
    @State private var probe: Task<Void, Never>?

    private enum Reachability: Equatable { case unknown, checking, reachable, unreachable }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: "NUEDIT tower") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    field(
                        title: "Address",
                        help: "Blank uses this machine's api_url from ~/.nuhandoff/hub.toml.",
                        placeholder: resolvedPlaceholder,
                        text: $baseURLOverride
                    )
                    field(
                        title: "Token",
                        help: "Optional. The tower is unauthenticated on the tailnet today.",
                        placeholder: "None",
                        text: $token
                    )
                    status
                }
            }
        }
        .task { await refresh() }
        .onChange(of: baseURLOverride) { _, _ in scheduleRefresh() }
        .onChange(of: token) { _, _ in scheduleRefresh() }
        .onDisappear { probe?.cancel() }
    }

    private var resolvedPlaceholder: String {
        resolved?.baseURL?.absoluteString ?? "Not configured"
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
        case .reachable: AppTheme.Status.successColor
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
        case .reachable: return "Connected."
        case .unreachable: return "No answer. Footage stays local and registers later."
        case .unknown: return " "
        }
    }

    private func field(title: String, help: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm).monospaced())
            Text(help)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
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
        guard settings.isConfigured else {
            reachability = .unknown
            return
        }
        reachability = .checking
        let reachable = await NUEDITBackendClient.shared.isReachable()
        guard !Task.isCancelled else { return }
        reachability = reachable ? .reachable : .unreachable
    }
}
