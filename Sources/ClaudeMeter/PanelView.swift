import AppKit
import SwiftUI
import UsageCore

// MARK: - Panel

/// The whole menu bar panel: two meters, five collapsible sections, three collapsible stat
/// groups, a footer.
///
/// One narrow column while the content still fits the screen, two columns and a height cap once it
/// does not — see `settleLayout()`.
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
    @AppStorage(Prefs.expandedHours) private var expandedHours = Prefs.Default.expandedHours

    /// One key per stats group rather than one for the block, because the three headers already
    /// exist — collapsing them costs no new rows, where a single "Stats" wrapper would have to add
    /// a header the panel does not have today or drop three that carry the period each grid covers.
    @AppStorage(Prefs.expandedToday) private var expandedToday = Prefs.Default.expandedToday
    @AppStorage(Prefs.expandedAllRecorded) private var expandedAllRecorded = Prefs.Default
        .expandedAllRecorded
    @AppStorage(Prefs.expandedHeadroom) private var expandedHeadroom = Prefs.Default
        .expandedHeadroom

    /// Whether the panel is in its two-column form. Maintained by `settleLayout()` from measured
    /// height rather than from which sections are open, and persisted only as a seed: see
    /// `Prefs.panelWide`.
    @AppStorage(Prefs.panelWide) private var isWide = Prefs.Default.panelWide

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

    /// Two columns exactly when one column would not fit the screen *and* splitting it would help,
    /// rather than because some particular section is open.
    ///
    /// The rule this replaces named sections: `expandedDaily` on its own, or any two of the lighter
    /// ones. That is what made collapsing feel broken. With "Last 30 days" open the panel was wide
    /// by definition, so closing every other section in turn changed nothing, and the only control
    /// that reached the layout was the one section the reader wanted to keep open. Measuring
    /// instead makes every collapse count towards it: each one shortens the content, and any
    /// sequence of them that gets it back under the screen height restores the single column.
    ///
    /// The second condition is the part a height alone cannot say. A panel that overruns because
    /// the session list is long, with the breakdown collapsed, has nothing to move into a second
    /// column — the split would buy back one collapsed header and cost the full width. That case
    /// stays narrow and scrolls, which is what the old rule did with it too.
    ///
    /// Content that fits in neither form is still the height cap's problem, not this one.
    ///
    /// Both comparisons carry the band on the side that keeps the current form; see
    /// `PanelLayout.hysteresis`.
    private func settleLayout() {
        let stacked = stackedContentHeight
        guard stacked > 0 else { return }
        let wanted = PanelLayout.wantsWide(
            stackedHeight: stacked, splitSaving: splitSaving,
            maximumHeight: maximumHeight, isWide: isWide)
        // Guarded rather than assigned every pass: this runs on each frame of a section's open
        // animation, and `@AppStorage` writes through to `UserDefaults` whether or not the value
        // moved.
        if wanted != isWide { isWide = wanted }
    }

    /// What the second column buys: the shorter block moves up beside the taller one instead of
    /// sitting under it, so the height saved is the whole of the shorter block plus the gap that
    /// separated them. Heights of zero are a pass that has not measured yet, and read here as a
    /// saving too small to act on — the safe answer for a pass that knows nothing.
    private var splitSaving: Double {
        PanelLayout.splitSaving(
            leading: columnHeights.leading, daily: columnHeights.daily,
            stackedGap: Self.stackedGap)
    }

    /// The height the content *would* have in one column, whichever form it is in now.
    ///
    /// Being able to ask that from inside the other form is what keeps the decision above from
    /// feeding on itself. The obvious version — widen when the measured height exceeds the screen —
    /// oscillates, because widening is precisely what makes the measured height small again, which
    /// satisfies the condition to narrow, which makes it large again: the panel changes form every
    /// frame.
    ///
    /// So the two blocks that swap columns are measured separately and the arrangement is
    /// substituted rather than re-measured. Side by side they occupy `max(leading, daily)`; stacked
    /// they occupy `leading + gap + daily`; everything else on the panel — footer, dividers,
    /// padding — is common to both and cancels. The only thing the current form decides is which
    /// of the two terms is subtracted back out.
    ///
    /// "Cancels" is a requirement on those other terms, not an observation about them. The health
    /// notice wraps its text, so left to itself it is *not* common to both: at 251pt against
    /// 592pt of measure, a long decoding error runs about nine lines in one column and four in
    /// two, a 65pt difference that alone exceeds the hysteresis band and flips the panel between
    /// forms every frame. It is pinned to one width in `content` for exactly this reason.
    ///
    /// The substitution is exact at rest and generous mid-flight, which is the useful direction.
    /// The blocks animate to their new sizes after a change of form, so during those 0.3s the
    /// estimate carries the outgoing arrangement's slack — too tall just after narrowing to wide,
    /// too short just after widening to narrow. Both errors argue for staying where the panel just
    /// went.
    private var stackedContentHeight: Double {
        PanelLayout.stackedHeight(
            measured: contentHeight, isWide: isWide, leading: columnHeights.leading,
            daily: columnHeights.daily, stackedGap: Self.stackedGap)
    }

    /// The 12pt spacing, divider and second 12pt spacing between the two blocks when they stack,
    /// which the two-column form does not spend.
    private static let stackedGap: CGFloat = 12 + dividerThickness + 12

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

    /// Natural heights of the two blocks that swap columns, which `stackedContentHeight` needs
    /// apart — in one column they share a `VStack` and `contentHeight` cannot tell them apart.
    @State private var columnHeights = ColumnHeights()

    /// One preference rather than two, so both heights land in the same update. Measured a key
    /// apart, a pass that carried the new height of one block and the old height of the other
    /// would put the decision against a total neither form has.
    private struct ColumnHeights: Equatable {
        var leading: CGFloat = 0
        var daily: CGFloat = 0
    }

    private struct ColumnHeightsKey: PreferenceKey {
        static let defaultValue = ColumnHeights()
        /// Componentwise, because each probe reports one field and leaves the other at zero.
        static func reduce(value: inout ColumnHeights, nextValue: () -> ColumnHeights) {
            let next = nextValue()
            value.leading = max(value.leading, next.leading)
            value.daily = max(value.daily, next.daily)
        }
    }

    /// Reports a block's height without taking part in the layout: a background is offered the size
    /// its content has already chosen, so measuring from there cannot change it.
    private func heightProbe(_ report: @escaping (CGFloat) -> ColumnHeights) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: ColumnHeightsKey.self, value: report(proxy.size.height))
        }
    }

    /// Never taller than the screen it is hanging from. Read at layout time rather than cached,
    /// since the panel can be opened after the display arrangement has changed.
    ///
    /// The screen the *status item* is on, not `NSScreen.main`, for the reason `PanelAnchor`
    /// gives about horizontal placement and which applies just as much to height: `main` is the
    /// screen with the key window, so a laptop-plus-external desk with the key window on the
    /// external measures a panel hanging from the laptop's menu bar against the external's
    /// height. That reads as 1392pt of room on a display with 852, and the panel is neither
    /// capped nor split — it is simply clipped off the bottom, which is the failure the whole
    /// rule exists to prevent.
    private var maximumHeight: CGFloat {
        let visible = PanelAnchor.statusItemScreen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height ?? 900
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
        // ordinary `.frame` does not reach the window at all. `PanelAnchor` travels inside that
        // modifier, so the window's size and placement are driven from the same interpolated
        // values the content is.
        .modifier(
            PanelSize(
                width: isWide ? Self.wideWidth : Self.narrowWidth,
                height: contentHeight > 0 ? min(contentHeight, maximumHeight) : 0))
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
        }
        .onPreferenceChange(ColumnHeightsKey.self) { heights in
            columnHeights = heights
        }
        // Not inside the preference handlers. Those run from the layout pass that produced the
        // measurement, and the form is a function of *both* of them — deciding from whichever
        // arrived first would judge a half-updated pair. `onChange` runs after the update has
        // settled, and a decision that changes nothing costs a comparison.
        .onChange(of: contentHeight) { settleLayout() }
        .onChange(of: columnHeights) { settleLayout() }
        .animation(PanelSection<EmptyView>.toggle, value: isWide)
        .animation(PanelSection<EmptyView>.toggle, value: contentHeight)
        .task { await model.refreshNow() }
        .task { await tick() }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pinned to the narrow column's width in *both* layouts rather than spanning the
            // panel, because its height has to be the same in both. It is the one block outside
            // the two column probes whose height depends on width — `detail` is a wrapping
            // `Text` — and `stackedContentHeight` reconstructs the one-column height on the
            // assumption that everything outside those probes cancels. Left to span, a long
            // decoding error wraps to about nine lines at 251pt of measure and four at 592pt;
            // that 65pt is more than the whole hysteresis band, so the panel would satisfy the
            // condition to widen in one form and the condition to narrow in the other, and
            // change form on every frame for as long as the notice was on screen — which is
            // whenever the app is offline, the only time it exists.
            //
            // Capping the measure is also the better reading: a caption running the full 633pt
            // of the two-column form is well past the line length anything else here uses.
            if let notice = healthNotice {
                HealthNotice(notice: notice)
                    .frame(width: Self.narrowContentWidth, alignment: .leading)
            }

            // One HStack in both forms, so the leading column keeps its identity across the
            // switch and only the breakdown changes parent. Branching between an HStack and a
            // VStack gave the two layouts *different* identities, and SwiftUI cross-faded
            // them — mid-flight the panel drew the outgoing single column at full opacity on
            // top of the incoming two, which is the ghosting half of the old jump.
            HStack(alignment: .top, spacing: isWide ? Self.columnGap : 0) {
                VStack(alignment: .leading, spacing: 12) {
                    // Nested in a stack of its own rather than spliced straight in, so that its
                    // height can be measured on its own. Narrow, this block and the breakdown
                    // below share a column, and `stackedContentHeight` needs the two apart. The
                    // spacing matches the stack outside it, so the arrangement is unchanged.
                    VStack(alignment: .leading, spacing: 12) { narrowLeadingContent }
                        .background(heightProbe { ColumnHeights(leading: $0) })

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
                // Titles name the period, not a lookback: the charts now span the window itself
                // rather than the trailing five hours or seven days, and "Last 5 hours" was
                // already wrong on both counts — the old domain reached across turnovers and
                // measured 6.93 hours. Built from `longLabel` so they cannot drift from the
                // meter rows directly above, which read "5-hour" and "Weekly".
                PanelSection(
                    title: "\(WindowKind.fiveHour.longLabel) window", isExpanded: $expandedFiveHour
                ) {
                    SparklineView(
                        samples: model.samples, kind: .fiveHour,
                        resetsAt: model.fiveHourResetsAt,
                        projection: liveProjection(model.fiveHourProjection), now: now,
                        severity: model.fiveHourSeverity)
                }

                // The weekly window gets the same treatment for the same reason: the shaded
                // cone is where its uncertainty lives, and the weekly forecast is the one
                // carrying by far the most of it — days of horizon against a limit whose pace
                // is set by behaviour rather than by anything measurable in the last hour. On
                // the fixed domain that cone is most of the chart's width, which is the honest
                // proportion: most of the window is still ahead.
                PanelSection(
                    title: "\(WindowKind.sevenDay.longLabel) window", isExpanded: $expandedWeekly
                ) {
                    SparklineView(
                        samples: model.samples, kind: .sevenDay,
                        resetsAt: model.sevenDayResetsAt,
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

            // Sits with the light sections rather than under "Last 30 days", even though both
            // cover the same month: this one is a fixed 24 bars however long the account has
            // been running, so it cannot grow the way the daily section can.
            PanelSection(title: "When you work", isExpanded: $expandedHours) {
                if model.hourProfile.isEmpty, model.isScanning {
                    note("Reading transcripts…")
                } else {
                    HourProfileView(buckets: model.hourProfile)
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
        // Measured here rather than at either call site, since only one of them renders at a time
        // and the height is the same in both — the column and the narrow content are within 8pt
        // of each other in width.
        .background(heightProbe { ColumnHeights(daily: $0) })
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
    /// Headroom in work rather than in percent.
    ///
    /// Purely additive: the meters above still carry the percentages, the reset times and the
    /// forecasts. This answers the question a percentage cannot — *how much can I still do* —
    /// by pricing a point in the tokens that were observed to consume one.
    ///
    /// Every figure here is a floor. Only local transcripts are visible, so any usage from
    /// claude.ai, the desktop app or another machine raised the percentage without contributing
    /// tokens to the measurement, which makes a point look cheaper than it is and the headroom
    /// smaller than it is. Under-promising is the safe direction for a budget.
    @ViewBuilder private var headroom: some View {
        let five = model.fiveHourCalibration
        let weekly = model.sevenDayCalibration
        // Still gated on having something to say. A collapsible empty section is worse than no
        // section: the chevron promises content that opening it does not produce.
        if five != nil || weekly != nil || model.cyclePace != nil {
            PanelSection(title: "Headroom", isExpanded: $expandedHeadroom) {
                grid(columns: 2) {
                    if let five, let left = five.headroom(fromPercent: model.fiveHourPercent ?? 0) {
                        StatTile(
                            label: "5-hour left",
                            value: UsageNumberFormat.tokens(Int(left)),
                            help: "Weighted tokens still available on the 5-hour window, priced "
                                + "at \(UsageNumberFormat.tokens(Int(five.weightedTokensPerPoint))) "
                                + "per point — measured over \(five.intervals) intervals of your "
                                + "own history. A floor: usage this app cannot see makes a point "
                                + "look cheaper than it is.")
                    }
                    if let weekly,
                        let left = weekly.headroom(fromPercent: model.sevenDayPercent ?? 0)
                    {
                        StatTile(
                            label: "Weekly left",
                            value: UsageNumberFormat.tokens(Int(left)),
                            help: "Weighted tokens still available this week, priced at "
                                + "\(UsageNumberFormat.tokens(Int(weekly.weightedTokensPerPoint))) "
                                + "per point over \(weekly.intervals) intervals. Same floor "
                                + "caveat as the 5-hour figure.")
                    }
                    if let paceText = cyclePaceText {
                        StatTile(
                            label: "Vs your norm",
                            value: paceText,
                            help: cyclePaceHelp)
                    }
                    if let spreadText = familySpreadText {
                        StatTile(
                            label: "Model cost",
                            value: spreadText,
                            help: familySpreadHelp)
                    }
                }
            }
        }
    }

    /// `+18%` near the norm, `15.6×` well away from it.
    ///
    /// A percentage stops being readable past a doubling — this account's first reading was
    /// `+1456%`, which is a number nobody parses at a glance — and that is the *ordinary* case
    /// for anyone whose usage has grown since the weeks being compared against, not an edge
    /// one. A multiple says the same thing in three characters. Below a halving the same
    /// applies in the other direction.
    private var cyclePaceText: String? {
        guard let pace = model.cyclePace, let ratio = pace.ratio, ratio.isFinite, ratio > 0
        else { return nil }
        if ratio >= 2 || ratio <= 0.5 { return String(format: "%.1f×", ratio) }
        let percent = Int(((ratio - 1) * 100).rounded())
        if percent == 0 { return "on pace" }
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }

    private var cyclePaceHelp: String {
        guard let pace = model.cyclePace else { return "" }
        let fraction = Int((pace.elapsedFraction * 100).rounded())
        return "Weighted spend this cycle against the median of the previous "
            + "\(pace.priorCycles) at the same \(fraction)% mark. Compared at equal elapsed "
            + "fraction rather than equal totals — three days into a week is not comparable "
            + "with a finished one. Measured from transcripts, which reach back much further "
            + "than the poll history does."
    }

    /// `Opus 3.4× Sonnet` — how much faster the dearer family burns the limit per token.
    private var familySpreadText: String? {
        guard let spread = model.sevenDayCalibration?.familySpread ?? model.fiveHourCalibration?.familySpread,
            spread.ratio.isFinite, spread.ratio > 1
        else { return nil }
        return String(format: "%@ %.1f×", spread.dearest.family, spread.ratio)
    }

    private var familySpreadHelp: String {
        guard let spread = model.sevenDayCalibration?.familySpread
            ?? model.fiveHourCalibration?.familySpread
        else { return "" }
        return "How much more of the limit \(spread.dearest.family) consumes per weighted token "
            + "than \(spread.cheapest.family), measured only over intervals where one family did "
            + "at least 80% of the work. Blank until your history contains stretches dominated "
            + "by each in turn — mixed usage leaves the two impossible to tell apart."
    }

    @ViewBuilder private var stats: some View {
        if model.eventCount > 0 {
            // 8pt between the groups rather than the 10 they sat at while permanently open, so
            // three collapsed stats headers keep the same rhythm as the collapsed section headers
            // directly above them in `lightSections`.
            VStack(alignment: .leading, spacing: 8) {
                PanelSection(title: "Today", isExpanded: $expandedToday) {
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

                PanelSection(title: "All recorded activity", isExpanded: $expandedAllRecorded) {
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
                        StatTile(
                            label: "Sub-agents",
                            value: UsageNumberFormat.share(model.sidechainShare),
                            help: "Share of limit-weighted spend that went to sub-agents rather "
                                + "than the main conversation. Weighted rather than raw, so it "
                                + "answers how much of the limit they consume.")
                    }
                }

                headroom
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

            // Forces both halves: the poll for the meters and a rescan for everything below them.
            Button {
                Task { await model.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canRefreshNow)
            .help(refreshHelp)
            .keyboardShortcut("r", modifiers: .command)

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

    /// Says which of the three states the button is in, because two of them make it do nothing.
    /// The deferral one re-reads on the panel's own tick, so the button comes back within a few
    /// seconds of the gate elapsing rather than on the next poll.
    private var refreshHelp: String {
        if model.isPolling { return "Checking…" }
        if let next = model.nextAttemptAt {
            return "The last poll failed, so the next attempt is held until "
                + "\(MenuBarLabelText.compactDuration(until: next, now: now)) from now. Asking "
                + "again inside that window spends a request the server has already refused."
        }
        return "Check the limits and rescan the transcripts now (⌘R)"
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
