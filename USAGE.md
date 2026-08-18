# Using ClaudeMeter

This document assumes the app is built and running. For what it is, how to build it, and how it
handles credentials, see `README.md`.

ClaudeMeter has three surfaces: the menu bar item, the panel that opens when you click it, and a
settings window reached from the panel's gear button. Everything it shows comes from two places —
the usage endpoint at `api.anthropic.com`, polled on a cadence you set and the app adapts, and the
local Claude Code transcripts under `~/.claude/projects`. Which source a number came from decides
how it behaves when the network does not answer, so the distinction is worth keeping in mind while
reading the panel.

## Reading the menu bar

The menu bar item is a ring plus, depending on your chosen format, some text. It always tracks the
**5-hour window**, never the most constrained one. A weekly percentage moves so slowly that an icon
driven by it would sit still for days, which makes it useless as a live signal; the weekly window
lives in the panel instead.

### The four formats

Set these under Settings → Menu bar.

| Setting label | Example | What it shows |
| --- | --- | --- |
| `42% → 63%   (now and projected)` | `42% → 63%` | Current utilization and the projection at the window's reset. This is the default. |
| `42%   (just the percentage)` | `42%` | Current utilization only. |
| `42% · 2h41m   (percentage and time to reset)` | `42% · 2h41m` | Current utilization and time until the window resets. |
| `Icon only` | *(ring alone)* | No text. |

Some details of how those strings are built:

- The percentage is rounded to the nearest point, and it is the same rounding the ring is drawn
  from, so the number and the fill never disagree. Negative utilization — which the API can in
  principle report — clamps to `0%`.
- The pace arrow is suppressed when the projection lands within a point of the current value, and
  also whenever the two would render as the same string. `42% → 42%` says nothing, so the format
  falls back to the bare percentage until there is a real difference to show.
- The countdown is truncated, not rounded, so it never claims more time than is left, and it
  ignores seconds. Anything under a minute — including a window whose reset has already passed —
  reads `now`. Spans of a day or more read as `3d2h`.
- With no usable percentage, every text format renders `—` rather than a bare countdown.

### The ring, and the cap dot

The ring fills clockwise from twelve o'clock in proportion to the 5-hour utilization. Its colour is
the window's severity:

| Colour | Severity | Meaning |
| --- | --- | --- |
| System accent | `normal` | Nothing to act on. |
| Orange | `warning` | Getting close. |
| Red | `critical` | Close to or at the limit. |

Severity comes from the API's own classification when the response carries one for that window;
otherwise the app classifies it numerically, with the boundaries at 70% and 90%. The fallback turns
on whether the response carried a matching `limits[]` entry for that window at all — not on whether
that entry had a severity — and per-model scoped entries are excluded from the match. The two need
not agree, which is why the API's value wins where it exists.

A **filled dot in the centre of the ring** means the 5-hour window is on pace to reach 100% *before*
it resets — the fitted burn rate crosses the cap earlier than the reset time. It is the one piece of
forecast information in the menu bar, and it is the same condition that drives the red `hits 100% in
…` line in the panel.

The ring is a rasterised bitmap, not a live SwiftUI shape, because `MenuBarExtra` only reliably
renders `Text` and `Image` in its label. It is deliberately not a template image either: the status
bar re-tints template images monochrome, which would throw away the orange and red the severity
colour exists to communicate. One consequence is visible in use: a bitmap cannot re-resolve a
semantic colour after the fact, so the ring has to be redrawn whenever anything it baked in changes.
A switch between light and dark mode invalidates the label immediately, but nothing pushes a change
of system accent colour, so a new accent reaches the ring on the label's next tick, roughly every
thirty seconds — the timer allows a few seconds' latitude, so it is not a guaranteed bound. Nothing is broken if the ring keeps the old accent for a few seconds after you change it.

An **amber symbol beside the ring** means the number next to it is not live. The ring draws the last
percentage it was given and goes on drawing it, so without this a meter that stopped an hour ago
looks exactly like one that updated a second ago. The symbol says which kind of stopped it is, and
hovering the item spells it out:

| Symbol | Meaning | What clears it |
| --- | --- | --- |
| Lock | ClaudeMeter needs Keychain access | Open the panel and press *Authorize* |
| Hourglass | The token has aged out | Run any `claude` command |
| Warning triangle | The token cannot be renewed by anybody | Sign in to Claude Code again |
| Person with a question mark | Not signed in | Sign in to Claude Code |
| Crossed-out Wi-Fi | Cannot reach the usage endpoint | Usually nothing; it retries on its own |

The badge is composited into the same bitmap as the ring rather than added beside it as a second
image. `MenuBarExtra` renders the first `Text` and the first `Image` in its label and silently drops
what follows, so a sibling badge is simply never drawn — the sort of thing only a screenshot tells
you.

The ring carries an accessibility description of the form `Claude 5-hour usage 42 percent`, with
`, on pace to run out before it resets` appended when the cap dot is showing. When a badge is
showing, that description is replaced by the badge's own sentence, since the state of the reading
matters more than its value.

## Reading the panel

Click the menu bar item to open the panel. Closed, it is a single narrow column. Opening the
`Last 30 days` breakdown — or any two of the other sections — switches it to two columns, with that
breakdown in the right-hand one. It carries the daily chart and four proportion groups, so in a
single column it runs past the bottom of the screen, and a menu bar panel has nowhere to overflow
to: it is simply clipped, and the footer becomes unreachable.

If the menu bar item sits far enough right that the wider panel has nowhere to grow into, the panel
expands leftward instead: its right edge stops a little short of the screen edge and its left edge
keeps going, in the same motion as the resize rather than a jump at the end of it.

The panel will also never exceed the height of the screen it hangs from. If the content still does
not fit — a long session list on a short display — it scrolls, and only then; a panel that fits
shows no scroll affordance. The sections remember whether you left them open, so it reopens in the
shape you last used.

Opening the panel refreshes the limits only if the last successful poll has gone stale, where stale
means older than nine tenths of the current cadence. Opening it twice in quick succession does not
fire two requests. The refresh button in the footer is the way to override that gate; the loop, the
panel-open check and that button are the only things that poll.

While the panel is open, relative strings (`resets in …`, `Updated 12s ago`, `23m ago`) re-render
every five seconds.

### The two meters

Each window — 5-hour and Weekly — gets a row with a title, a percentage, a capsule bar, and up to
three lines of text beneath it. Lines that would say nothing are omitted rather than shown empty,
so a row with fewer lines is normal, not broken.

**The reset line.** `resets now` when the reset is a minute or less away, `resets in 2h41m` while it
is under twelve hours out, and `resets Fri 3:20 PM` once a countdown stops being useful. The date
format follows your locale.

**The projection line.** `↗ 12 pts/hr · 63% at reset ± 4`, where:

- The rate clause is the fitted burn rate in percentage points per hour. `↗` is rising, `↘` falling.
  Rates below half a point per hour are suppressed, because the API reports utilization coarsely and
  anything that small is fit noise rather than a trend. Below ten points an hour the rate carries one
  decimal, since the difference between 0.6 and 1.4 points an hour is the difference between coasting
  and capping before the reset.
- `63% at reset` is the projection carried forward to the reset time. It is dropped when it lands
  within a point of where the window already is.
- `± 4` is the half-width of a 95% confidence band on that projection. It appears only when the fit
  supports one and the band is narrow enough to mean something; a band wider than 40 points is
  hidden rather than drawn.

**The activity line.** `≈5h active of 14h left · busy now ×2.4 · 3 agents running`, in smaller grey
type under the projection. It appears only when the forecast is not simply the reading divided by the
clock, and each clause appears only when it has something to say:

- `≈5h active of 14h left` — how much of the time before the reset this account usually works. Four
  o'clock on a Sunday morning is not an hour anybody spends a rate limit in, and the forecast no
  longer prices it as if it were. Absent when the horizon is about as busy as an average stretch of
  the same length, which is what a whole week always averages out to.
- `busy now ×2.4` or `quiet now ×0.4` — how the last half hour compares with what this account
  usually does at this hour. It decays back to normal over roughly as long as the current stretch has
  already run, so a burst moves the five-hour forecast a great deal and the weekly one by about a
  point.
- `3 agents running` — sub-agents that have produced a message within the idle gap. Work already
  handed to a sub-agent keeps spending after the last message the app has seen, so their presence
  holds the burst open longer.

**The cap line.** `hits 100% in 1h20m`, in red with a warning triangle, appears when the window is on
pace to exhaust before it resets. This is the same condition as the menu bar's cap dot.

An `Extra usage spend limit reached` line appears beneath the meters when the API reports that state.

Before the first reading has arrived, both meters are still drawn — `—` where each percentage goes,
an empty bar, and no reset or projection lines — and `Waiting for the first reading…` appears as an
extra line beneath them. The meters are hidden altogether only when the app has never had a reading
*and* is not live; see the offline states below.

### `estimated` versus `measured`

A small `estimated` badge sits beside the projection line — or beside the cap line, when the
projection line is suppressed — whenever the burn rate did not come from the poll series.

There are two ways the app can arrive at a rate:

- **Measured.** A least-squares fit of utilization against time over the trailing 45 minutes of poll
  samples. It requires at least four samples spanning at least ten minutes. The 5-hour window prefers
  this whenever it has one; the weekly window never uses it, because a slope measured over 45 minutes
  and carried across 168 hours is nonsense — on real data it projected 171% for a week that finished
  at 23%. No badge is shown.
- **Paced.** The utilization the API reports, divided by how much of the window has been spent and
  carried across what is left of it. This needs no history at all and it is account-wide by
  construction, so it sees usage from other machines, the desktop app and claude.ai. It is the
  weekly window's normal path, and the 5-hour window's fallback when the series is too thin to fit —
  where it is badged `estimated`, since there it is the weaker of two available answers.

Pacing does not divide by hours. It divides by how much of the window's *activity* has been spent,
where activity is this account's own rhythm: spend by hour of day times spend by weekday, measured
over the last four whole weeks of transcripts and normalized so an average hour is worth 1. Nobody
spends a rate limit while asleep, so a Friday-evening reading is not carried across two nights as
though they were two working days. On top of that the forecast reads the present: the poll series
says whether the limit is climbing faster than the window's own pace expects, and the transcripts say
whether this machine is mid-burst and how long the stretch has run. The activity line under the
projection reports both.

All of it is shrunk toward plain wall-clock pacing when the evidence is thin. Under three complete
days of transcripts there is no profile at all and the forecast is exactly the flat arithmetic; the
shape strengthens as the days accumulate, and it can never move the pace by more than a factor of
four in either direction.

In practice you see `estimated` on the 5-hour row for the first several polls after a launch. The fit
only looks at the trailing 45 minutes, so the persisted series helps after a quick restart but not
after the app has been closed for hours: in that case the badge returns until the series refills.

### The rolling 5-hour window

The 5-hour window rolls rather than resetting on a fixed schedule: its `resets_at` drifts forward as
old usage ages out. Three consequences look like bugs and are not.

1. **A falling percentage is normal.** Utilization drops whenever usage ages out faster than it
   accrues, so `↘` is a legitimate reading and the chart shows the decline rather than smoothing it
   into a rise.
2. **The reset time moves.** The app re-reads `resets_at` from every poll instead of remembering it,
   because a remembered value would be wrong within minutes.
3. **A decline is not treated as a reset.** The app only starts a new series when utilization drops
   by at least 20 points between consecutive polls, or when the gap between polls is longer than the
   window itself. Without that rule an ordinary rolling decline would be read as a reset, and both
   the chart and the burn-rate fit would restart on nothing.

### The collapsible sections

**Last 5 hours** plots utilization for the 5-hour window from the poll samples, with the projection
continued to the reset as a dashed line and its confidence band as a faint cone. The x-axis
deliberately runs past *now* to the reset time, because the question is where the window is heading.
The dashed line follows the same activity clock the forecast is paced on rather than running straight
to its endpoint, so on the weekly chart it levels off overnight and climbs again in the morning; the
cone opens on that clock too.
The section is absent entirely until the first poll has been recorded. This is the only section
built from poll samples; everything below it comes from the transcripts.

**Recent sessions (N)** lists work stretches, most recent first: the project name (the last path
component of the session's working directory), how long ago it started, how long it ran, message
count, tokens in and out, and a cost equivalent. Input and output tokens are shown separately rather
than as one total, because they differ by orders of magnitude and price differently, so a single
figure would hide which one moved. At most eight rows are drawn and the remainder is acknowledged as
`+N older`.

The count in the label can exceed the number of transcript sessions. A single transcript session id
can span days of on-and-off work, so the app splits one session wherever the pause between messages
exceeds the idle gap from Settings, and each stretch becomes its own row.

**Last 30 days** holds a bar chart of total tokens per day, zero-filled so an inactive day is a real
gap rather than a missing category. Today's bar is drawn at full strength and the settled days
recede slightly; without that, the partial current day would read as a collapse in usage. Under the
chart are the range totals, and then four proportion splits.

The splits are labelled `all recorded`, and that label is load-bearing: the bars above them cover the
last 30 days, but the splits run over every event the app is holding. They are not the same period.

- **Models** — share of tokens per model. The top five rows are shown, but the fractions are taken
  over every model, so a truncated list cannot imply that the shown rows account for everything.
- **Effort** — the same, split by the effort setting on each request. Requests that carried no effort
  field form their own `Unset` bucket rather than being folded into a default level.
- **Tokens** — the input, cache-read, cache-write and output sides, as shares of the token count.
- **Cost share** — those same four sides priced, as shares of the cost equivalent.

### Token volume and cost rank very differently

The Tokens and Cost share splits are the same four quantities in the same order, and they usually
look nothing like each other. That is the point of showing both.

Cache reads normally dominate the token count and bill at a tenth of the fresh-input rate. Output is
a small fraction of the volume and bills at several times the input rate. So the row that is largest
by tokens is usually not the row that is largest by cost, and the panel says so in a note under the
token split. Reading the token split as if it were a spend breakdown is the specific mistake the two
adjacent bars exist to prevent.

The cost split is built from per-event, per-field costs rather than from pooled totals: each event's
four sides are priced separately at that event's own timestamp, and those per-field costs are carried
per model and added up for the split. The cache rates are multiples of that model's input rate and output has its own published rate, so
pricing pooled tokens at one blended rate would be wrong. Pricing each event at the rate in force when
it happened is also what keeps the split honest across a rate change — the four rows add up to the
pooled cost equivalent for the same events, which re-pricing pooled totals at today's rate would not.
Historical usage keeps the rate that applied at the time.

Cost figures are equivalent spend at published API rates, marked with a leading `~` — except a
non-zero amount under a cent, which reads `<$0.01`. Subscription
usage is not billed per token, so none of them is a bill. A model the app has no published rate for
contributes its tokens to the token splits but nothing to the cost splits.

### What the statistics do and do not cover

The meters and the statistics have different scopes, and it is the first thing that looks wrong when
it is not.

The **meters are account-wide**. The 5-hour and weekly limits are billed against the whole
subscription, so anything on the account moves them: Claude Code on another machine, claude.ai in a
browser, the desktop app, mobile. The endpoint returns no per-device breakdown, so the app cannot
attribute the usage either.

Everything else — tokens, sessions, the daily chart, the model and effort splits, cost equivalents,
wall-clock and agent-hours — is read from `~/.claude/projects`, which is written **only by Claude
Code, and only on this machine**. Work done from a browser, from a phone, or on another Mac never
appears there.

Which means a high meter over quiet statistics is informative rather than broken: the limit went
somewhere this app cannot see. If you want the statistics to account for a second machine, there is
no supported way to do it — the transcripts are local files, and the app does not merge them.

### The statistics grids

**Today** holds four tiles. `Tokens in` is everything sent — fresh input plus cache reads and cache
writes — and excludes generated tokens. `Tokens out` is generated tokens only. `Sessions` counts
stretches that started today, using the same splitting rule as the sessions list, so one transcript
session picked up again after a long pause counts more than once. `Cost equiv` is the day's cost
equivalent.

**All recorded activity** holds three tiles.

`Cache hit` is the share of the *input side* served from cache: cache reads over cache reads plus
cache writes plus fresh input. Output tokens are excluded, because they are generated rather than
read, and including them would make the ratio a function of response length instead of cache
behaviour.

`Wall clock` and `Agent hours` both answer "how much time", and they answer different questions.
Neither is measured. The transcripts carry no duration fields at all, so both are inferred by
clustering message timestamps, which is why both carry a `~` prefix. `<1m` is already an
approximation and is left unmarked.

- **Wall clock** is the union of active stretches across every session. A pause longer than the idle
  gap ends a stretch. Because it is a union, two projects worked at the same time count once —
  this is clock time, and clock time cannot be double-spent.
- **Agent hours** is the sum of per-sub-agent spans, from each agent's first message to its last. It
  uses no gap rule, because a sub-agent runs continuously from spawn to completion. It reads `None`
  when the transcripts contain no sub-agent activity, rather than `<1m`, which would suggest a brief
  burst of it.

**Agent hours can exceed wall-clock hours, and that is the expected result, not an error.** Agents
run in parallel, so twenty agents running for thirty minutes is ten agent-hours inside half an hour
of clock time. Reading the two together tells you how much concurrency you got: wall clock is how
long you were at the keyboard, agent hours is how much work happened while you were.

### The footer

The left of the footer says how fresh the limit numbers are — `Updated just now`, `Updated 12s ago`,
`Updated 3m ago`. It reports seconds rather than rounding to minutes, because at a multi-minute
cadence a line that said "Updated now" for the whole interval would defeat the purpose. A spinner
appears beside it while a transcript scan is running. On the right: the circular arrow refreshes now
(<kbd>⌘R</kbd>), the gear opens Settings (<kbd>⌘,</kbd>) and `Quit` exits (<kbd>⌘Q</kbd>).

The refresh button asks for both halves at once — a poll for the meters and a transcript rescan for
everything below them — and ignores the staleness gate that holds back an ordinary panel open. What it
will not do is jump a queue the app has already committed to: while a failed poll's backoff or an
honoured `Retry-After` is still running, the button is disabled and its tooltip says how long is left,
because a request inside that window is one the server has already refused and every refusal widens
the cadence for everything else. It comes back by itself within a few seconds of the wait elapsing.

Before the first successful poll the line reads `Scanning…` or `No reading yet`.

## Settings

The gear in the panel footer opens the settings window. Every control writes to this app's user
defaults; nothing here is sent anywhere.

| Section | Control | Effect |
| --- | --- | --- |
| Menu bar | Format | Which of the four menu bar formats is drawn. |
| Usage hours | Idle gap (5–30 min) | The pause that ends an active stretch. Drives the sessions list, the `Sessions` tile, and `Wall clock`. Does not affect agent hours. |
| Refresh | Check limits every (90 s, 2, 3, 5, 10, 15 min) | The cadence to aim for. A rate limit can still widen it; a second row appears showing the effective one when it has. |
| Credentials | Token | Paste a token from `claude setup-token` to give ClaudeMeter its own credential, or forget one already set. Optional. |
| Alerts | Notify me when a limit is running out | Master switch for notifications. Off by default. |
| Alerts | Alert at N% of a window (50–99, steps of 5) | Threshold crossing that triggers an alert. |
| Startup | Launch ClaudeMeter at login | Registers or unregisters the app as a login item. |

A few of these behave in ways worth knowing.

**Idle gap** recomputes instantly. The aggregates are a pure function of events the app is already
holding in memory, so dragging the slider re-derives sessions and wall-clock time without rescanning
the transcripts. The current wall-clock figure sits in the same section so you can see what the
setting is doing. The bounds are not arbitrary: below five minutes an ordinary pause between prompts
fragments one sitting into many, and above thirty an evening off reads as continuous work.

**Refresh sets a target, not a guarantee.** Choosing a cadence takes effect at once — the app does not
wait out the interval already in flight — and it clears whatever interval the app had learned, so a
cadence a rate limit widened yesterday is not still in force after you have asked for a faster one.
What it cannot do is overrule the endpoint: a 429 still widens the interval past your setting, and the
app works back down to it. Whenever the two differ, a `Currently` row shows what the app is actually
polling at and the text below says why. See the section on the cadence for the rest.

**ClaudeMeter never writes Claude Code's credential, and never renews it.** There used to be a
setting offering to, and it was removed rather than defaulted off, because neither of its two
outcomes was acceptable. macOS keeps a list on each Keychain item of the programs allowed to read
it without a password, and writing an item's data rebuilds that list around whoever wrote it —
measured here against a throwaway item seeded with three identities, both the modern and the legacy
write API collapsed it to the writer alone, so there is no way to write and leave the list intact.
Renewing also means spending Claude Code's refresh token, which the endpoint rotates: the CLI's
stored copy stops working the moment ClaudeMeter spends it. So saving the renewal locks `claude`
out of its own credential, and not saving it signs `claude` out altogether. Declining to renew is
the only branch that does neither.

The cost is that when the access token ages out, the panel shows `Waiting for Claude Code` until
you next run any `claude` command — which also happens to be the only time your usage is changing.
Everything drawn from your transcripts carries on regardless.

**A token of ClaudeMeter's own is the way to avoid Keychain prompts entirely.** The one thing the
read-only arrangement cannot dodge is the reverse eviction: when `claude` renews, *it* writes the
item, and that drops ClaudeMeter off the permitted list. ClaudeMeter never raises the resulting
dialog on its own — the read is made with system dialogs suppressed, so it fails cleanly and the
panel shows `Keychain access needed` with an *Authorize…* button you press when it suits you.

To stop even that, run `claude setup-token` and paste the token into Settings ▸ Credentials.
It goes into a Keychain item ClaudeMeter creates and is the sole writer of, so nothing ever resets
its permitted list, no dialog can arise, and Claude Code's own credential is never read at all.
The token is checked against the usage endpoint before it is accepted, so a wrong paste is
reported straight away.

**Alerts request permission only when you switch the toggle on.** That is the app's only
authorisation request, so a default install never raises a system permission prompt. If the request
is refused, the toggle switches straight back off and an explanation with an `Open Notification
Settings` button appears. That warning is not hidden behind the toggle, because the toggle is exactly
what turns itself off in that case.

**Launch at login** reflects the real login-item state rather than a stored boolean. If macOS wants
the item approved, an `Open Login Items` button appears. A note reading `Available once ClaudeMeter
is running from a built .app bundle` appears beneath the toggle when the login-item status comes back
`notFound` — macOS reporting no login item it could register, which is what a bare executable run out
of `.build` looks like to it. The app does not test for a bundle itself; it shows what the system
reports. A registration that fails for any other reason surfaces the system's own error text instead.

The footer of the settings window states where state lives and repeats the credential guarantee: the
OAuth token is never sent anywhere but `api.anthropic.com`, and Claude Code's credential item is
only ever read, never written. The token is held in memory between polls rather than re-read each
time, and the app notices Claude Code renewing by checking the item's modification date — an
attributes-only read that decrypts nothing and can raise no dialog. When the transcripts contain duplicate rows — they normally do — a line
reports how many times the average request was written, which is there to explain why ClaudeMeter's
token totals are lower than a naive sum over the same files. Duplicate assistant rows are common in
the transcripts, and adding them up over-counts tokens substantially, so the scanner keys rows on
`(requestId, message.id)` and takes the element-wise maximum of each token field on a collision
rather than summing. The maximum, not first-wins: a minority of repeated keys carry a streamed
partial followed by its final form, and the largest value of each field is the true one.

The settings window is a plain `NSWindow` owned in AppKit rather than a SwiftUI `Settings` scene.
This is intentional. The app runs as an accessory app so it has no Dock icon, and an accessory app
cannot reliably take focus — with the scene, clicking the gear would open a window that nothing
brought forward, so it stayed behind other windows or on whichever Space it was last used on. From
the outside that is "clicking the gear does nothing, sometimes". Owning the window means the code
that shows it runs on the click, every time. Its position and size are remembered between launches,
and a window whose remembered frame lands off every attached screen — a display that is no longer
connected — is recentred rather than left unreachable.

## Alerts

Alerts are evaluated after each successful poll, never after a transcript scan: a scan changes token
aggregates but not the utilization an alert is about. Two conditions can fire:

1. **On pace to run out.** The window is projected to reach 100% before it resets. The body gives the
   rate and how long until the cap.
2. **Threshold crossed.** Utilization is at or above your configured threshold. The body gives the
   reset time.

**At most one notification per window instance**, however many polls that window survives, and the
pace alert outranks the threshold alert when both apply, because running out before the reset is the
more actionable of the two.

The suppression is keyed per window rather than per poll or per threshold, and the key is the
window's reset time, because that is a limit window's only identity. Matching is by window *kind*
against the stored key, not by exact timestamp equality — the 5-hour window is rolling, so its
reported reset creeps forward continuously, and an exact match would mint a fresh key on every poll
and post a banner every cadence. The stored key is the reset you were told about, so suppression
lapses precisely when that window is over and a genuinely new window can alert again. A window that
reports no reset time, or one whose reset has already passed, gets a synthetic cooldown instead,
since without a future reset there is no window identity to suppress on.

Changing the threshold clears the fired set. A key identifies a window, not a threshold, so lowering
the threshold has to be able to alert on a window that already notified under the old setting.

Banners are requested explicitly through a notification-centre delegate. Opening the panel activates
the app, and macOS suppresses banners for the active app unless a delegate asks for them, so without
this the alert would be swallowed exactly while you were looking at your usage.

## When the API is unavailable

The panel shows a notice at the top and adjusts what it trusts. There are four states:

| State | Notice | What it means |
| --- | --- | --- |
| Live | none | Last poll succeeded. |
| Offline | `Offline since 3:20 PM` (or `Can't reach the usage API`) | The last poll failed. The reason and the time of the next attempt are in the notice. |
| Sign in again | `Sign in again` | Credentials are present but beyond renewal — the refresh token has expired, been revoked, or was never there. |
| Not signed in | `Not signed in` | No usable Claude Code credentials in the Keychain. |
| Waiting for Claude Code | `Waiting for Claude Code` | The stored token has aged out. ClaudeMeter never renews Claude Code's token, because spending it retires the CLI's copy and saving the result locks the CLI out. Run any `claude` command, or give ClaudeMeter a token of its own. |
| Keychain access needed | `Keychain access needed` | Claude Code rewrote its credential, which reset the item's list of permitted programs. Press *Authorize…*, or set up a dedicated token so it stops happening. |

While offline:

- The two limit meters grey out and keep showing the last real reading. Those numbers were true at a
  stated time, and the notice says when.
- **The projections disappear entirely** — the pace line, the cap warning, the dashed forecast and
  its band. A cached percentage is still a reading that was true at a known moment; a cached
  projection is a forecast from a rate nobody is measuring any more, aimed at a reset that may
  already have passed. The observed sparkline points stay, because they were real readings.
- **Everything derived from the transcripts stays fully live.** Recent sessions, the 30-day chart,
  all four splits, cache hit, wall clock, agent hours, cost equivalents — none of it touches the
  network, and the rescan is checked after every poll attempt whether it succeeded or not. The
  offline notice says this explicitly.
- The menu bar item shows a crossed-out Wi-Fi badge while it is offline, and keeps showing the last
  reading beside it. The panel is still the authority on how old that reading is.
- The notice tells you when the next attempt is due, which is the app's own backoff rather than the
  server's `Retry-After`. This endpoint answers a 429 with `Retry-After: 0`, which means "no delay
  supplied" and not "retry immediately", so surfacing it would contradict what the app actually does.
- On a first launch with no network there is nothing cached, so the meters are hidden rather than
  shown empty, and the notice does not claim to be showing a last reading.

The credential states are handled differently from a transport failure, because no request was made.
There is nothing to back off from, so the app keeps its normal cadence and stays open to a
panel-open refresh — which is how a token Claude Code has just rotated gets picked up immediately.
The Keychain item is not re-read on every poll: the credential is held in memory and reused until
it either nears its deadline or the item's modification date changes, and that date comes from an
attributes-only read that decrypts nothing and cannot raise a dialog. So a rotation is still
noticed within one poll, without a decrypting read per poll to notice it with.

## The refresh cadence, and what setting it actually does

You choose the pace; the endpoint gets the last word. The usage endpoint is rate-limited per account,
and that budget is shared with Claude Code itself, so ClaudeMeter cannot know how much of it is
already spent. Your setting is where it aims, and the adaptive machinery around it stays in place.

- The default is three minutes — deliberately slower than the endpoint strictly needs. Starting slow
  and earning speed costs a little freshness and avoids teaching the limiter that this app is a
  problem.
- A 429 doubles the interval and the new value is written to defaults, so a limit discovered today is
  still respected after a relaunch rather than rediscovered tomorrow. It doubles past your setting if
  it has to: a setting is not a claim on somebody else's budget.
- After twelve consecutive clean polls the interval gives back a fifth of itself, down to the cadence
  you asked for. Quick to retreat, slow to advance: that asymmetry is what keeps the cadence from
  oscillating in and out of the limit.
- Ninety seconds is the fastest you can ask for, and the ceiling is fifteen minutes either way, so
  the app never stops being a live meter. Faster than ninety seconds is not on offer because it does
  not pay: a refusal costs minutes, which is slower than anything in the list.
- Choosing a cadence applies immediately and drops the interval the app had learned. Going slower
  that is obvious; going faster it means a backoff from an earlier 429 is forgiven, which is the point
  — a limit hit hours ago is a guess about a shared budget, not a fact about now. The first poll after
  a change is timed from your last reading, so changing the setting does not itself spend a request.
- A `Retry-After` that carries a usable value outranks the app's own backoff, but is capped at an
  hour — a header asking for a day would otherwise park the app until it was relaunched.
- Transport failures back off exponentially from the current cadence, capped at five minutes. The
  first step is the current cadence, so a network blip never retries faster than the pace the app has
  settled on.

Settings shows the cadence you chose, adds the effective one beside it once a 429 has pushed the two
apart, and changes its explanatory text to match — so a slow refresh reads as a deliberate choice
rather than a hang or a setting being ignored.

The transcript rescan is separate from all of this. It is checked after every poll attempt and runs
once five minutes have passed since the last scan, so poll failures do not hold it up. Passes after
the first are incremental — files already at their stored byte offset are not reopened — so it costs
almost nothing.

## Troubleshooting

**A Keychain prompt on first launch.** ClaudeMeter reads the same `Claude Code-credentials` item
Claude Code writes, and macOS asks once for access. Choose *Always Allow*. If it asks again on every
launch, the build is ad-hoc signed: an ad-hoc signature changes on every rebuild, so the system sees
a different application each time and the approval never sticks. Rebuild with a stable identity —
`make app SIGN_ID="Apple Development: you@example.com (TEAMID)"` — which is why `make app` now stops
rather than signing ad hoc by default.

**A password dialog on every `claude` command, naming `security` rather than ClaudeMeter.** Writing
a Keychain item's data rebuilds the item's list of permitted programs around whoever wrote it, and
the CLI gets dropped off it. Versions of ClaudeMeter that saved a renewed token did this; this one
never writes that item, so it cannot recur — but a machine carrying the damage still needs it
undone once. The panel shows `Claude Code is locked out of the Keychain` with a button that copies
the repair; `scripts/repair-keychain-partition-list.sh` is the same repair with a confirmation
step, and it adds the missing programs to the list rather than replacing it. Run it from a
terminal, where `security` asks for your login password itself — the dialogs the CLI raises are
torn down after two seconds, which is why *Always Allow* never manages to settle them.

**`Keychain access needed`.** The mirror image of the above, and the one that is expected to happen
from time to time: `claude` renewed its token, which rewrote the item and dropped *ClaudeMeter* off
the permitted list. Nothing is broken and nothing needs repairing. Press *Authorize…* in the panel
and approve once. ClaudeMeter deliberately does not raise that dialog by itself — its reads are
made with system dialogs suppressed, so a refusal comes back as a value instead of as a modal
window over whatever you were doing. To stop it recurring at all, give ClaudeMeter a token of its
own from `claude setup-token` in Settings ▸ Credentials.

**`Waiting for Claude Code`.** The stored access token has aged out and ClaudeMeter is deliberately
leaving it alone. Renewing it would spend Claude Code's refresh token, which the endpoint rotates,
retiring the copy the CLI is holding — and the only way to hand the replacement over is to write
the shared item, which locks the CLI out of it. Run any `claude` command and it renews within a few
minutes. Nothing is wrong with your credentials, and every statistic drawn from the transcripts is
still live.

**`Sign in again`.** The *refresh* token is the problem: it has passed its own deadline (they last a
few weeks), the server has revoked it, or the credentials never had one, which is the shape
`claude setup-token` writes. None of those can be fixed from this side. Run `claude` and sign in;
the notice clears within a cadence, and opening the panel picks it up sooner. If you gave
ClaudeMeter a token of its own, this notice names that token instead and the fix is to run
`claude setup-token` again and paste the new one into Settings.

**`Not signed in`.** No usable credential item exists. Sign in to Claude Code; the app picks the
credentials up on its next poll.

**No notifications.** Check, in order: the Alerts toggle is off by default and nothing is requested
from the system until you switch it on; if macOS is blocking notifications the settings pane says so
and offers a button to the right pane; and if you are running the binary directly out of `.build`
rather than the built `.app`, the process has no bundle identifier and the whole notification path
degrades to a no-op by design, because the system notification centre traps in that case. Note also
that alerts fire once per window — a window that already notified will not notify again, even if
utilization climbs further, until that window is over. Changing the threshold resets that
suppression.

**A Dock icon appears while Settings is open.** Expected. Accessory apps are not meant to own key
windows, so the app switches to a regular activation policy while the settings window is up and
reverts when it closes. The visible cost is a Dock icon for exactly as long as the window is open,
which is the trade for a settings window that actually appears when you click the gear. The revert is
deferred by one turn of the run loop, because doing it synchronously fights the window's close
animation and leaves the icon behind.

**`Launch ClaudeMeter at login` is unavailable.** Settings says `Available once ClaudeMeter is
running from a built .app bundle` when macOS reports no login item it can register, which is the case
for the bare executable. Run `make app` (or `make install`) and launch the bundle instead.

**The `Last 5 hours` section is missing.** It appears once the first poll sample has been recorded.
If samples exist but none falls inside the current window, the section shows a placeholder instead.

**Session rows look wrong, or there are more of them than expected.** The sessions list is stretches
of work, not transcript files. Widen the idle gap in Settings to merge stretches, narrow it to split
them; the list updates immediately without a rescan.

**Statistics are empty and the footer shows a spinner.** The first transcript pass reads the whole
corpus and runs off the main thread, so it cannot block the panel from opening. The affected sections
say they are reading transcripts while it runs. Later passes are incremental and finish quickly.

## Where state lives

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/ClaudeMeter/samples.jsonl` | One line per successful poll. The burn-rate dataset; pruned to just over a week. |
| `~/Library/Application Support/ClaudeMeter/last-snapshot.json` | Last successful reading, so a cold start has something to show. |
| `~/Library/Application Support/ClaudeMeter/events.json` | Deduplicated transcript events, so a cold start does not re-read the whole corpus. |
| `~/Library/Application Support/ClaudeMeter/scan-state.json` | Per-transcript byte offsets, a cumulative row count per file, and a format version. |
| App user defaults | Every setting, the collapsed/expanded state of the panel sections, the chosen and learned poll cadences, and which windows have already alerted. |

Deleting these is safe. The app rebuilds the event cache from the transcripts on its next scan and
loses its poll history, so projections read `estimated` again until the series refills.

Deleting them does not reset the refresh cadence. Neither interval is in this directory: the one you
chose lives in this app's user defaults under `preferredPollIntervalSeconds` and the learned one under
`pollIntervalSeconds`, so a cadence a 429 has widened survives both a relaunch and a clean-out of the
files above, and comes back down as the app earns it back — or at once, if you pick a cadence in
Settings. Resetting it by hand means clearing those keys from the app's defaults domain.
