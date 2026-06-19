import SwiftUI
import AppKit
import AiTaskbarCore

/// Settings panel — overlays the popover (same pattern as `AboutView`).
/// Binds directly to `SettingsViewModel.draft` so SwiftUI handles the diff
/// tracking. The Save button calls `viewModel.save()` which routes through
/// `ConfigLoader.applyChanges` (comment-preserving) and then surfaces the
/// "relaunch to apply" banner via `viewModel.didSaveSuccessfully`.
///
/// **Layout:** matches the popover's 420×540 frame exactly. The header +
/// footer are pinned outside the scroll view so Save/Cancel are always
/// visible. Vendor sections are flat SwiftUI `Section`s (NOT nested
/// DisclosureGroups, which macOS 13's Form+Section rendering breaks).
public struct SettingsView: View {
    public let onDone: () -> Void
    @EnvironmentObject private var viewModel: SettingsViewModel

    @State private var showOAuthConfirmVendor: String?
    @State private var showResetConfirm = false
    @State private var pinHostsText: String = ""
    @State private var expandedVendor: String? = nil

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                generalSection
                thresholdsSection
                notificationsSection
                updatesSection
                securitySection
                // Vendors as flat Sections — DisclosureGroup nesting inside
                // a Form+Section on macOS 13 silently breaks expand/collapse.
                // The header line on each Section acts as the affordance.
                Section(content: { vendorAnthropic },
                        header: { vendorHeader("Anthropic", icon: "person.crop.circle") },
                        footer: { Text(L10n.localizedString("settings_vendor_footer")).font(.caption2).foregroundStyle(.secondary) })
                Section(content: { vendorOpenAI },
                        header: { vendorHeader("OpenAI / Codex", icon: "person.crop.circle") })
                Section(content: { vendorZAI },
                        header: { vendorHeader("Z.AI", icon: "person.crop.circle") })
                Section(content: { vendorOpenRouter },
                        header: { vendorHeader("OpenRouter", icon: "person.crop.circle") })
                Section(content: { vendorKimi },
                        header: { vendorHeader("Kimi (Moonshot)", icon: "person.crop.circle") })
                Section(content: { vendorGemini },
                        header: { vendorHeader("Gemini", icon: "person.crop.circle") })
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            footer
        }
        .frame(width: 420, height: 540)
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
                showOAuthConfirmVendor = nil
            }
            Button(L10n.localizedString("cancel"), role: .cancel) {
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
            .controlSize(.small)
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
        Section {
            Picker(L10n.localizedString("settings_menu_bar_mode"),
                   selection: menuBarModeSelection) {
                ForEach(MenuBarMode.allCases, id: \.self) { m in
                    Text(menuBarModeLabel(m)).tag(m)
                }
            }
            .pickerStyle(.menu)
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
            .pickerStyle(.menu)
        } header: {
            Text(L10n.localizedString("settings_general"))
        }
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
        Section {
            HStack {
                Text(L10n.localizedString("settings_warning"))
                Spacer()
                Slider(value: Binding(
                    get: { viewModel.draft.thresholds.warning },
                    set: { viewModel.draft.thresholds.warning = $0 }),
                       in: 0...100) { EmptyView() }
                    .frame(maxWidth: 140)
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
                    .frame(maxWidth: 140)
                Text("\(Int(viewModel.draft.thresholds.critical))%")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
        } header: {
            Text(L10n.localizedString("settings_thresholds"))
        } footer: {
            Text(L10n.localizedString("settings_thresholds_help"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            Toggle(L10n.localizedString("settings_notifications_enabled"),
                   isOn: Binding(
                    get: { viewModel.draft.notifications.enabled },
                    set: { viewModel.draft.notifications.enabled = $0 }))
            Toggle(L10n.localizedString("settings_discreet"),
                   isOn: Binding(
                    get: { viewModel.draft.notifications.discreet },
                    set: { viewModel.draft.notifications.discreet = $0 }))
        } header: {
            Text(L10n.localizedString("settings_notifications"))
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private var updatesSection: some View {
        Section {
            Toggle(L10n.localizedString("settings_updates_enabled"),
                   isOn: Binding(
                    get: { viewModel.draft.updates.enabled },
                    set: { viewModel.draft.updates.enabled = $0 }))
            Toggle(L10n.localizedString("settings_updates_prereleases"),
                   isOn: Binding(
                    get: { viewModel.draft.updates.includePrereleases },
                    set: { viewModel.draft.updates.includePrereleases = $0 }))
        } header: {
            Text(L10n.localizedString("settings_updates"))
        }
    }

    // MARK: - Security

    @ViewBuilder
    private var securitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.localizedString("settings_pin_hosts"))
                    .font(.subheadline)
                TextEditor(text: $pinHostsText)
                    .font(.subheadline.monospaced())
                    .frame(minHeight: 36, maxHeight: 72)
                    .onChange(of: pinHostsText) { new in
                        viewModel.draft.security.pinHosts = parseHostList(new)
                    }
            }
            Toggle(L10n.localizedString("settings_pin_audit_only"),
                   isOn: Binding(
                    get: { viewModel.draft.security.pinAuditOnly },
                    set: { viewModel.draft.security.pinAuditOnly = $0 }))
        } header: {
            HStack(spacing: 4) {
                Text(L10n.localizedString("settings_security"))
                Image(systemName: "shield.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(L10n.localizedString("settings_security_help"))
                .font(.caption2)
                .foregroundStyle(.secondary)
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

    // MARK: - Vendor headers (Section header pattern)

    /// Per-vendor Section header. Clicking toggles the expansion state we
    /// track locally — the body content reads the same flag to show/hide.
    private func vendorHeader(_ name: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expandedVendor == name ? 90 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedVendor = (expandedVendor == name) ? nil : name
            }
        }
    }

    @ViewBuilder
    private func vendorBody<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if expandedVendor != nil {
            content()
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Vendor: Anthropic

    @ViewBuilder
    private var vendorAnthropic: some View {
        vendorBody {
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
        }
    }

    // MARK: - Vendor: OpenAI / Codex

    @ViewBuilder
    private var vendorOpenAI: some View {
        vendorBody {
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
        }
    }

    // MARK: - Vendor: ZAI

    @ViewBuilder
    private var vendorZAI: some View {
        vendorBody {
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
            .pickerStyle(.menu)
        }
    }

    // MARK: - Vendor: OpenRouter

    @ViewBuilder
    private var vendorOpenRouter: some View {
        vendorBody {
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
    private var vendorKimi: some View {
        vendorBody {
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
            .pickerStyle(.menu)
        }
    }

    // MARK: - Vendor: Gemini

    @ViewBuilder
    private var vendorGemini: some View {
        vendorBody {
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
            .pickerStyle(.menu)
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
            Group {
                if visible {
                    TextField(label, text: $value)
                } else {
                    SecureField(label, text: $value)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
            .font(.subheadline.monospaced())
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
