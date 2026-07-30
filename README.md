# ClaudeMeter

A macOS menu bar app for Claude usage. It shows how far into your 5-hour and weekly rate-limit
windows you are, projects where each window lands by the time it resets, and summarises the local
Claude Code transcripts: recent sessions, per-model and per-effort token splits, time spent, cache
hit ratio, and equivalent cost at published API rates.

It is a menu bar item and nothing else. `LSUIElement` is set in `Packaging/Info.plist`, so there is
no Dock icon and no app-switcher entry, with one deliberate exception while the settings window is
open. There are no third-party dependencies: `Package.swift` declares none. The code is split into
two targets — `UsageCore`, which imports only Foundation and Security and holds every decision worth testing,
and `ClaudeMeter`, the SwiftUI and AppKit shell around it.

## What it shows

### Menu bar

A ring plus, depending on the chosen format, a short piece of text. The ring fills clockwise from
12 o'clock in proportion to utilization and is tinted by severity: accent colour when normal, orange
at warning, red at critical. Severity comes from the `limits[]` entry whose `group` matches the
window — `session` for the 5-hour window, `weekly` for the weekly one — skipping `weekly_scoped`
rows, since those are per-model caps rather than the window itself. Only when there is no such entry
is severity classified from the percentage by `UsageCore`'s own thresholds. A filled dot appears in
the centre of the ring when the projection says the window will reach 100% before it resets.

Four text formats are available (the settings labels use illustrative values):

| Format                | Renders           | Meaning                              |
| --------------------- | ----------------- | ------------------------------------ |
| `percentAndPace`      | `42% → 63%`       | Utilization now, and projected at reset. Default. |
| `percent`             | `42%`             | Utilization only.                    |
| `percentAndTimeLeft`  | `42% · 2h41m`     | Utilization and time to reset.       |
| `iconOnly`            | ring only         | No text.                             |

The pace arrow is suppressed when the projection lands within a point of the current value, since a
label that reads `42% → 42%` is noise, not information.

### Panel

Clicking the item opens a window (not an `NSMenu`, because Swift Charts and disclosure groups do
not render inside one). It is one column while the sections are closed and two once the daily
breakdown is open, since that section alone is taller than a single column can show. Top to bottom:

- A notice when something is wrong: not signed in, token expired, or offline with the reason, when
  the next request is due, and a reminder that the transcript-derived statistics below are
  unaffected.
- Two meters, one per window, each with the percentage, a capsule bar, a reset line that switches
  from a countdown to a weekday-and-time once the reset is twelve hours or more out, a pace line
  (`↗ 12 pts/hr · 63% at reset ± 4`), and a warning line when the window is on pace to hit 100%
  early. A projection fitted from transcript velocity instead of the poll series is marked
  `estimated`.
- Three collapsible sections whose expanded state persists across launches: a chart of the last five
  hours of poll samples with the projection continued to the reset as a dashed line and its
  confidence band as a faint cone; recent sessions (project, age, duration, message count, input-side
  and output tokens, cost equivalent), capped at eight rows with the remainder acknowledged as a
  count; and a 30-day daily token chart followed by model, effort, token-side and cost-side splits.
- A stats grid: today's tokens in and out, sessions started today, today's cost equivalent, and then
  cache hit ratio, wall-clock hours and agent-hours over everything recorded.
- A footer with the age of the last reading, a settings button, and quit.

### Settings

Menu bar format; the idle gap that separates one stretch of work from the next (5 to 30 minutes,
default 10) with a live wall-clock readout; a read-only display of the current poll cadence and why
it is what it is; the notification toggle and threshold (50% to 99%, default 90); launch at login
via `SMAppService`; and a footer naming the support directory and restating that the OAuth token is
read but never written.

## Requirements

- macOS 14 or later. `Package.swift` declares `.macOS(.v14)` and the bundle sets
  `LSMinimumSystemVersion` to `14.0`.
- A Swift 6 toolchain. `Package.swift` is `swift-tools-version: 6.0`; the targets themselves are
  built in Swift 5 language mode.
- Claude Code, installed and signed in. The app reads the credential item Claude Code writes to the
  Keychain and never authenticates on its own, so without a Claude Code login there is nothing for
  it to read.

## Build and install

| Command          | Effect |
| ---------------- | ------ |
| `make app`       | Release build, then assemble `dist/ClaudeMeter.app`. |
| `make run`       | `make app`, kill any running copy, then `open` the bundle. |
| `make install`   | `make app`, then copy the bundle to `/Applications`. |
| `make test`      | Run the `UsageCore` suite. |
| `make uninstall` | Kill the running copy and remove it from `/Applications`. |
| `make clean`     | `swift package clean` and remove `dist/`. |

SwiftPM produces a bare executable, so the bundle is assembled by hand: the Makefile creates the
`Contents` tree, copies the binary and `Packaging/Info.plist`, writes `PkgInfo`, copies any SwiftPM
resource bundles into `Contents/Resources` so `Bundle.module` resolves, and signs the result ad hoc
(`codesign --force --sign -`).

Two consequences of that ad-hoc signature are worth knowing before you build. An ad-hoc signature
gives the app a new code identity every time it is rebuilt, so macOS treats each rebuild as a
different program and asks for Keychain access again; signing with a stable self-signed certificate
avoids the repeat prompts. And the app must be run from the bundle for two features to work at all:
`UNUserNotificationCenter.current()` traps in a process with no bundle identifier, so every
notification path degrades to a no-op when the binary is run straight out of `.build`, and
`SMAppService` reports `notFound` there, which the settings pane surfaces as a note instead of a
broken toggle.

`make test` passes `--no-parallel`, and that flag is load-bearing, not caution. Several
suites redirect the same process-global path overrides in `Paths`, and swift-testing runs suites
concurrently, so in parallel one suite's temp-tree cleanup can delete another's mid-test.

## Where the numbers come from

Two sources, for two different jobs.

**Limit percentages come from the usage endpoint.** `LimitsClient` issues a single
`GET https://api.anthropic.com/api/oauth/usage` with an `Authorization: Bearer` header and
`Accept: application/json`; no other header is required and none is sent. The response carries
`five_hour.utilization`, `seven_day.utilization`, `resets_at` timestamps, a generic `limits[]` array
(each entry with a `kind`, `group`, `percent`, `severity`, and an optional model scope, which is
where per-model weekly caps appear), and an `extra_usage` object. These are the server's own
figures. The limit accounting is not derivable from token counts, so there is no way to reconstruct
them locally, which is why the app polls at all.

Decoding is deliberately lossy, key by key. Each top-level key is read independently, one malformed
entry in `limits[]` is dropped instead of failing the array, and an unrecognised severity string is
classified from the percentage instead of failing the decode. The two fields that are *not* treated
that way are `utilization` and a limit row's `percent`: substituting zero for an unreadable
percentage would tell you a window is empty when the truth is that it could not be read, so those
drop the window or the row instead.

**Token detail comes from the local transcripts.** `TranscriptScanner` reads
`~/.claude/projects/**/*.jsonl` and turns every assistant row carrying a `message.usage` object into
one event: input, output, cache-creation (with the 5-minute and 1-hour buckets kept separately) and
cache-read token counts, plus the model, the `effort` field, the session id, the working directory,
whether the row is a sidechain, and the sub-agent id when there is one. Rows whose model is
`<synthetic>` are dropped, since those token counts were never billed.

Neither source substitutes for the other. The API knows your limits but reports no tokens, no
history and no per-project detail; the transcripts know every token but nothing about limits. Burn
rate is where they meet. The rate is a least-squares fit of utilization against time over the
trailing 45 minutes of the persisted poll series, and it is attempted only when two conditions hold
together: at least four usable samples, and at least ten minutes between the first and the last of
them. Both matter, because at the starting cadence of 180 seconds four samples span nine minutes —
the span is the condition still outstanding at that point, and a further poll is what clears it. Once
the fit exists the projection is labelled `measured`. Until then — after a fresh install, and again
after any gap long enough to empty the trailing window — the app weights recent transcript tokens by
their relative API price, calibrates that weight against the current utilization to get
points-per-token without knowing your actual limits, and labels the result `estimated`. The weighting
only needs the ratios between token classes, which is why it does not depend on per-model rates.

**Cost figures are equivalent-cost estimates, not a bill.** A subscription is not billed per token.
Every dollar figure in the app is what the same tokens would cost at Anthropic's published API
rates, which is the only way to compare usage across models, and each is rendered with a leading `~`
(a non-zero amount under a cent shows as `<$0.01` instead)
to say so. Events are priced at the rate in force at their own timestamp, so a session that predates
the end of an introductory pricing window keeps the rate that applied then. The panel's cost-side
split is summed from per-field costs computed the same way — each event's own timestamp, one field at
a time — rather than by re-pricing pooled totals, which is what keeps the four rows summing to the
total beside them once a rate has lapsed. Only the input and output rates per model are published; the
cache rates are derived from the input rate (1.25× for a 5-minute cache write, 2× for a 1-hour write,
0.1× for a cache read), so a model's numbers cannot drift out of agreement with each other.

## The credential model

Access is read-only, and that is a design commitment, not an omission. `Keychain` performs one
`SecItemCopyMatching` against the generic-password item for service `Claude Code-credentials`, parses
`claudeAiOauth.accessToken` and `expiresAt` (epoch milliseconds), and discards the refresh token —
the type it returns has no field to put one in. Nothing in the app writes, updates or deletes the
item.

The reason is that the item is shared with Claude Code. Refreshing a token means writing the new one
back into that item, so two processes refreshing on their own schedules race for it: whichever writes
last wins, and a write from here could clobber a token the CLI had just rotated. Claude Code is the
process that has to keep working, and losing its login is a sign-out this app has no way to repair,
so it does not compete for the write. What the server's exact token-rotation semantics are is not
something this code establishes; what it commits to is never writing. Instead:

- The Keychain is re-read on **every** poll rather than cached, so a token Claude Code has just
  rotated is picked up without a relaunch.
- An already-expired token means no request is made at all. There is nothing to gain from a
  guaranteed 401, and the fix is Claude Code writing a new token, which should show up within a
  minute. The panel says `Token expired` and tells you to run any Claude Code command. Expiry is
  inclusive: a token whose deadline is exactly now is treated as unusable, because the request would
  land after it.
- A 401 or 403 from a request that *was* made triggers one re-read before it is reported, since the
  token may have rotated mid-request. `LimitsClient` maps both statuses to the same unauthorized
  case, so both take that path. If the item has disappeared entirely in the meantime, the app says
  "not signed in" rather than "renew", because those need different actions from you.

Credential states are handled separately from transport failures. No request was made, so there is
nothing to back off from: the cached snapshot stays on screen, the normal cadence continues, and a
panel-open refresh is still allowed, which is how a freshly rotated token is picked up immediately.

## Privacy

One network call exists in the whole app: the `GET` to `api.anthropic.com/api/oauth/usage` described
above, carrying the token. No other host is contacted, there is no analytics or telemetry, and there
are no third-party dependencies that could add either. Transcripts are read from disk and aggregated
in process.

Four files are written under `~/Library/Application Support/ClaudeMeter`:

| File                 | Contents |
| -------------------- | -------- |
| `samples.jsonl`      | One line per successful poll: the timestamp, both window percentages, and both windows' reset timestamps. The dataset burn rate is fitted from. Pruned to eight days. |
| `scan-state.json`    | Per-transcript byte offsets and cumulative row counts, for incremental rescanning. |
| `events.json`        | The deduplicated transcript events, so a cold start does not re-read the whole corpus. |
| `last-snapshot.json` | The last successful usage reading, so a relaunch has something to show before the network answers. |

`events.json` includes each event's working directory and session id, so it describes your local
project paths. It never leaves the machine. Settings live in the app's own user defaults.

## Architecture

```
Sources/UsageCore/            pure logic; no SwiftUI, no AppKit
  Models.swift                shared value types: snapshots, events, aggregates, projections
  Paths.swift                 every filesystem location, with test overrides
  ISO8601.swift               the two timestamp shapes this app meets, and the JSON coders
  Keychain.swift              read-only credential access
  LimitsClient.swift          the usage endpoint and its defensive decoding
  TranscriptScanner.swift     incremental scan, dedup, and the persisted event cache
  SampleStore.swift           poll history (JSONL) and the offline snapshot cache
  Aggregates.swift            sessions, daily buckets, model/effort splits, time spent
  Pricing.swift               published rates and cost equivalence
  Projection.swift            reset detection, burn-rate fit, time-to-cap
  MenuBarLabelText.swift      the menu bar string, formatted here so it can be tested

Sources/ClaudeMeter/          SwiftUI, AppKit, Charts
  ClaudeMeterApp.swift        the MenuBarExtra scene and the always-visible label
  AppModel.swift              poll loop, adaptive cadence, backoff, health, aggregates
  Prefs.swift                 every UserDefaults key and default, in one place
  MenuBarIcon.swift           the ring, rasterised and memoised
  PanelView.swift             the panel; owns the sections and the stats grid
  MeterRow.swift              one limit window: bar, reset line, projection line
  SparklineView.swift         utilization over the current window, with the forecast
  DailyBarsView.swift         tokens per day
  SessionsSection.swift       the recent-sessions list
  ShareRowsView.swift         proportion rows, plus the number formatting the views share
  SeverityStyle.swift         the single severity-to-colour mapping
  SettingsView.swift          the settings form
  SettingsWindowController.swift  owns the settings NSWindow
  Notifier.swift              threshold and pace alerts, once per window

Tests/UsageCoreTests/         swift-testing suites, plus synthetic endpoint payloads
```

`AppModel` is the only place that touches the network, the Keychain or the filesystem, and it is
`@MainActor` out of necessity rather than convenience: `SampleStore` and `TranscriptScanner` are
plain classes with unsynchronised mutable state and no `Sendable` conformance, so single-actor
confinement is what makes them safe to use at all. The one piece of work that cannot run on the main
actor, the pass over the whole transcript corpus, is detached, owns its own scanner instance, and
hands back only value types.

## Non-obvious engineering decisions

These look like mistakes if you do not know why they are there.

### The menu bar ring is a rasterised bitmap, not a live SwiftUI shape

`MenuBarExtra`'s label only reliably renders `Text` and `Image`, so the ring is drawn once through
`ImageRenderer` and handed over as an `NSImage`. It is deliberately not a template image: the status
bar re-tints templates monochrome, which would throw away the exact amber and red the severity
colour exists to communicate.

A bitmap cannot re-resolve semantic colours, so everything it bakes in has to be part of its cache
key: the rounded percentage, the severity, the cap dot, the light/dark appearance, the backing scale
factor of the sharpest attached screen, and the current system accent colour. Drop any one of them
and you get a stale ring — a green ring on a window that crossed 90, a black track after a flip to
dark mode, a soft ring after a Retina display is attached, or an icon that alternates between two
accent colours as the number moves. Appearance takes care of itself: the label reads
`@Environment(\.colorScheme)`, and that read is what invalidates it when the menu bar flips light or
dark, so the ring is re-rasterised for the new appearance immediately. It is read rather than applied
as an `.id`, which would re-create the label and its timer subscription instead of just redrawing it.
An accent change is not pushed at all, so it is picked up by the 30-second ticker the countdown
format needs anyway: each tick re-asks for the image, so a new accent reaches the ring on the label's
next tick. The key space is small and bounded, so nothing is ever evicted.

One measured detail is worth repeating: `ImageRenderer.nsImage` ignores its `scale` and returns the
same bitmap at scale 1, 2 and 3, so the pixels come from `cgImage` instead and the point size is
pinned when the `NSImage` is constructed. That is what keeps a 2× ring an 18-point item instead of a
36-point one.

### The menu bar tracks the 5-hour window, never the most constrained one

Showing whichever window is furthest along sounds more useful and is not: a weekly figure barely
moves, so the icon would sit unchanged for hours and stop being a live signal. The weekly window
lives in the panel, where a number that changes slowly is fine.

### Settings is an AppKit window, not a SwiftUI `Settings` scene

The app runs with `.accessory` activation policy, and an accessory app cannot reliably take focus.
With a `Settings` scene, `SettingsLink` would fire, the window would open, and nothing would bring it
forward — it stayed behind other windows, or on whichever Space it was last used on. From the user's
side, clicking the gear did nothing, some of the time. Coaxing the scene's window after the fact
worked only intermittently, because the scene decides when the window exists and whether the click is
honoured at all.

`SettingsWindowController` owns an `NSWindow` instead, created on demand and shown by code that runs
on every click, with `activate(ignoringOtherApps:)`, one bounded retry on the next turn of the run
loop, and `orderFrontRegardless()` as a last resort so the worst case is a window you have to click
to focus rather than an invisible one. It also recentres a remembered frame that lies off every
attached screen, since a frame saved on a display that is no longer connected would otherwise strand
the window permanently.

The one thing that genuinely requires a policy switch is focus: accessory apps are not meant to own
key windows, so the app becomes `.regular` while the settings window is up and reverts on close. The
visible cost is a Dock icon for exactly as long as that window is open. That is the usual trade menu
bar apps make, and it is worth it for a window that actually appears.

The window is also sized explicitly instead of being left to infer its own height, because neither
automatic answer is usable: left alone, `NSHostingController` reported a 28-point height for a
grouped `Form` — a title bar and nothing else — while `preferredContentSize` reported the form's
full expanded height, close to a whole screen.

### The poll cadence tunes itself, and is not a preference

The usage endpoint is rate-limited per account and that budget is shared with Claude Code itself, so
the app cannot know how much of it is already spent. It starts deliberately slower than the endpoint
strictly needs, then earns speed:

| Behaviour            | Value |
| -------------------- | ----- |
| Starting interval    | 180 s |
| Floor                | 90 s  |
| Ceiling              | 15 min |
| On a 429             | interval × 2, remembered |
| After 12 clean polls | interval × 0.8, down to the floor |

Both directions are multiplicative — doubling on refusal, giving back a fifth after a clean run —
so it is quick to retreat and slow to advance, which is what
stops it oscillating in and out of the limit. The learned interval is persisted, so a limit
discovered today is not rediscovered tomorrow, and it is clamped on read so a value written by an
older build or a hand-edited plist cannot make the app poll in a hot loop or stop polling
altogether. Settings shows the current cadence read-only, with an explanation, because a reading a
few minutes old otherwise looks like a stuck app rather than a deliberate choice.

Several details fall out of this:

- Opening the panel refreshes only if the last successful poll has gone stale, where stale means 0.9
  × the current interval. A fixed gate does not track the cadence: at 20
  seconds it fired on nearly every open, spending a request to re-fetch what the loop had just
  refreshed.
- A failing poll freezes the "last update" timestamp, so the staleness gate alone stops holding and
  every panel presentation would fire another request that the backoff or an honoured `Retry-After`
  had explicitly deferred. A separate "not before" gate exists for exactly that.
- Concurrent callers are coalesced onto one request. The loop and a panel-open refresh can arrive
  together, and two simultaneous polls would append two samples a millisecond apart, which the
  burn-rate fit reads as an infinite slope.
- The transport backoff's first rung is the current cadence, not one second, so a network blip never
  retries faster than the pace the app has settled on. It caps at 300 seconds.
- `Retry-After` is honoured as sent but bounded to an hour, because a header asking for a day would
  otherwise park the app until it is relaunched. This endpoint sends `Retry-After: 0` while
  rate-limiting, which means "no delay supplied" rather than "retry immediately"; taking it literally
  is how you stay throttled, so a non-positive value falls back to the app's own schedule and the
  panel reports the app's next attempt rather than the server's header.

### Transcript rows are deduplicated, and merged with element-wise maximum

Assistant rows repeat in the transcripts, so summing them naively over-counts tokens substantially.
Rows are keyed on `(requestId, message.id)` and repeats are merged rather than added. The merge takes
the element-wise maximum of each token field, which is neither a sum nor first-wins for a reason: a
minority of repeated keys carry differing payloads, typically a streamed row followed by its final
form, so the largest value of each field is the true one, and identical repeats collapse to a no-op.

Duplicates of a row already counted in an earlier pass turn up in *later* bytes, which is why byte
offsets alone are not sufficient state — the deduplicated event map is persisted too. The two writes
are ordered, and the order is load-bearing: the event cache is written before the offsets, because
if the process dies in between, offsets ahead of the cache would silently skip bytes whose events
were never saved (a permanent under-count), whereas a cache ahead of the offsets merely re-reads
bytes it already holds, which the maximum-merge makes idempotent. For the same reason, adopting a
stored offset set without a trustworthy event cache is refused outright.

Settings surfaces the ratio of rows read to distinct requests, so the app's totals being lower than a
naive sum over the same files has a visible explanation.

### The 5-hour window is rolling, so a falling percentage is not a reset

Utilization can slide a long way down purely by ageing out, with `resets_at` drifting forward the
whole time. Treating any decline as a reset would chop the sample series into fragments and produce
nonsense fits. Only a cliff of at least 20 percentage points between consecutive polls, or a gap
longer than the window itself, starts a new series. A negative burn rate is a legitimate result, not
an error condition, and the chart never smooths or clips a decline into a rise.

The same rolling behaviour is why `resets_at` is read from the snapshot on every projection rather
than remembered, and why the confidence band is hidden when its half-width exceeds 40 points: a band
spanning the whole chart says nothing worth drawing.

### Notifications are keyed per window instance

An alert key is the window kind plus the reset timestamp the user was told about, and stored keys are
matched by *kind* rather than by exact timestamp. Because the 5-hour window is rolling, an exact
match would mint a fresh key on every poll whose reported reset had moved by even a second, and post
a banner on every poll — precisely the storm the fired set exists to prevent. Matching by kind means
the suppression lapses exactly when the window it referred to is over, and a genuinely new window can
alert again.

Keys whose reset has passed are dropped on each evaluation, which is both the prune and the "this is
a new window" test, so the set holds at most one key per window kind and cannot grow with the age of
the install. A window with no reported reset, or one whose reported reset has already passed, gets a
synthetic cooldown instead of a stamp in the past that would expire immediately; an implausibly
distant reset is capped so a corrupt payload cannot silence alerts indefinitely. Changing the
threshold clears the fired set, because a key identifies a window and not a threshold, and lowering
the threshold has to be able to alert on a window that already notified under the old one.

Alerts are evaluated only after a poll, never after a transcript scan: a scan changes token
aggregates but never the utilization an alert is about. Notifications default to off and the only
authorisation request in the app is the settings toggle being switched on, so a default install never
raises a system permission prompt. A delegate is installed before posting, because opening the panel
activates the app and macOS otherwise suppresses banners for the active app — the alert would be
swallowed exactly while you are looking at your usage.

### The transcript scan is detached and incremental; aggregates are not

The first pass reads the whole corpus, which must never block panel presentation, so it runs
detached at utility priority with its own scanner instance and returns only value types. Later passes
re-open only files that have grown past their stored offset, so a rescan every five minutes costs
close to nothing. Files are streamed line by line from that offset, and a trailing fragment with no
newline is deliberately left unconsumed because the CLI may still be writing it. A file that has
shrunk below its stored offset was truncated or rotated, so scanning restarts at zero for that file,
but its cumulative row count is not reset — those rows produced events that are still held.

Two `autoreleasepool` scopes inside the read loop are what make it actually streaming, not
merely incremental. `read(upToCount:)` hands back an autoreleased buffer and `JSONSerialization`
builds an autoreleased object graph per line, and a synchronous scan drains no pool of its own, so
without them every chunk and every parsed row would stay resident until the whole pass returned:
peak memory would scale with the size of the corpus instead of staying flat. Draining per chunk caps
residency at one chunk, and draining per line caps the parsed graph at one row.

Aggregates work the other way round. They are pure functions of the in-memory event array, so moving
the idle-gap slider recomputes sessions, daily buckets and usage hours instantly and triggers no
rescan at all. Poll samples take the same care in reverse: a sample is appended to the in-memory
series even when the file write fails, because persistence is allowed to degrade but the burn-rate
fit is not — an unwritable support directory would otherwise pin every projection at `estimated` for
the life of the process.

### Wall-clock hours and agent-hours answer different questions

The transcripts carry no duration fields, so time spent is inferred from the spacing of message
timestamps, and the gap that ends a stretch is the user-visible setting. Wall-clock hours union
active stretches across *all* sessions before summing, so two projects worked at the same time count
once: clock time cannot be double-spent. Agent-hours use no gap rule at all, because a sub-agent runs
continuously from spawn to completion, so each agent's span is simply its last message minus its
first, and those spans are summed rather than unioned. Twenty agents running for thirty minutes is
ten agent-hours, which is why agent-hours can exceed the elapsed wall-clock time. Both figures are
marked as approximate in the UI, for the same reason the cost figures are.

## Tests

`make test` runs the `UsageCore` suites with swift-testing: dedup and incremental-scan behaviour,
aggregate rollups, pricing including the introductory-window boundary, reset detection and the
burn-rate fit, sample-store persistence and its damage recovery, credential parsing, endpoint
decoding, and the menu bar string. The decoding suite runs against two synthetic payloads shaped like
the real response rather than captured traffic: a full one and a sparse one. Both carry top-level keys
the app has never seen; the sparse one is deliberately hostile on top of that, with a missing window
and unrecognised `kind`, `group` and `severity` values, which is the case worth having a fixture for.
None of the suites touch the network, the Keychain, or a real `~/.claude` directory — `Paths` exposes
overrides for the support directory and the transcript root, which is what the `--no-parallel`
requirement above is about.

`UsageCore` imports neither SwiftUI nor AppKit. Anything with a decision in it lives there.
