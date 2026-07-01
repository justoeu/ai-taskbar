import SwiftUI
import AppKit
import AiTaskbarCore

public struct AboutView: View {
    public let onDone: () -> Void
    @EnvironmentObject var updates: UpdateChecker

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        if let short, let build, short != build {
            return "v\(short) (\(build))"
        }
        if let short { return "v\(short)" }
        return "v0.7.2-dev"
    }

    public var body: some View {
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
            }

            Spacer(minLength: 4)

            HStack(spacing: 12) {
                Button(L10n.localizedString("done")) { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 4)
        }
        .padding(18)
        .frame(width: 400, height: 540)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(radius: 20)
        )
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
