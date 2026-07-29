# ClaudeMeter

A macOS menu bar widget for Claude usage. Shows your 5-hour and weekly limit percentages, projects where you'll land by the end of the period at your current rate, and keeps history of what you've used.

Built with SwiftUI's `MenuBarExtra`. No dependencies, no Dock icon. Resident set measured between
a modest figure against a large transcript corpus — the high end on the first launch, which reads
every transcript, and the low end afterwards, when the deduplicated event cache is
reused. Most of the floor is the SwiftUI and Charts framework baseline rather than usage data.

## Build

```sh
make app       # builds dist/ClaudeMeter.app
make run       # builds and launches it
make install   # copies to /Applications
make test      # runs the UsageCore test suite
```

Requires macOS 14+ and a Swift 6 toolchain (Xcode's is fine).

## Where the numbers come from

Two sources, used for different things.

**Limit percentages** come from `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's own `/usage` command reads. The response carries `five_hour.utilization`, `seven_day.utilization`, and exact `resets_at` timestamps. These are the real server-side numbers, not an approximation reconstructed from token counts — the limit accounting is proprietary and isn't derivable from tokens.

**History and session statistics** come from the local transcripts at `~/.claude/projects/**/*.jsonl`.

Burn rate is measured rather than modelled: the app records one sample per poll and fits a slope through the recent series. On first launch there's no series yet, so it falls back to calibrating token velocity from the transcripts against your current utilization. That state is labelled "estimated" in the UI and switches to measured once enough samples exist.

**The split matters when the API is unavailable.** The usage endpoint is rate-limited per account and
the token is shared with Claude Code itself, so a 429 is reachable in ordinary use — it was reached
during development. When that happens the two limit meters grey out and keep showing the last real
reading with its age, the forecast disappears entirely (a projection from a rate nobody is measuring
is worse than none), and everything drawn from the transcripts — sessions, the 30-day chart, model
and effort split, usage hours, cache-hit ratio, cost — stays fully live, because none of it depends
on the network. The notice says when the next attempt is due.

Polling is 60 seconds, but after a 429 the app holds a slower cadence for fifteen minutes rather than
returning to 60s on the first success; otherwise it oscillates between one good reading and another
rate limit. Note that this endpoint answers a 429 with `Retry-After: 0`, which means "no delay
supplied" rather than "retry immediately" — taking it literally is how you stay throttled.

## A note on the transcript data

If you're reading the source or building something similar: the transcripts contain duplicate rows. On a real corpus a large share of `requestId`s repeat, and summing rows naively inflates token totals substantially. Most duplicates are byte-identical, but a minority carry different payloads for the same key — streaming partials or retries.

`TranscriptScanner` deduplicates on `(requestId, message.id)` and takes the element-wise maximum of each token field on a collision. The deduplicated map is persisted, not just the file offsets, because a duplicate of an already-counted row can turn up in bytes read on a later pass.

## Credentials

The OAuth token is read from your Keychain (`Claude Code-credentials`), the same item Claude Code writes.

The app **never refreshes or writes the token**. Refresh tokens rotate, and racing Claude Code's own refresh could log you out. It re-reads the Keychain on each poll so a token Claude Code refreshed is picked up automatically. If the token expires while Claude Code isn't running, the widget says so and waits rather than trying to fix it.

macOS will prompt once for Keychain access. Choose "Always Allow". The build is ad-hoc signed and ad-hoc signatures change on every rebuild, so the prompt can reappear after `make app`. Signing with a stable self-signed certificate avoids that if it becomes tiresome.

## Privacy

The token goes to `api.anthropic.com` and nowhere else. Transcripts are read locally and never leave the machine. App state lives in `~/Library/Application Support/ClaudeMeter/`.

## Layout

```
Sources/UsageCore/     pure logic, no SwiftUI, fully testable
  Models.swift         shared types
  Paths.swift          every filesystem location, with test overrides
  ISO8601.swift        the two timestamp formats this app meets
  Keychain.swift       read-only credential access
  LimitsClient.swift   usage endpoint + defensive decoding
  TranscriptScanner.swift  incremental scan + deduplication
  SampleStore.swift    poll history and offline snapshot cache
  Aggregates.swift     sessions, daily rollups
  Pricing.swift        cost-equivalent estimates
  Projection.swift     window segmentation, burn rate, time-to-cap
  MenuBarLabelText.swift  the menu bar string, formatted here so it can be tested

Sources/ClaudeMeter/   SwiftUI, AppKit, Charts
  ClaudeMeterApp.swift the MenuBarExtra scene and the always-visible label
  AppModel.swift       poll loop, backoff, health state, aggregate recomputation
  Prefs.swift          every UserDefaults key, shared by the model and the views
  MenuBarIcon.swift    the ring, rasterised and memoised (see below)
  PanelView.swift      the dropdown; owns the disclosure sections
  MeterRow.swift       one limit: bar, reset line, projection line
  SeverityStyle.swift  the single severity-to-colour mapping
  SparklineView.swift  utilization over the current 5-hour window
  DailyBarsView.swift  tokens per day
  SessionsSection.swift  recent sessions
  ShareRowsView.swift  model and effort proportions
  SettingsView.swift   format, active-gap, notifications, launch at login
  Notifier.swift       threshold alerts, once per window

Tests/UsageCoreTests/  fixtures and unit tests
```

`UsageCore` doesn't import SwiftUI or AppKit. Anything with a decision in it — deduplication, window arithmetic, slope fitting, pricing — lives there and is covered by tests that run without network, Keychain, or a real `~/.claude` directory.

Two implementation notes that look odd until you know why. The menu bar ring is a rasterised
`NSImage` rather than a live SwiftUI shape, because `MenuBarExtra` only reliably renders `Text` and
`Image`; it is memoised on percentage, severity, the cap dot, and the current appearance, since a
bitmap cannot re-resolve a semantic colour when the menu bar flips between light and dark. And
`make test` passes `--no-parallel`: several suites redirect the same process-global path overrides,
and swift-testing runs suites concurrently, so in parallel one suite's cleanup can delete another's
temporary tree mid-test.

## Cost figures

The per-session and per-day dollar amounts are equivalent-cost estimates: what the same tokens would cost at published API rates. Subscription usage isn't billed per token, so treat them as a sense of scale rather than a bill.
