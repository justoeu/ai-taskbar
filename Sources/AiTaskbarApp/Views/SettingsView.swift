import SwiftUI
import AppKit
import AiTaskbarCore

/// Settings panel — overlays the popover (same pattern as `AboutView`).
/// Binds directly to `SettingsViewModel.draft` so SwiftUI handles the diff
/// tracking. The Save button calls `viewModel.save()` which routes through
/// `ConfigLoader.applyChanges` (comment-preserving) and then surfaces the
/// "relaunch to apply" banner via `viewModel.didSaveSuccessfully`.
public struct SettingsView: View {
    public let onDone: () -> Void
    @EnvironmentObject private var viewModel: SettingsViewModel

    @State private var showOAuthConfirmVendor: String?
    @State private var showResetConfirm = false
    @State private var pinHostsText: String = ""

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Form {
                    generalSection
                    thresholdsSection
                    notificationsSection
                    updatesSection
                    securitySection
                    Section(L10n.localizedString("settings_vendors")) {
                        anthropicSection
                        openaiSection
                        zaiSection
                        openRouterSection
                        kimiSection
                        geminiSection
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
            }
            Divider()
            footer
        }
        .frame(width: 440, height: 580)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(radius: 20)
        )
        .onAppear { syncPinHostsText() }
        .alert(L10n.localizedString("settings_save_failed"),
               isPresented: .init(get: { viewModel.saveError != nil },
                                  set: { if !$0 { viewModel.saveError = nil } })) {
            Button(L10n.localizedString("done")) { viewModel.saveError = nil }
        } message: {
            Text(viewModel.saveError ?? "")
        }
        .confirmationDialog(
            L10n.localizedString("settings_oauth_confirm_title"),
            isPresented: .init(get: { showOAuthConfirmVendor != nil },
                               set: { if !$0 { showOAuthConfirmVendor = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.localizedString("settings_oauth_confirm_understand"),
                   role: .destructive) {
                // User explicitly accepted — leave the toggle on.
                showOAuthConfirmVendor = nil
            }
            Button(L10n.localizedString("cancel"), role: .cancel) {
                // Revert whichever vendor's flag they tried to flip.
                if let v = showOAuthConfirmVendor {
                    if v == "anthropic" { viewModel.draft.anthropic.manageOAuthRefresh = false }
                    if v == "openai"    { viewModel.draft.openai.manageOAuthRefresh = false }
                }
                showOAuthConfirmVendor = nil
            }
        } message: {
            Text(L10n.localizedString("settings_oauth_confirm_body"))
        }
        .confirmationDialog(
            L10n.localizedString("settings_reset_confirm_title"),
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.localizedString("settings_reset"), role: .destructive) {
                try? viewModel.resetToDefaults()
                syncPinHostsText()
            }
            Button(L10n.localizedString("cancel"), role: .cancel) {}
        } message: {
            Text(L10n.localizedString("settings_reset_confirm_body"))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "gearshape.fill")
                .foregroundStyle(.tint)
            L10n.text("settings_title")
                .font(.headline)
            Spacer()
            Button { onDone() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help(L10n.localizedString("cancel"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                L10n.text("settings_reset_to_defaults")
            }
            .buttonStyle(.borderless)
            Spacer()
            Button { onDone() } label: {
                L10n.text("cancel")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                try? viewModel.save()
                syncPinHostsText()
            } label: {
                Label(L10n.localizedString("save"), systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!viewModel.hasUnsavedChanges)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - General

    @ViewBuilder
    private var generalSection: some View {
        Section(L10n.localizedString("settings_general")) {
            Picker(L10n.localizedString("settings_primary_vendor"),
                   selection: primarySelection) {
                Text(L10n.localizedString("settings_system_default")).tag(VendorId?.none)
                ForEach(VendorId.allCases, id: \.self) { v in
                    Text(v.displayName).tag(Optional(v))
                }
            }
            Picker(L10n.localizedString("settings_menu_bar_mode"),
                   selection: menuBarModeSelection) {
                ForEach(MenuBarMode.allCases, id: \.self) { m in
                    Text(menuBarModeLabel(m)).tag(m)
                }
            }
            HStack {
                Text(L10n.localizedString("settings_refresh_interval"))
                Spacer()
                Stepper(value: refreshIntervalBinding,
                        in: 15...3600,
                        step: 15) {
                    Text("\(Int(viewModel.draft.ui.refreshIntervalSeconds))s")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Picker(L10n.localizedString("settings_language"),
                   selection: languageSelection) {
                Text(L10n.localizedString("settings_system_default")).tag(String?.none)
                ForEach(["en", "pt-BR", "es"], id: \.self) { code in
                    Text(languageDisplayName(code)).tag(Optional(code))
                }
            }
        }
    }

    private var primarySelection: Binding<VendorId?> {
        Binding(get: { viewModel.draft.ui.primary },
                set: { viewModel.draft.ui.primary = $0 })
    }
    private var menuBarModeSelection: Binding<MenuBarMode> {
        Binding(get: { viewModel.draft.ui.menuBarMode },
                set: { viewModel.draft.ui.menuBarMode = $0 })
    }
    private var refreshIntervalBinding: Binding<Double> {
        Binding(get: { viewModel.draft.ui.refreshIntervalSeconds },
                set: { viewModel.draft.ui.refreshIntervalSeconds = max(15, $0) })
    }
    private var languageSelection: Binding<String?> {
        Binding(get: { viewModel.draft.ui.language },
                set: { viewModel.draft.ui.language = $0 })
    }

    private func menuBarModeLabel(_ m: MenuBarMode) -> String {
        switch m {
        case .icon:            return L10n.localizedString("settings_mb_icon_only")
        case .iconAndPercent:  return L10n.localizedString("settings_mb_icon_and_percent")
        case .rotating:        return L10n.localizedString("settings_mb_rotating")
        }
    }

    private func languageDisplayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    // MARK: - Thresholds

    @ViewBuilder
    private var thresholdsSection: some View {
        Section(L10n.localizedString("settings_thresholds")) {
            HStack {
                Text(L10n.localizedString("settings_warning"))
                Spacer()
                Slider(value: Binding(
                    get: { viewModel.draft.thresholds.warning },
                    set: { viewModel.draft.thresholds.warning = $0 }),
                       in: 0...100) { EmptyView() }
                    .frame(maxWidth: 160)
                Text("\(Int(viewModel.draft.thresholds.warning))%")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text(L10n.localizedString("settings_critical"))
                Spacer()
                Slider(value: Binding(
                    get: { viewModel.draft.thresholds.critical },
                    set: { viewModel.draft.thresholds.critical = $0 }),
                       in: 0...100) { EmptyView() }
                    .frame(maxWidth: 160)
                Text("\(Int(viewModel.draft.thresholds.critical))%")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        Section(L10n.localizedString("settings_notifications")) {
            Toggle(L10n.localizedString("settings_notifications_enabled"),
                   isOn: Binding(
                    get: { viewModel.draft.notifications.enabled },
                    set: { viewModel.draft.notifications.enabled = $0 }))
            Toggle(L10n.localizedString("settings_discreet"),
                   isOn: Binding(
                    get: { viewModel.draft.notifications.discreet },
                    set: { viewModel.draft.notifications.discreet = $0 }))
            L10n.text("settings_notify_at_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private var updatesSection: some View {
        Section(L10n.localizedString("settings_updates")) {
            Toggle(L10n.localizedString("settings_updates_enabled"),
                   isOn: Binding(
                    get: { viewModel.draft.updates.enabled },
                    set: { viewModel.draft.updates.enabled = $0 }))
            Toggle(L10n.localizedString("settings_updates_prereleases"),
                   isOn: Binding(
                    get: { viewModel.draft.updates.includePrereleases },
                    set: { viewModel.draft.updates.includePrereleases = $0 }))
        }
    }

    // MARK: - Security

    @ViewBuilder
    private var securitySection: some View {
        Section(L10n.localizedString("settings_security")) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.localizedString("settings_pin_hosts"))
                    .font(.subheadline)
                TextEditor(text: $pinHostsText)
                    .font(.subheadline.monospaced())
                    .frame(minHeight: 44, maxHeight: 88)
                    .onChange(of: pinHostsText) { new in
                        viewModel.draft.security.pinHosts = parseHostList(new)
                    }
                L10n.text("settings_pin_hosts_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(L10n.localizedString("settings_pin_audit_only"),
                   isOn: Binding(
                    get: { viewModel.draft.security.pinAuditOnly },
                    set: { viewModel.draft.security.pinAuditOnly = $0 }))
                .help(L10n.localizedString("settings_pin_audit_help"))
        }
    }

    private func syncPinHostsText() {
        pinHostsText = viewModel.draft.security.pinHosts.joined(separator: "\n")
    }

    private func parseHostList(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // MARK: - Vendor: Anthropic

    @ViewBuilder
    private var anthropicSection: some View {
        DisclosureGroup(L10n.localizedString("anthropic")) {
            Toggle(L10n.localizedString("settings_enabled"),
                   isOn: Binding(
                    get: { viewModel.draft.anthropic.enabled },
                    set: { viewModel.draft.anthropic.enabled = $0 }))
            TextField(L10n.localizedString("settings_keychain_account"),
                      text: Binding(
                        get: { viewModel.draft.anthropic.keychainAccount ?? "" },
                        set: { viewModel.draft.anthropic.keychainAccount = $0.isEmpty ? nil : $0 }))
                .font(.subheadline.monospaced())
            Toggle(L10n.localizedString("settings_manage_oauth_anthropic"),
                   isOn: Binding(
                    get: { viewModel.draft.anthropic.manageOAuthRefresh },
                    set: { newVal in
                        viewModel.draft.anthropic.manageOAuthRefresh = newVal
                        if newVal { showOAuthConfirmVendor = "anthropic" }
                    }))
                .help(L10n.localizedString("settings_manage_oauth_help"))
        }
    }

    // MARK: - Vendor: OpenAI / Codex

    @ViewBuilder
    private var openaiSection: some View {
        DisclosureGroup(L10n.localizedString("openai")) {
            Toggle(L10n.localizedString("settings_enabled"),
                   isOn: Binding(
                    get: { viewModel.draft.openai.enabled },
                    set: { viewModel.draft.openai.enabled = $0 }))
            TextField(L10n.localizedString("settings_codex_auth_path"),
                      text: Binding(
                        get: { viewModel.draft.openai.codexAuthPath ?? "" },
                        set: { viewModel.draft.openai.codexAuthPath = $0.isEmpty ? nil : $0 }))
                .font(.subheadline.monospaced())
            Toggle(L10n.localizedString("settings_manage_oauth_openai"),
                   isOn: Binding(
                    get: { viewModel.draft.openai.manageOAuthRefresh },
                    set: { newVal in
                        viewModel.draft.openai.manageOAuthRefresh = newVal
                        if newVal { showOAuthConfirmVendor = "openai" }
                    }))
                .help(L10n.localizedString("settings_manage_oauth_help"))
        }
    }

    // MARK: - Vendor: ZAI

    @ViewBuilder
    private var zaiSection: some View {
        DisclosureGroup(L10n.localizedString("zai")) {
            Toggle(L10n.localizedString("settings_enabled"),
                   isOn: Binding(
                    get: { viewModel.draft.zai.enabled },
                    set: { viewModel.draft.zai.enabled = $0 }))
            TextField(L10n.localizedString("settings_api_key_env"),
                      text: Binding(
                        get: { viewModel.draft.zai.apiKeyEnv },
                        set: { viewModel.draft.zai.apiKeyEnv = $0 }))
                .font(.subheadline.monospaced())
            SecureInlineField(label: L10n.localizedString("settings_api_key"),
                              value: Binding(
                                get: { viewModel.draft.zai.apiKey ?? "" },
                                set: { viewModel.draft.zai.apiKey = $0.isEmpty ? nil : $0 }))
            Picker(L10n.localizedString("settings_plan_tier"),
                   selection: Binding(
                    get: { viewModel.draft.zai.planTier ?? "" },
                    set: { viewModel.draft.zai.planTier = $0.isEmpty ? nil : $0 })) {
                Text(L10n.localizedString("settings_system_default")).tag("")
                ForEach(["lite", "pro", "max"], id: \.self) { Text($0).tag($0) }
            }
        }
    }

    // MARK: - Vendor: OpenRouter

    @ViewBuilder
    private var openRouterSection: some View {
        DisclosureGroup(L10n.localizedString("openrouter")) {
            Toggle(L10n.localizedString("settings_enabled"),
                   isOn: Binding(
                    get: { viewModel.draft.openrouter.enabled },
                    set: { viewModel.draft.openrouter.enabled = $0 }))
            TextField(L10n.localizedString("settings_api_key_env"),
                      text: Binding(
                        get: { viewModel.draft.openrouter.apiKeyEnv },
                        set: { viewModel.draft.openrouter.apiKeyEnv = $0 }))
                .font(.subheadline.monospaced())
            SecureInlineField(label: L10n.localizedString("settings_api_key"),
                              value: Binding(
                                get: { viewModel.draft.openrouter.apiKey ?? "" },
                                set: { viewModel.draft.openrouter.apiKey = $0.isEmpty ? nil : $0 }))
        }
    }

    // MARK: - Vendor: Kimi

    @ViewBuilder
    private var kimiSection: some View {
        DisclosureGroup(L10n.localizedString("kimi")) {
            Toggle(L10n.localizedString("settings_enabled"),
                   isOn: Binding(
                    get: { viewModel.draft.kimi.enabled },
                    set: { viewModel.draft.kimi.enabled = $0 }))
            TextField(L10n.localizedString("settings_api_key_env"),
                      text: Binding(
                        get: { viewModel.draft.kimi.apiKeyEnv },
                        set: { viewModel.draft.kimi.apiKeyEnv = $0 }))
                .font(.subheadline.monospaced())
            SecureInlineField(label: L10n.localizedString("settings_api_key"),
                              value: Binding(
                                get: { viewModel.draft.kimi.apiKey ?? "" },
                                set: { viewModel.draft.kimi.apiKey = $0.isEmpty ? nil : $0 }))
            Picker(L10n.localizedString("settings_base_url"),
                   selection: Binding(
                    get: { viewModel.draft.kimi.baseURL },
                    set: { viewModel.draft.kimi.baseURL = $0 })) {
                Text("api.moonshot.ai").tag("https://api.moonshot.ai/v1")
                Text("api.moonshot.cn").tag("https://api.moonshot.cn/v1")
            }
        }
    }

    // MARK: - Vendor: Gemini

    @ViewBuilder
    private var geminiSection: some View {
        DisclosureGroup(L10n.localizedString("gemini")) {
            Toggle(L10n.localizedString("settings_enabled"),
                   isOn: Binding(
                    get: { viewModel.draft.gemini.enabled },
                    set: { viewModel.draft.gemini.enabled = $0 }))
            TextField(L10n.localizedString("settings_api_key_env"),
                      text: Binding(
                        get: { viewModel.draft.gemini.apiKeyEnv },
                        set: { viewModel.draft.gemini.apiKeyEnv = $0 }))
                .font(.subheadline.monospaced())
            SecureInlineField(label: L10n.localizedString("settings_api_key"),
                              value: Binding(
                                get: { viewModel.draft.gemini.apiKey ?? "" },
                                set: { viewModel.draft.gemini.apiKey = $0.isEmpty ? nil : $0 }))
            Picker(L10n.localizedString("settings_base_url"),
                   selection: Binding(
                    get: { viewModel.draft.gemini.baseURL },
                    set: { viewModel.draft.gemini.baseURL = $0 })) {
                Text("v1beta").tag("https://generativelanguage.googleapis.com/v1beta")
                Text("v1").tag("https://generativelanguage.googleapis.com/v1")
                Text("v1alpha").tag("https://generativelanguage.googleapis.com/v1alpha")
            }
        }
    }
}

/// A SecureField with a show/hide toggle. Sits on one row with the label to
/// keep the Settings UI dense (vendor sections stack 3-4 of these).
struct SecureInlineField: View {
    let label: String
    @Binding var value: String
    @State private var visible = false

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if visible {
                TextField(label, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .font(.subheadline.monospaced())
            } else {
                SecureField(label, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .font(.subheadline.monospaced())
            }
            Button {
                visible.toggle()
            } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(L10n.localizedString(visible ? "settings_hide" : "settings_show"))
        }
    }
}
