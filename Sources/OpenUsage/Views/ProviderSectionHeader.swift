import SwiftUI

/// Shared provider section header used by the dashboard and its lifted provider-reorder preview.
/// The provider mark and name lead, followed by the optional plan badge. Dashboard callers supply a
/// screenshot-copy action, revealed at the trailing edge while the header is hovered. Callers can also
/// supply an optional `warning` — the latest refresh error, rendered as a small amber
/// triangle beside the name whose hover tooltip carries the message (e.g. "Not logged in. Run `codex`
/// to authenticate."). The
/// optional `staleness` is the dashboard-only hint that the values shown are an aged snapshot still
/// revalidating: a short "Outdated" tag whose hover tooltip carries the precise age ("Last updated 3h
/// 12m ago"), so fossilized plan/limits never pass for current data.
struct ProviderSectionHeader: View {
    let provider: Provider
    var plan: String?
    var nameOverride: String?
    var accountEmail: String?
    var onRenameAccount: ((String) -> Void)?
    var warning: String?
    /// Whether this provider's refresh is currently in flight — drives the small spinner beside the name
    /// so the section shows live feedback while values are being fetched (instead of silently sitting on
    /// the previous, possibly stale, numbers).
    var refreshing: Bool = false
    /// A muted "Outdated" hint shown only when the displayed snapshot has aged past its freshness window
    /// (dashboard only; `nil` in the reorder preview, which never surfaces staleness). Its tooltip carries
    /// the precise age.
    var staleness: StalenessHint?
    /// Dashboard-only screenshot action. The reorder preview omits it, while Customize uses its own
    /// row type and is unaffected by this header.
    var onCopyScreenshot: (() -> Bool)?

    /// Header type and icon track the density setting like the rows do, so Compact shrinks the
    /// whole section anatomy — not just the rows under it.
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    /// Party easter egg: pulse the provider mark. Off by default everywhere else.
    @Environment(\.popoverPartyMode) private var partyMode
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var isRenameFocused: Bool

    init(
        provider: Provider,
        plan: String? = nil,
        nameOverride: String? = nil,
        accountEmail: String? = nil,
        onRenameAccount: ((String) -> Void)? = nil,
        warning: String? = nil,
        refreshing: Bool = false,
        staleness: StalenessHint? = nil,
        onCopyScreenshot: (() -> Bool)? = nil
    ) {
        self.provider = provider
        self.plan = plan
        self.nameOverride = nameOverride
        self.accountEmail = accountEmail
        self.onRenameAccount = onRenameAccount
        self.warning = warning
        self.refreshing = refreshing
        self.staleness = staleness
        self.onCopyScreenshot = onCopyScreenshot
    }

    var body: some View {
        HStack(spacing: 5) {
            // The provider mark replaces the dashboard's visual drag grip. Reordering still belongs
            // to the whole header at the caller, so the logo itself stays presentational.
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: density.headerIconSize, height: density.headerIconSize)
                .partyPulse(partyMode)
            VStack(alignment: .leading, spacing: 1) {
                // Baseline-aligned pair: the plan badge (and stale tag) are smaller type and sit on the
                // name's text baseline, so the words line up along the bottom rather than floating centered.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // Name + plan keep their width and stay on one line; under width pressure (a long plan
                    // name like "Super Grok Heavy") the lower-priority stale tag truncates first instead of
                    // wrapping the name to a second line.
                    HStack(spacing: 2) {
                        Text(nameOverride ?? provider.displayName)
                            .font(.system(size: density.headerPointSize, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if onRenameAccount != nil {
                            Button {
                                renameDraft = nameOverride ?? ""
                                isRenaming = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Rename Account")
                            .accessibilityLabel("Rename \(nameOverride ?? provider.displayName)")
                            .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Rename account")
                                        .font(.headline)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Account name")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        TextField(provider.displayName, text: $renameDraft)
                                            .textFieldStyle(.roundedBorder)
                                            .focused($isRenameFocused)
                                            .onSubmit(saveRename)
                                    }
                                    HStack {
                                        Spacer()
                                        Button("Cancel") {
                                            isRenaming = false
                                        }
                                        .keyboardShortcut(.cancelAction)
                                        Button("Save") {
                                            saveRename()
                                        }
                                        .keyboardShortcut(.defaultAction)
                                    }
                                }
                                .padding(12)
                                .frame(width: 240)
                                .onAppear {
                                    isRenameFocused = true
                                }
                            }
                        }
                    }
                    .layoutPriority(1)
                    if let plan {
                        ProviderPlanBadge(plan: plan)
                            .layoutPriority(1)
                    }
                    // Tertiary, below the plan in hierarchy: outdated content, not something the user acts on.
                    // Short by design ("Outdated") so it never pushes the plan name onto a second line — the
                    // precise age rides in the hover tooltip. Hidden while a refresh is in flight: the spinner
                    // already says "working on it".
                    if let staleness, !refreshing {
                        Text(staleness.label)
                            .font(.system(size: density.planBadgePointSize))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .hoverTooltip(staleness.tooltip)
                    }
                }
                if let accountEmail, !accountEmail.isEmpty {
                    Text(accountEmail)
                        .font(.system(size: density.planBadgePointSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if refreshing {
                MotionAwareProgressView(controlSize: .mini)
                    .accessibilityLabel("Refreshing")
            } else if let warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notice)
                    .hoverTooltip(warning)
                    .accessibilityLabel(warning)
            }
            Spacer(minLength: 8)
            if let onCopyScreenshot {
                CopyFeedbackButton(
                    accessibilityLabel: "Copy \(provider.displayName) Screenshot",
                    isRevealed: isHovered,
                    action: onCopyScreenshot
                )
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func saveRename() {
        onRenameAccount?(renameDraft)
        isRenaming = false
    }
}

struct ProviderPlanBadge: View {
    let plan: String

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        // Plain text — no pill/capsule — for a cleaner header. Secondary (not tertiary): the plan
        // name is information the user reads, and tertiary on glass is reserved for inactive
        // content. The smaller point size alone keeps it subordinate to metric values.
        Text(plan)
            .font(.system(size: density.planBadgePointSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct ReorderGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
    }
}
