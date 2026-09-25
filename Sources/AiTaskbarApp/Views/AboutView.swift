import SwiftUI
import AppKit
import AiTaskbarCore

public struct AboutView: View {
    public let onDone: () -> Void
    public let onQuit: () -> Void
    @EnvironmentObject var updates: UpdateChecker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showQuitConfirmation = false

    public init(
        onDone: @escaping () -> Void,
        onQuit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.onDone = onDone
        self.onQuit = onQuit
    }

    /// Read once from the binary's own code signature (Developer ID leaf
    /// cert). Ad-hoc/dev builds have no cert chain → nil → line is omitted.
    private static let developerName: String? = CodeSignatureInfo.currentDeveloperName()

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        if let short, let build, short != build {
            return "v\(short) (\(build))"
        }
        if let short { return "v\(short)" }
        return "v0.21.0-dev"
    }

    public var body: some View {
        ZStack {
            mainContent
                .disabled(showQuitConfirmation)
                .allowsHitTesting(!showQuitConfirmation)
                .accessibilityHidden(showQuitConfirmation)

            if showQuitConfirmation {
                quitConfirmationOverlay
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: 400, height: 540)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(radius: 20)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: showQuitConfirmation)
        .onExitCommand {
            if showQuitConfirmation {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    showQuitConfirmation = false
                }
            } else {
                onDone()
            }
        }
        .onDisappear {
            showQuitConfirmation = false
        }
    }

    private var mainContent: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

            VStack(spacing: 2) {
                L10n.text("app_name")
                    .font(.title2.weight(.semibold))
                Text(versionString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            updateSection
                .padding(.horizontal, 24)

            Divider().padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 6) {
                L10n.text("about_description")
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Label(L10n.localizedString("about_refresh_hint"), systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(L10n.localizedString("about_macroscopic"), systemImage: "gauge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(L10n.localizedString("about_credentials"), systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(L10n.localizedString("about_security"), systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(L10n.localizedString("about_cost_source"), systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(L10n.localizedString("about_cost_source_help"))
            }
            .padding(.horizontal, 24)

            Divider().padding(.horizontal, 40)

            VStack(spacing: 4) {
                L10n.text("about_built_with")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let developer = Self.developerName {
                    Label(L10n.localizedString("about_developer_fmt", developer),
                          systemImage: "checkmark.seal")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        showQuitConfirmation = true
                    }
                } label: {
                    Label(L10n.localizedString("quit_app"), systemImage: "power")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.regular)

                Spacer()

                Button {
                    onDone()
                } label: {
                    Label(L10n.localizedString("back"), systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 4)
        }
        .padding(18)
    }

    private var quitConfirmationOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        showQuitConfirmation = false
                    }
                }

            VStack(spacing: 16) {
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 38))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)

                VStack(spacing: 6) {
                    Text(L10n.localizedString("quit_confirm_title"))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(L10n.localizedString("quit_confirm_message"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                            showQuitConfirmation = false
                        }
                    } label: {
                        Text(L10n.localizedString("cancel"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)

                    Button(role: .destructive) {
                        onQuit()
                    } label: {
                        Text(L10n.localizedString("quit_confirm_button"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.regular)
                }
            }
            .padding(20)
            .frame(width: 310)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        VStack(spacing: 6) {
            switch updates.status {
            case .idle:
                Button {
                    updates.check()
                } label: {
                    Label(L10n.localizedString("updates_check"),
                          systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    L10n.text("updates_checking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .upToDate(let v):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L10n.localizedString("updates_up_to_date_fmt", v))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        updates.check()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(L10n.localizedString("updates_recheck"))
                }

            case .updateAvailable(let release):
                VStack(spacing: 4) {
                    Label(L10n.localizedString("updates_available_fmt", release.tag),
                          systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                    HStack(spacing: 6) {
                        Button {
                            updates.download(release)
                        } label: {
                            Label(L10n.localizedString("updates_download"),
                                  systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(release.dmgURL == nil)
                        Button(L10n.localizedString("updates_view_release")) {
                            updates.openReleasePage(release)
                        }
                        .controlSize(.small)
                    }
                }

            case .downloading(let progress, let release):
                VStack(spacing: 4) {
                    Text(L10n.localizedString("updates_downloading_fmt", release.tag))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                        .frame(maxWidth: 240)
                        .controlSize(.small)
                }

            case .downloaded(_, let release):
                VStack(spacing: 4) {
                    Label(L10n.localizedString("updates_downloaded_fmt", release.tag),
                          systemImage: "tray.and.arrow.down.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                    L10n.text("updates_drag_to_applications")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

            case .failed(let message):
                VStack(spacing: 4) {
                    Label(L10n.localizedString("updates_failed"),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Button(L10n.localizedString("updates_retry")) {
                        updates.check()
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
