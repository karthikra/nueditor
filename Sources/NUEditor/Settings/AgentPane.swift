import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var profile: String = ""
    @State private var region: String = ""
    @State private var connection: AgentService.Connection = .checking
    @State private var check: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: "AI Chat") {
                bedrockSection
            }
            SettingsSection(title: "Integrations") {
                mcpSection
            }
        }
        .onAppear(perform: load)
        .onDisappear { check?.cancel() }
    }

    // MARK: - Amazon Bedrock

    private var bedrockSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Amazon Bedrock")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("The agent runs on Claude through your AWS account. Credentials come from the AWS CLI — a named profile, SSO, or environment — and are never stored here.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                labeledField("Profile", text: $profile, placeholder: "default")
                labeledField("Region", text: $region, placeholder: BedrockSettings.defaultRegion)
                Button("Connect", action: save)
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.large)
                    .disabled(!BedrockSettings.isValidRegion(trimmedRegion))
            }
            connectionRow
        }
    }

    private func labeledField(_ label: LocalizedStringKey, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .onSubmit(save)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.black.opacity(AppTheme.Opacity.muted))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                )
        }
    }

    private var connectionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(connection == .ready ? AppTheme.Status.successColor : AppTheme.Text.mutedColor)
                .frame(width: AppTheme.Spacing.smMd, height: AppTheme.Spacing.smMd)
            Text(connectionText)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(connection == .ready ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var connectionText: String {
        switch connection {
        case .checking: String(localized: "Checking AWS credentials…")
        case .ready: String(localized: "AWS credentials found. Model access is confirmed by the first message.")
        case .unavailable(let reason): reason
        }
    }

    private var trimmedRegion: String {
        let value = region.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? BedrockSettings.defaultRegion : value
    }

    private func load() {
        let settings = BedrockSettings.load()
        profile = settings.profile
        region = settings.region == BedrockSettings.defaultRegion ? "" : settings.region
        verify(settings)
    }

    private func save() {
        guard BedrockSettings.isValidRegion(trimmedRegion) else { return }
        let settings = BedrockSettings(profile: profile.trimmingCharacters(in: .whitespaces), region: trimmedRegion)
        connection = .checking
        check?.cancel()
        check = Task { @MainActor in
            // Drop held credentials first, so a fixed profile or a fresh `aws sso login` is seen.
            await AWSCredentialProvider.shared.invalidate(profile: settings.profile)
            settings.save()
            let result = await AgentService.connection(for: settings)
            guard !Task.isCancelled else { return }
            connection = result
        }
    }

    private func verify(_ settings: BedrockSettings) {
        connection = .checking
        check?.cancel()
        check = Task { @MainActor in
            let result = await AgentService.connection(for: settings)
            guard !Task.isCancelled else { return }
            connection = result
        }
    }

    // MARK: - MCP server

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            mcpHeader
            mcpStatusRow
        }
    }

    private var mcpHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("MCP Server")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Lets external clients like Cursor, Claude Desktop, Claude Code, and Codex edit your timeline.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: openInstructions) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text("Setup instructions")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.link)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .pointerStyle(.link)
            }
        }
    }

    private var mcpStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill((appState.mcpService?.isRunning ?? false) ? AppTheme.Status.successColor : AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.Spacing.smMd, height: AppTheme.Spacing.smMd)

                if appState.mcpService?.isRunning ?? false {
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xxs) {
                        Text("Running on")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Text("127.0.0.1:\(String(MCPService.port))")
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                } else {
                    Text("Stopped")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { (appState.mcpService?.isRunning ?? false) },
                    set: { appState.setMCPEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel("MCP Server")
        }
        .padding(.top, AppTheme.Spacing.xs)
    }

    private func openInstructions() {
        HelpWindowController.shared.show(tab: .mcp)
    }
}
