import AppKit
import SwiftUI
import UsageCore

// MARK: - Panel

/// The whole menu bar panel: two meters, three collapsible sections, a stats grid, a footer.
///
/// Narrow and single-column while the sections are closed. Expanded, it lays out in two columns
/// and gains a height cap.
///
/// The reason is that one section is far taller than the others: "Last 30 days" carries the daily
/// chart *and* four proportion groups (models, effort, tokens, cost share). Stacked in one 320pt
/// column that overruns the bottom of the screen, and a menu bar panel has nowhere to overflow to —
/// it is simply clipped, so the footer and part of the content become unreachable. Widening alone
/// does not fix it either; the tall section has to get a column of its own, which is why the split
/// below is by content weight rather than by source order.
///
/// The cap and scroll view are the guarantee rather than the mechanism: whatever the section
/// contents grow into — a long session list, a small display — the panel still cannot exceed the
/// screen.
struct PanelView: View {
    @Environment(AppModel.self) private var model

    @AppStorage(Prefs.expandedFiveHour) private var expandedFiveHour = Prefs.Default.expandedFiveHour
    @AppStorage(Prefs.expandedWeekly) private var expandedWeekly = Prefs.Default.expandedWeekly
    @AppStorage(Prefs.expandedSessions) private var expandedSessions = Prefs.Default.expandedSessions
    @AppStorage(Prefs.expandedDaily) private var expandedDaily = Prefs.Default.expandedDaily

    /// Drives every countdown and the "updated Ns ago" line. Ticked into state rather than read
    /// inline so all the relative strings in one pass of the body agree with each other.
    @State private var now = Date()

    init() {}

    /// One column closed, two open. 300 rather than 320 per column so the two-column form stays
    /// under a third of a small laptop screen's width.
    private static let columnWidth: CGFloat = 300
    private static let columnGap: CGFloat = 16
    /// Hoisted out of `body` so the layout and `wideWidth` cannot disagree about them.
    private static let horizontalPadding: CGFloat = 14
    private static let dividerThickness: CGFloat = 1

    /// Widen when the content is about to get tall.
    ///
    /// `expandedDaily` alone is enough: that section carries the daily chart and four proportion
    /// groups, and on its own it overruns a single column. Two of the lighter sections together do
    /// the same. One light section on its own stays narrow, because a 620pt-wide panel showing a
    /// single sparkline looks like a mistake.
    private var isWide: Bool {
        let openLightSections = [expandedFiveHour, expandedWeekly, expandedSessions]
            .filter { $0 }.count
        return expandedDaily || openLightSections >= 2
    }

    /// Width of the single-column form.
    private static let narrowWidth: CGFloat = 320

    /// Width available to content inside the horizontal padding, in the narrow form.
    private static var narrowContentWidth: CGFloat { narrowWidth - horizontalPadding * 2 }

    /// A legacy scroller is laid out *inside* the scroll view and takes width from it; an overlay
    /// scroller floats above the content and takes none. This is the term that made the earlier
    /// attempt at this arithmetic come out low. It is worth 15pt, and it is a live system
    /// setting, so it is read rather than baked in.
    private static var scrollerAllowance: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
    }

    /// The two-column form's width, stated rather than inferred — animating towards a width
    /// means naming it, because `.frame(width:)` cannot interpolate towards `nil`.
    ///
    /// 300 + 16 + 1 + 16 + 300 + 14·2 + 15 = 676, which is what the panel window measures.
    /// Erring generous is the safe direction: a few points spare leave dead space on the right,
    /// where a few points short clip both columns against the window edge.
    private static var wideWidth: CGFloat {
        columnWidth * 2 + columnGap * 2 + dividerThickness
            + horizontalPadding * 2 + scrollerAllowance
    }

    /// Whether growing to the wide form would make AppKit re-anchor the panel.
    ///
    /// The panel's *leading* edge is pinned to the status item while the panel still fits to the
    /// right of it, and AppKit flips to trailing-edge anchoring the moment it does not — moving
    /// the window by its whole width in one frame, with no clamping to the screen. Measured
    /// stepping a panel from 320 to 1400 under a status item at x=668 on a 1792pt screen: x held
    /// at 668 up to a width of 1104, then jumped to −435 at 1134.
    ///
    /// Nothing can smooth that, so when the two widths straddle the threshold the switch is left
    /// instant. One jump reads as a resize; a glide that ends in a jump reads as a fault.
    private static var reanchorsBetweenWidths: Bool {
        guard let statusItem = NSApp.windows.first(where: { $0.level == .statusBar }),
            let screen = statusItem.screen ?? NSScreen.main
        else { return false }
        let room = screen.frame.maxX - statusItem.frame.minX
        return (narrowWidth <= room) != (wideWidth <= room)
    }

    /// Natural height of the content, measured rather than assumed.
    ///
    /// The root `ScrollView` is why this is needed. Asked for its size with no height proposed —
    /// which is what the hosting view does — a scroll view answers with a near-constant instead
    /// of its content's height, and that constant is what sized the panel: the window sat at
    /// 334pt with every section collapsed *and* the content clipped behind a scroll bar, and it
    /// stayed 334pt however much the content grew. `maximumHeight` never bound, because its own
    /// 400pt floor is above the height the window was taking.
    @State private var contentHeight: CGFloat = 0

    private struct ContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// Never taller than the screen it is hanging from. Read at layout time rather than cached,
    /// since the panel can be opened after the display arrangement has changed.
    private var maximumHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(400, visible - 48)
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, 12)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ContentHeightKey.self, value: proxy.size.height)
                    })
        }
        // Only scrolls when it has to, so a closed panel has no idle scroll affordance and does not
        // rubber-band under the pointer. Vertical only, deliberately: the wide content overflowing
        // horizontally is what lets the growing window *uncover* the second column, and adding a
        // horizontal axis would turn that reveal into a scrollable overflow instead.
        .scrollBounceBehavior(.basedOnSize)
        // Both forms state a width, because a window can only be animated towards a number. The
        // earlier version left the wide form at `nil` and let the content size itself, which is
        // correct at rest and unanimatable in flight — so the panel arrived at its new width in
        // one step, and SwiftUI cross-faded the two layouts over the top of the jump.
        //
        // Height rides in the same modifier rather than in a `.frame(maxHeight:)` of its own, so
        // the two dimensions are interpolated from a single animatable value and the window
        // cannot finish widening before it has finished growing. See `PanelSize` for why an
        // ordinary `.frame` does not reach the window at all.
        .modifier(
            PanelSize(
                width: isWide ? Self.wideWidth : Self.narrowWidth,
                height: contentHeight > 0 ? min(contentHeight, maximumHeight) : 0))
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
        }
        .animation(
            Self.reanchorsBetweenWidths ? nil : PanelSection<EmptyView>.toggle,
            value: isWide)
        .animation(PanelSection<EmptyView>.toggle, value: contentHeight)
        .task { await model.refreshNow() }
        .task { await tick() }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Full width in both layouts: it explains the state of everything below it.
            if let notice = healthNotice {
                HealthNotice(notice: notice)
            }

            // One HStack in both forms, so the leading column keeps its identity across the
            // switch and only the breakdown changes parent. Branching between an HStack and a
            // VStack gave the two layouts *different* identities, and SwiftUI cross-faded
            // them — mid-flight the panel drew the outgoing single column at full opacity on
            // top of the incoming two, which is the ghosting half of the old jump.
            HStack(alignment: .top, spacing: isWide ? Self.columnGap : 0) {
                VStack(alignment: .leading, spacing: 12) {
                    narrowLeadingContent
                    // Narrow, the breakdown simply carries on down the same column.
                    if !isWide {
                        Divider()
                        dailySection
                    }
                }
                .frame(
                    width: isWide ? Self.columnWidth : Self.narrowContentWidth,
                    alignment: .topLeading)

                if isWide {
                    Divider()
                    column { dailySection }
                }
            }
            // No fade on the second column. It is laid out at its final position from the first
            // frame and the widening window uncovers it, which is the motion the resize already
            // implies; cross-fading it as well reads as two effects fighting.
            .transition(.identity)

            Divider()
            footer
        }
    }

    /// Everything except the 30-day breakdown, in the order it reads in one column. In the wide
    /// layout this is the left column and the breakdown is the right one — the split is by height,
    /// not by topic, because the breakdown is the only part that grows without bound.
    @ViewBuilder private var narrowLeadingContent: some View {
        if showsMeters {
            meters
        }

        // Not gated on `isLive`. Recent sessions and the daily chart are derived from the local
        // transcripts, so an API outage says nothing about them — they are as live as ever. Only
        // the sparkline is built from poll samples, and it hides itself when it has none.
        Divider()
        lightSections

        Divider()
        stats
    }

    private func column<Content: View>(@ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { body() }
            .frame(width: Self.columnWidth, alignment: .topLeading)
    }

    // MARK: Meters

    @ViewBuilder private var meters: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeterRow(
                title: WindowKind.fiveHour.longLabel,
                percent: model.fiveHourPercent,
                severity: model.fiveHourSeverity,
                resetsAt: model.fiveHourResetsAt,
                projection: liveProjection(model.fiveHourProjection),
                now: now)

            MeterRow(
                title: WindowKind.sevenDay.longLabel,
                percent: model.sevenDayPercent,
                severity: model.sevenDaySeverity,
                resetsAt: model.sevenDayResetsAt,
                projection: liveProjection(model.sevenDayProjection),
                now: now)

            if model.snapshot?.extraUsage?.spendLimitReached == true {
                Label("Extra usage spend limit reached", systemImage: "creditcard")
                    .font(.caption)
                    .foregroundStyle(SeverityStyle.color(.warning))
            }

            if model.snapshot == nil {
                Text("Waiting for the first reading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isLive ? 1 : 0.55)
    }

    /// Two em-dash meters under a "not signed in" notice say nothing the notice hasn't; once a
    /// snapshot has ever arrived they are worth showing greyed, because those numbers were real.
    private var showsMeters: Bool {
        model.snapshot != nil || isLive
    }

    /// A cached percentage is still a reading that was true at a stated time; a cached projection
    /// is a forecast from a rate nobody is measuring any more, aimed at a reset that may already
    /// have passed. So the percentages stay greyed and the projection goes away entirely, which
    /// is what `MeterRow` does with a nil one.
    private func liveProjection(_ projection: Projection?) -> Projection? {
        isLive ? projection : nil
    }

    // MARK: Sections

    /// Each section's content view owns its own empty state, so this only adds the one thing they
    /// cannot know: that a first transcript scan is still running.
    /// The two sections that stay a reasonable height when open, so they travel with the meters.
    @ViewBuilder private var lightSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The samples themselves were real readings, so they stay visible during an outage;
            // the dashed forecast does not, since nobody is measuring the rate any more.
            if !model.samples.isEmpty {
                PanelSection(title: "Last 5 hours", isExpanded: $expandedFiveHour) {
                    SparklineView(
                        samples: model.samples, kind: .fiveHour,
                        projection: liveProjection(model.fiveHourProjection), now: now,
                        severity: model.fiveHourSeverity)
                }

                // The weekly window gets the same treatment for the same reason: the shaded
                // cone is where its uncertainty lives, and the weekly forecast is the one
                // carrying by far the most of it — days of horizon against a limit whose pace
                // is set by behaviour rather than by anything measurable in the last hour.
                PanelSection(title: "Last 7 days", isExpanded: $expandedWeekly) {
                    SparklineView(
                        samples: model.samples, kind: .sevenDay,
                        projection: liveProjection(model.sevenDayProjection), now: now,
                        severity: model.sevenDaySeverity)
                }
            }

            PanelSection(
                title: "Recent sessions (\(model.sessions.count))", isExpanded: $expandedSessions
            ) {
                if model.sessions.isEmpty, model.isScanning {
                    note("Reading transcripts…")
                } else {
                    SessionsSection(sessions: model.sessions)
                }
            }
        }
    }

    /// Kept separate from the others because it is the one section that can outgrow the screen: a
    /// month of bars plus four proportion groups. In the wide layout it owns the second column.
    @ViewBuilder private var dailySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSection(title: "Last 30 days", isExpanded: $expandedDaily) {
                VStack(alignment: .leading, spacing: 10) {
                    if model.daily.isEmpty, model.isScanning {
                        note("Reading transcripts…")
                    } else {
                        DailyBarsView(daily: model.daily)
                    }
                    // Labelled with their own period: the bars above are the last 30 days, but
                    // `Aggregates.modelSplit` / `effortSplit` run over every cached event, and a
                    // split silently attributed to the section header would overstate its window.
                    if !modelRows.isEmpty {
                        subLabel("Models · all recorded")
                        ShareRowsView(rows: modelRows)
                    }
                    if !effortRows.isEmpty {
                        subLabel("Effort · all recorded")
                        ShareRowsView(rows: effortRows)
                    }
                    if !tokenRows.isEmpty {
                        subLabel("Tokens · all recorded")
                        ShareRowsView(rows: tokenRows)
                        // Without this the split invites the wrong conclusion. Cache reads
                        // dominate the token count but bill at a tenth of the input rate, while
                        // output is a rounding error by volume and bills at five times it — so
                        // the two orderings barely resemble each other.
                        note("Output is a small share of tokens and a large share of cost.")
                    }
                    if !costRows.isEmpty {
                        subLabel("Cost share · all recorded")
                        ShareRowsView(rows: costRows)
                    }
                }
            }
        }
    }

    /// Fractions are taken over *every* model, not just the rows shown, so a truncated list
    /// cannot imply the top few account for everything.
    private var modelRows: [ShareRow] {
        let total = model.models.reduce(0) { $0 + $1.tokens.total }
        guard total > 0 else { return [] }
        return model.models.prefix(5).map { usage in
            ShareRow(
                id: "model-\(usage.model)",
                label: usage.displayName,
                detail: UsageNumberFormat.tokens(usage.tokens.total),
                fraction: Double(usage.tokens.total) / Double(total))
        }
    }

    private var effortRows: [ShareRow] {
        let total = model.efforts.reduce(0) { $0 + $1.tokens.total }
        guard total > 0 else { return [] }
        return model.efforts.prefix(5).map { usage in
            ShareRow(
                id: "effort-\(usage.id)",
                label: usage.effort?.capitalized ?? "Unset",
                detail: UsageNumberFormat.tokens(usage.tokens.total),
                fraction: Double(usage.tokens.total) / Double(total))
        }
    }

    /// Every token the corpus touched, split by which side of the request it was on. `cacheCreate`
    /// is the total, so it is *not* added to the 5m/1h split — that would count those tokens twice.
    private var tokenTotals: TokenCounts {
        model.models.reduce(TokenCounts.zero) { $0 + $1.tokens }
    }

    /// Fractioned by token count, which is what the label promises. Compare with `costRows`.
    private var tokenRows: [ShareRow] {
        let tokens = tokenTotals
        let total = tokens.total
        guard total > 0 else { return [] }
        return [
            ("Input", tokens.input),
            ("Cache read", tokens.cacheRead),
            ("Cache write", tokens.cacheCreate),
            ("Output", tokens.output),
        ]
        .filter { $0.1 > 0 }
        .map { name, value in
            ShareRow(
                id: "tok-\(name)",
                label: name,
                detail: UsageNumberFormat.tokens(value),
                fraction: Double(value) / Double(total))
        }
    }

    /// The same four fields priced. Taken from `Aggregates`, which prices each event at its own
    /// timestamp — re-pricing the pooled totals here at today's rate made the rows stop summing to
    /// the total beside them whenever a rate had changed since the usage happened.
    private var costRows: [ShareRow] {
        let costs = model.models.reduce(FieldCosts.zero) { $0 + $1.fieldCosts }
        let total = costs.total
        guard total > 0 else { return [] }
        return [
            ("Input", costs.input),
            ("Cache read", costs.cacheRead),
            ("Cache write", costs.cacheWrite),
            ("Output", costs.output),
        ]
        .filter { $0.1 > 0 }
        .map { name, value in
            ShareRow(
                id: "cost-\(name)",
                label: name,
                detail: UsageNumberFormat.cost(value),
                fraction: value / total)
        }
    }

    // MARK: Stats

    /// Never greyed with the health notice: these come from the local transcripts, so a failed
    /// poll leaves them just as current as they were.
    @ViewBuilder private var stats: some View {
        if model.eventCount > 0 {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Today")
                    grid(columns: 2) {
                        StatTile(
                            label: "Tokens in",
                            value: UsageNumberFormat.tokens(
                                (model.today?.tokens).map {
                                    $0.input + $0.cacheRead + $0.cacheCreate
                                } ?? 0),
                            help: "Everything sent: fresh input plus cache reads and cache writes. "
                                + "Cache reads usually dominate and bill at a tenth of the input "
                                + "rate.")
                        StatTile(
                            label: "Tokens out",
                            value: UsageNumberFormat.tokens(model.today?.tokens.output ?? 0),
                            help: "Generated tokens. A small fraction of the volume and a large "
                                + "fraction of the cost — output bills at five times the input "
                                + "rate.")
                        StatTile(
                            label: "Sessions",
                            value: "\(sessionsToday)",
                            help: "Stretches of work that started today. One transcript session "
                                + "counts more than once if it was picked up again after a pause "
                                + "longer than the active-gap setting.")
                        StatTile(
                            label: "Cost equiv",
                            value: UsageNumberFormat.cost(model.today?.costEquivalent ?? 0),
                            help: "Equivalent spend at published API rates. A subscription is not "
                                + "billed per token, so this is never a bill.")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("All recorded activity")
                    grid {
                        StatTile(
                            label: "Cache hit",
                            value: UsageNumberFormat.share(model.cacheHitRatio),
                            help: "Share of input-side tokens served from cache. Output tokens "
                                + "are excluded — they are generated, never read.")
                        StatTile(
                            label: "Active time",
                            value: wallClockText,
                            help: wallClockHelp)
                        StatTile(
                            label: "Agent hours",
                            value: agentHoursText,
                            help: agentHoursHelp)
                    }
                }
            }
        } else {
            note(
                model.isScanning
                    ? "Reading local transcripts…"
                    : "No local Claude Code activity found yet.")
        }
    }

    /// `columns` is explicit because tile counts differ per grid, and a count that does not divide
    /// the tiles leaves a ragged last row on a panel this narrow.
    private func grid<Content: View>(
        columns: Int = 3, @ViewBuilder _ content: () -> Content
    ) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 8, alignment: .topLeading),
                count: max(1, columns)),
            alignment: .leading, spacing: 8
        ) {
            content()
        }
    }

    /// `AppModel` publishes no per-day session count, so this is counted here rather than adding
    /// an aggregate for one tile.
    private var sessionsToday: Int {
        let calendar = Calendar.current
        return model.sessions.filter { calendar.isDate($0.start, inSameDayAs: now) }.count
    }

    /// Both hour figures are inferences, not measurements — the transcripts carry no durations,
    /// so these are clustered message timestamps — hence the `~`, the same marker the cost
    /// equivalent carries. `<1m` is already an approximation and is left alone.
    private var wallClockText: String {
        guard let hours = model.usageHours else { return "—" }
        return approximate(hours.wallClock)
    }

    /// An account that has never spawned a sub-agent has no agent hours at all, and
    /// `compactDuration` floors at `<1m`, which would read as a brief burst of agent work.
    private var agentHoursText: String {
        guard let hours = model.usageHours else { return "—" }
        guard hours.agentCount > 0 else { return "None" }
        return approximate(hours.agentTotal)
    }

    private func approximate(_ interval: TimeInterval) -> String {
        let text = UsageNumberFormat.compactDuration(interval)
        return text.hasPrefix("<") ? text : "~" + text
    }

    /// Called "Active time" rather than "wall clock", which is what it used to say and what it
    /// is not. The figure is the sum of the gaps *between* messages inside each stretch, so the
    /// time spent generating a stretch's final reply is never in it, and a genuinely busy day
    /// whose messages all sit further apart than the gap setting counts as zero. It is a floor.
    private var wallClockHelp: String {
        guard let hours = model.usageHours else { return "" }
        let minutes = Int((hours.gap / 60).rounded())
        return "Active stretches across every session, merged so concurrent work counts once. "
            + "A pause longer than \(minutes) min ends a stretch. Measured between message "
            + "timestamps — the transcripts record no durations — so it counts time inside a "
            + "stretch and not the reply that ends one. A floor on time spent rather than a "
            + "measurement of it, and it moves with the active-gap setting."
    }

    private var agentHoursHelp: String {
        guard let hours = model.usageHours else { return "" }
        guard hours.agentCount > 0 else {
            return "No sub-agent activity in the local transcripts yet."
        }
        return "Sum of \(hours.agentCount) sub-agent spans, inferred from message timestamps. "
            + "20 agents running for 30 minutes is 10 agent-hours."
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(updatedText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 0)

            // Not `SettingsLink`: the `Settings` scene it opens is unreliable in an accessory
            // app. See `SettingsWindowController`.
            Button {
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings…")
            .keyboardShortcut(",", modifiers: .command)

            Button("Quit") { model.quit() }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    /// Seconds granularity, unlike `UsageNumberFormat.ago`: at a 60-second cadence "Updated now"
    /// would sit there for a whole minute, and the point of the line is to say how fresh the
    /// numbers above it are.
    private var updatedText: String {
        guard let last = model.lastUpdate else {
            return model.isScanning ? "Scanning…" : "No reading yet"
        }
        // Clamped before the `Int` conversion, which traps past `Int.max`: `lastUpdate` can come
        // from the cached snapshot on disk, whose dates are stored as raw epoch seconds.
        let age = min(max(0, now.timeIntervalSince(last)), Self.maximumReportedAge)
        let seconds = Int(age.rounded())
        if seconds < 10 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        if seconds < 3600 { return "Updated \(seconds / 60)m ago" }
        if seconds < 86_400 { return "Updated \(seconds / 3600)h ago" }
        return "Updated \(seconds / 86_400)d ago"
    }

    private static let maximumReportedAge: TimeInterval = 3_650 * 24 * 3600

    // MARK: Health

    private var isLive: Bool {
        if case .live = model.health { return true }
        return false
    }

    private var healthNotice: HealthNotice.Notice? {
        switch model.health {
        case .live:
            return nil
        case .noCredentials:
            return notice(
                symbol: "person.crop.circle.badge.questionmark",
                title: "Not signed in",
                detail: "Sign in to Claude Code, then ClaudeMeter picks the credentials up on its "
                    + "next poll.",
                tint: SeverityStyle.color(.warning))
        case .staleCredentials:
            return notice(
                symbol: "exclamationmark.triangle",
                title: "Token expired",
                detail: "ClaudeMeter reads Claude Code's token but never refreshes it. Run any "
                    + "Claude Code command to renew it.",
                tint: SeverityStyle.color(.warning))
        case let .offline(since, reason):
            // "Rate limited" on its own reads as stuck. What the reader needs is when it will
            // try again, which is our backoff — not the server's `Retry-After`, which this
            // endpoint sends as 0.
            var detail = reason
            if let next = model.nextAttemptAt {
                detail += " · retrying in \(MenuBarLabelText.compactDuration(until: next, now: now))"
            }
            detail += ". The statistics below come from your local transcripts and are unaffected."
            return notice(
                symbol: "wifi.slash",
                title: offlineTitle(since: since),
                detail: detail,
                tint: Color.secondary)
        }
    }

    /// The cached-numbers sentence is appended only when there are cached numbers: on a first
    /// launch with no network the app has never read anything, `showsMeters` is false, and a
    /// notice claiming to show the last reading would be describing an empty panel.
    private func notice(
        symbol: String, title: String, detail: String, tint: Color
    ) -> HealthNotice.Notice {
        HealthNotice.Notice(
            symbol: symbol,
            title: title,
            detail: model.snapshot == nil
                ? detail
                : detail + " The meters below are the last reading, not live.",
            tint: tint)
    }

    /// "Offline since 3:45 PM" needs a moment the numbers were true. With nothing cached, `since`
    /// is only the first failed attempt, and a non-finite one — the snapshot cache on disk stores
    /// dates as raw epoch seconds — has no clock time at all, so both fall back to a plain title.
    private func offlineTitle(since: Date) -> String {
        guard model.snapshot != nil, since.timeIntervalSince1970.isFinite else {
            return "Can't reach the usage API"
        }
        return "Offline since \(offlineSinceText(since))"
    }

    /// Clock time alone while the outage started today, date as well once it did not: a panel
    /// opened the next morning must not read yesterday afternoon as this afternoon.
    private func offlineSinceText(_ since: Date) -> String {
        Calendar.current.isDate(since, inSameDayAs: now)
            ? since.formatted(date: .omitted, time: .shortened)
            : since.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private func subLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Lifecycle

    /// Cancelled with the view, so a closed panel ticks nothing. `AppModel.refreshNow()` owns the
    /// staleness gate; repeating the interval here would let the two drift apart.
    @MainActor private func tick() async {
        while !Task.isCancelled {
            now = Date()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }
}

// MARK: - Health notice

extension PanelView {
    /// The inline replacement for the charts when the app has no live data: what is wrong, and
    /// what the user can do about it.
    fileprivate struct HealthNotice: View {
        struct Notice {
            let symbol: String
            let title: String
            let detail: String
            let tint: Color
        }

        let notice: Notice

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: notice.symbol)
                    .foregroundStyle(notice.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(.callout)
                        .fontWeight(.medium)
                    Text(notice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Stat tile

extension PanelView {
    fileprivate struct StatTile: View {
        let label: String
        let value: String
        var help: String = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(value)
                    .font(.body)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(help)
            .accessibilityElement(children: .combine)
        }
    }
}
