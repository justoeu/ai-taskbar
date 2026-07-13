import SwiftUI
import AppKit
import AiTaskbarCore

public struct VendorSectionView: View {
    @ObservedObject var vm: VendorViewModel
    @EnvironmentObject private var store: UsageStore
    public let thresholds: ThresholdsConfig
    /// Plain reference — NOT `@ObservedObject`. The cost footer (the only
    /// consumer of cost data inside this section) is now isolated in
    /// `CostFooterView`, which holds its own observation. This keeps the
    /// per-vendor section body from re-rendering every ≥60 s when the
    /// shared `CostEstimator` flips `isLoading` / `byVendor`.
    public let cost: CostEstimator

    /// Tracks an in-progress CLI re-login triggered by `reloginAffordance`.
    /// Flips true on click, back to false once the vendor recovers
    /// (`needsReauth` clears) or after a timeout — whichever comes first.
    @State private var reloginPending = false
    /// Set when the login process couldn't even be spawned (very rare —
    /// `/bin/zsh` missing); surfaces a copy-the-command fallback.
    @State private var reloginSpawnFailed = false

    /// In-flight flag for the one-time Keychain authorization (the native
    /// password dialog blocks until dismissed).
    @State private var keychainAuthPending = false
    /// Non-nil after a failed authorization attempt — rendered under the
    /// banner so the user sees why (canceling sets nothing).
    @State private var keychainAuthError: String?

    public init(vm: VendorViewModel,
                thresholds: ThresholdsConfig,
                cost: CostEstimator) {
        self.vm = vm
        self.thresholds = thresholds
        self.cost = cost
    }

    /// True when this vendor is "disabled" (no credentials).
    private var isDisabled: Bool {
        if case .failed(let err, _) = vm.state, err.isDisabled { return true }
        return false
    }

    private var effectiveExpanded: Bool {
        // Vendors without credentials stay folded regardless of preference.
        isDisabled ? false : vm.isExpanded
    }

    public var body: some View {
        let state = vm.state
        VStack(alignment: .leading, spacing: 8) {
            header(state: state)
            if effectiveExpanded {
                content(state: state)
                if !vm.history.isEmpty {
                    SparklineView(samples: vm.history, thresholds: thresholds)
                }
                CostFooterView(vendorId: vm.vendorId, cost: cost)
            } else if isDisabled {
                disabledHint
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .animation(.easeInOut(duration: 0.15), value: effectiveExpanded)
    }

    @ViewBuilder
    private var disabledHint: some View {
        Label(L10n.localizedString("no_credentials_short"),
              systemImage: "key.slash")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func header(state: VendorViewModel.State) -> some View {
        // Leading block (chevron + title + flexible space) is the expand/
        // collapse hit target for the whole "header" area. Trailing controls
        // stay outside that Button so dashboard / reorder / refresh keep
        // working independently.
        HStack(spacing: 6) {
            if isDisabled {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                    headerTitle(state: state)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(L10n.localizedString("locked_help"))
            } else {
                Button {
                    // Source of truth lives on the VM; the didSet there
                    // persists to UserDefaults and the menu-bar aggregate
                    // recomputes so a collapsed card drops out of the %.
                    vm.isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: effectiveExpanded ? "chevron.down" : "chevron.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 28, alignment: .center)
                        headerTitle(state: state)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.localizedString(
                    effectiveExpanded ? "collapse_fmt" : "expand_fmt",
                    vm.vendorId.displayName))
            }
            if let url = vm.vendorId.dashboardURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L10n.localizedString("open_dashboard_fmt", url.host ?? "dashboard"))
            }
            statusIndicator(state: state)
            reorderControls
            if !isDisabled {
                Button {
                    vm.refresh(forceRefresh: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L10n.localizedString("refresh_vendor_fmt", vm.vendorId.displayName))
            }
        }
    }

    @ViewBuilder
    private func headerTitle(state: VendorViewModel.State) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(vm.vendorId.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
            if let plan = state.outcome?.snapshot.planLabel {
                Text(plan)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// ↑/↓ reorder — MenuBarExtra windows do not deliver drag-and-drop
    /// reliably, so explicit buttons are the supported path.
    @ViewBuilder
    private var reorderControls: some View {
        let idx = store.displayIndex(of: vm.vendorId)
        let count = store.displayCount
        let canUp = (idx ?? 0) > 0
        let canDown = idx.map { $0 < count - 1 } ?? false
        HStack(spacing: 0) {
            Button {
                store.moveVendorUp(vm.vendorId)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .frame(width: 18, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(!canUp)
            .help(L10n.localizedString("move_vendor_up_help"))
            Button {
                store.moveVendorDown(vm.vendorId)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .frame(width: 18, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(!canDown)
            .help(L10n.localizedString("move_vendor_down_help"))
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func statusIndicator(state: VendorViewModel.State) -> some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small)
        case .ok(let outcome) where outcome.isStale:
            // Tooltip now surfaces WHY the data is stale (last error message)
            // when available — credential ACL mismatch, schema drift, etc.
            // Falls back to the generic "stale" hint if no error captured.
            let detail = outcome.lastError?.body ?? L10n.localizedString("stale_help")
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(detail)
        case .failed(let err, _) where err.isDisabled:
            Image(systemName: "key.slash")
                .foregroundStyle(.secondary)
                .help(L10n.localizedString("no_credentials_help"))
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .help(L10n.localizedString("last_fetch_failed_help"))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func content(state: VendorViewModel.State) -> some View {
        switch state {
        case .idle:
            L10n.text("waiting_first_refresh")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .loading where state.outcome == nil:
            L10n.text("loading")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .loading, .ok:
            VStack(alignment: .leading, spacing: 8) {
                if state.isKeychainACLBlocked {
                    keychainAuthorizeAffordance
                }
                if vm.needsReauth {
                    reloginAffordance
                }
                if let snap = state.outcome?.snapshot {
                    if snap.windows.isEmpty {
                        L10n.text("no_usage_windows")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    } else {
                        renderSnapshot(snap)
                    }
                }
            }

        case .failed(let err, let fallback):
            VStack(alignment: .leading, spacing: 6) {
                if vm.needsReauth {
                    reloginAffordance
                }
                if err.isDisabled {
                    Label(L10n.localizedString("no_credentials_for_vendor_fmt",
                                               vm.vendorId.displayName),
                          systemImage: "key.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    L10n.text("no_credentials_hint")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if err.isKeychainACLBlocked {
                    keychainAuthorizeAffordance
                } else {
                    Text(err.localizedDescription)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let snap = fallback?.snapshot, !snap.windows.isEmpty {
                    Divider()
                    L10n.text("showing_cached_data")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    renderSnapshot(snap)
                }
            }
        }
    }

    /// Actionable Keychain banner shown after a prompt-suppressed scheduled
    /// read is blocked. The button performs one explicit interactive read and
    /// seeds the reader's in-memory credential cache. It deliberately does
    /// not rewrite Claude Code's ACL. Runs off the main actor because the
    /// native SecurityAgent dialog blocks until the user responds.
    @ViewBuilder
    private var keychainAuthorizeAffordance: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                L10n.text("keychain_auth_title")
                    .font(.subheadline.weight(.semibold))
                if let message = keychainAuthError {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else {
                    L10n.text(keychainAuthPending ? "keychain_auth_pending"
                                                  : "keychain_auth_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button {
                runKeychainAuthorization()
            } label: {
                Label(L10n.localizedString("keychain_auth_button"),
                      systemImage: "key.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(keychainAuthPending)
        }
    }

    private func runKeychainAuthorization() {
        keychainAuthPending = true
        keychainAuthError = nil
        let vm = self.vm
        let provider = vm.provider
        Task.detached(priority: .userInitiated) {
            let result: Result<Void, Error> = Result {
                try provider.authorizeCredentialsInteractively()
            }
            await MainActor.run {
                keychainAuthPending = false
                switch result {
                case .success:
                    vm.refresh(forceRefresh: true)
                case .failure(let error):
                    keychainAuthError = (error as? AppError)?.localizedDescription
                        ?? String(describing: error)
                }
            }
        }
    }

    /// Actionable "token expired — re-login" banner. Shown only when the
    /// vendor's last fetch was a 401 AND the vendor has a CLI login command
    /// (Claude Code or OpenAI/Codex). The button runs that command in the
    /// background — delegating re-auth to the CLI that owns the token, so the
    /// monitor never rotates the shared refresh_token itself.
    @ViewBuilder
    private var reloginAffordance: some View {
        if let command = vm.vendorId.reloginCommand {
            HStack(spacing: 8) {
                Image(systemName: reloginPending
                      ? "person.badge.key.fill"
                      : "person.badge.key.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    L10n.text("token_expired_title")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if reloginSpawnFailed {
                        Text(command)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if reloginPending {
                        L10n.text("relogin_started")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        L10n.text("token_expired_relogin_hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if reloginSpawnFailed {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Label(L10n.localizedString("copy"),
                              systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        runRelogin(command: command)
                    } label: {
                        Label(reloginPending
                              ? L10n.localizedString("relogin_started")
                              : L10n.localizedString("relogin"),
                              systemImage: reloginPending
                                ? "checkmark.circle"
                                : "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(reloginPending)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
        }
    }

    /// Spawns the vendor's login command in the background via a login shell.
    /// GUI apps inherit a minimal PATH that excludes `/opt/homebrew/bin`, so
    /// we run through `/bin/zsh -l -c` to source the user's profile first;
    /// this finds `claude` or `codex`. The CLI itself opens the browser for the OAuth
    /// flow and writes the renewed token — no Terminal window and no macOS
    /// Automation permission needed (the AppleScript/Terminal approach was
    /// fragile under ad-hoc signing: TCC dropped the grant on every rebuild).
    /// `scheduleReauthRetry()` re-checks the token afterwards.
    private func runRelogin(command: String) {
        reloginSpawnFailed = false
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-l", "-c", command]
        do {
            try task.run()
        } catch {
            reloginSpawnFailed = true
            return
        }
        reloginPending = true
        vm.scheduleReauthRetry()
        // Re-arm the button after a grace window so the user can retry if the
        // browser flow never completed. Cleared earlier by the view when the
        // vendor recovers (needsReauth flips false → affordance vanishes).
        let pendingReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            if !Task.isCancelled { reloginPending = false }
        }
        // If the view goes away, cancel the reset (harmless either way).
        _ = pendingReset
    }

    @ViewBuilder
    private func renderSnapshot(_ snap: VendorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snap.windows, id: \.label) { w in
                ProviderRowView(window: w, thresholds: thresholds)
            }
            extras(for: snap)
        }
    }

    @ViewBuilder
    private func extras(for snap: VendorSnapshot) -> some View {
        switch snap {
        case .anthropic:
            // Usage credits + model-scoped windows (e.g. Fable) now render as
            // regular rows via `VendorSnapshot.windows`; no extra label needed.
            EmptyView()
        case .openai(let s):
            if let credits = s.creditsUSD {
                Label(L10n.localizedString("credits_fmt", credits),
                      systemImage: "dollarsign.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let range = s.messageCountRange {
                Label(range, systemImage: "message")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .openrouter(let s):
            if let models = s.topModels, !models.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        L10n.text("models_label")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                    }
                    ForEach(models.prefix(5), id: \.model) { m in
                        HStack(spacing: 6) {
                            Text("•")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            Text(m.model)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text("\(Int(m.percent.rounded()))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.leading, 4)
                    }
                }
                .padding(.leading, 2)
            }
        case .zai(let s):
            if let models = s.topModels, !models.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        L10n.text("models_label")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                    }
                    ForEach(models.prefix(5), id: \.model) { m in
                        HStack(spacing: 6) {
                            Text("•")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            Text(m.model)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text("\(Int(m.percent.rounded()))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.leading, 4)
                    }
                }
                .padding(.leading, 2)
            }
        case .gemini(let s):
            if let count = s.modelCount {
                Label("\(count) models available",
                      systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .kimi(let s):
            VStack(alignment: .leading, spacing: 2) {
                if let avail = s.availableUSD {
                    Label(L10n.localizedString("balance_fmt", avail),
                          systemImage: "dollarsign.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let voucher = s.voucherUSD, voucher > 0 {
                    Label(L10n.localizedString("voucher_fmt", voucher),
                          systemImage: "ticket")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let cash = s.cashUSD, cash > 0 {
                    Label(L10n.localizedString("cash_fmt", cash),
                          systemImage: "creditcard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .deepseek(let s):
            VStack(alignment: .leading, spacing: 2) {
                if let total = s.totalBalance {
                    Label(L10n.localizedString("balance_fmt", total),
                          systemImage: "dollarsign.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let granted = s.grantedBalance, granted > 0 {
                    Label(L10n.localizedString("voucher_fmt", granted),
                          systemImage: "ticket")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let toppedUp = s.toppedUpBalance, toppedUp > 0 {
                    Label(L10n.localizedString("cash_fmt", toppedUp),
                          systemImage: "creditcard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .xai(let s):
            VStack(alignment: .leading, spacing: 2) {
                if let prepaid = s.prepaidUSD {
                    Label(L10n.localizedString("balance_fmt", prepaid),
                          systemImage: "dollarsign.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let spent = s.spentUSD {
                    Label(L10n.localizedString("cash_fmt", spent),
                          systemImage: "creditcard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
