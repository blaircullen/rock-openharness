# Desktop and device: one living companion

## Objective

Connect the desktop's daemon to the USB Habitat device as one living character.
The same egg, individual, appearance, growth and emotional state must appear on
both surfaces. Real work across the agents it oversees drives reactions: merges,
successes, bugs and recovery, requests for help, sustained work and rest. The
device is the desktop's display and input peripheral. Mobile, web and TUI are
outside this integration's scope.

The user's refinement is **Tim first**. Complete Tim's egg-to-hatchling-to-grown
life cycle and his full emotional range before extending this work to other
species. The user will select Tim under Settings → Experimental. This is not a
request to reset an existing account collection or replace an owned individual.

This builds on PR #442 (`c500b8a5`), rebased onto #444 (`805d3deb`): shared Tim/Tux character rendering, local
animation, tap-to-speak, the separate bell/inbox, and one CableSession per device.
The existing account collection and pair brain remain the source of persistent
identity and work observations; the desktop owns the presentation sent to USB.

## Experience and ownership

- Start at the desktop's actual egg. Cracks, anticipation, hatch and the revealed
  individual travel to the device. A reconnect never grants or hatches an egg.
- Preserve individual identity and traits. A fixed gallery Tux is not a valid
  replacement for another individual's appearance. Supply bounded ASCII clips
  from the existing individual-art pipeline; keep animation clocks on the device.
- Let a merge produce a short delighted jump, a successful recovery a relieved
  bounce, repeated real failures a frustrated shake, and a request for help an
  attentive expression. Work, concentration, contentment, curiosity, boredom,
  playfulness, tiredness, exhaustion and sleep form the quieter daily rhythm.
- Emotional fatigue is expressive, never a claim about token limits or a reason
  to stop an agent. Idle moods may depend on elapsed time: the user explicitly
  requested a character that gets bored and tired, extending the old work-only
  animation rule.
- Reactions have priorities, finite durations, cooldowns and event identities.
  Questions and disconnection remain legible during celebrations. Returning to
  a screen does not replay a historical merge or failure.
- Give Tim the full home stage while the experiment is on. Completed results
  remain in the separate bell/inbox; explicitly opened reading views retain
  their text. Keep tap-to-speak and the bell/inbox from #442. Device requests return to the
  owning desktop window; only its acknowledged state changes identity or eggs.
- Respect the Experimental switch, quiet mode and Reduce Motion. Disabling the
  companion hides it on both surfaces without erasing the collection. Account
  changes clear the previous individual's device state and artwork.

## State and transport

Use a versioned, bounded `app_companion` snapshot on the local desktop socket.
It identifies the window epoch and increasing revision, enabled state, egg or
individual, presentation mood/reaction, motion preference and the artwork key.
Keep work observation and reaction selection in one desktop controller, used by
the desktop face and the USB publisher. Device-local gaze, microphone feedback
and idle animation may run at display cadence without changing persistent state.

The bridge selects the same desktop window as the existing device controls.
It validates snapshots, keeps the latest state, discards stale revisions and
publishes `companion.state` through CableFleet. Firmware advertises support;
older devices retain their existing controls. New devices request a full snapshot
on reconnect. A fresh connection restores current mood but does not restart a
completed transient reaction. Art transfers are keyed, bounded and cancellable;
an old transfer cannot replace a newly selected individual.

Do not send terminal prose, prompts or account credentials in companion state.
Use structured turn/tool outcomes and validated PR status transitions as evidence.
Initial inventories and transcript replay establish baselines, not celebrations.

## Completion evidence

The goal stays open until all of these are implemented and verified:

- [x] Desktop controller maps actual multi-agent work and PR transitions into a
      shared emotional state, including repeated failures and recovery.
- [x] Desktop face/portrait and USB state use that same controller.
- [x] Experimental off, account changes, window ownership, stale messages,
      disconnects and reconnects behave correctly.
- [x] USB transport carries egg, hatch, selected individual and emotional state
      end to end, with reverse device actions and acknowledgement.
- [x] Firmware renders the entire egg development/hatch sequence and Tim's baby,
      growing and mature stages, preserving his individual appearance, with
      delightful motion for the full event and emotion vocabulary.
- [x] Quiet/Reduce Motion, bounded memory, redraw correctness, voice, inbox and
      multiple devices remain covered.
- [x] Synthetic end-to-end replay uses production desktop serialization, the
      bridge, the C parser and renderer. Tests cover both normal and interrupted
      hatch/art transfers, live events and historical baselines.
- [x] Local review files demonstrate the complete day, egg/hatch sequences,
      individual appearances and each reaction using production renderers.
- [x] Firmware and desktop builds and relevant integration gates pass. Physical
      device validation remains distinct from simulated rendering/latency claims.

## Working safety

Use the isolated `codex/desktop-device-companion` worktree. Fixtures use temporary
data and simulated USB ports. Do not touch the user's tmux, Harness state,
installed app, services or physical device during implementation and host tests.
Prepare reviewable builds before any separately authorized hardware rollout. This
implementation has not been installed in the running desktop app or flashed.

## Validation (28 September 2026)

- Baseline: #442's character, preference, renderer, touch/inbox (200,000 operations
  per character) and seven mocked USB fleet checks passed in an isolated review.
- Desktop: 203 relevant unit/widget checks pass, including the actual saved egg,
  server-style hatch, daily earning caps, the same Tim UID/seed at all three ages,
  live tools versus replay, PR baselines, and Experimental off. A follow-up 21-test
  off/lifetime suite covers disposing the workspace. After rebasing onto #444,
  notification/question compatibility checks and the 35-test workspace suite
  pass. macOS debug build passes, and all ten changed application files pass
  static analysis without findings.
- CLI: 215 checks covering companion state, art, actions, local socket boundaries,
  CableSession, CableFleet and the newly unified notifications pass. Type checking and the CLI build pass. The build retains
  an existing `require` warning in `dsh/verdict.spec.ts`.
- Production replay: 15 actual Dart-serialized lifecycle snapshots enter
  `DesktopCompanion` and `CableSession`, which emit real framed USB bytes into a
  memory port. The C cable decoder and JSON guard consume chunks of 1, 7, 64, or
  8,192 bytes before the companion parser and renderer. Together with all eight
  egg kinds and 21 emotions at every age, it verifies 1,368 accepted messages,
  303 intentional refusals, and 1,192 incremental/full raster comparisons.
- Native touch replay with the companion enabled passes hatch gating, exact
  window/epoch/individual ownership, receipts, timeout, pet/nap/wake, and voice.
  The existing full native suite passes, including voice, bell/inbox, concurrent
  audio, USB recovery and 200,000-contact/state traces per legacy character.
- Firmware builds with ESP-IDF 5.5 for ESP32-S3 Habitat. The bounded companion
  state takes 55,072 bytes in external RAM; each owned-color scene is 11,208 bytes.
- `tim-life.html` uses the production clip provider, is self-contained, and passes
  offline control checks for every age/seed/mood/egg, hatch/day playback, pause,
  reduced motion and off. Production C raster images were inspected separately.

### Review limits

No physical USB/display/voice latency, on-board frame rate or battery claim is
made. The browser tool refused local `file:` URLs, so the HTML was checked with
an offline DOM harness, not a browser layout engine. Full Flutter analysis has
12 pre-existing informational lints confined to `third_party/xterm`; changed
application files have no findings. Review binaries remain isolated and have
not replaced the installed app or device firmware.

### Reproduce

Use disposable test state. The CLI tests use fake sockets and ports; never run a
production harness process just to test this feature.

```sh
# From desktop/ (Flutter 3.47.2; Swift Package Manager enabled)
flutter pub get
COMPANION_DESKTOP_WIRE=/tmp/companion-desktop-wire.json flutter test --no-pub \
  test/daemons test/daemon_off_test.dart test/daemon_workspace_test.dart
flutter build macos --debug --no-pub

# From cli/
npm ci --ignore-scripts
npm run typecheck
npm run build
npx vitest run src/cable/companionState.spec.ts src/cable/companionArt.spec.ts \
  src/cable/companionActions.spec.ts src/cable/cableSession.spec.ts \
  src/cable/cableFleet.spec.ts src/localWsServer.spec.ts --maxWorkers=2

# From the repository root, with ESP-IDF 5.5's IDF_PATH set
node daemons/companion/generate.mjs --check
COMPANION_DESKTOP_WIRE=/tmp/companion-desktop-wire.json \
  COMPANION_CHECK_OUT=/tmp/companion-replay node daemons/companion/check.mjs
SANITIZERS=undefined,bounds bash devices/harness-device/firmware/test/run.sh
HABITAT_COMPANION_TEST=1 python3 devices/harness-device/firmware/test/test_touch_ui.py
npm ci --prefix daemons/review/tools --ignore-scripts
node daemons/companion/review.mjs
node daemons/companion/check-review.mjs

# From devices/harness-device/firmware/ after sourcing ESP-IDF's export.sh
idf.py -B /tmp/companion-firmware-build -DIDF_TARGET=esp32s3 \
  -DDEVICE_HABITAT=1 -DDEVICE_DEFAULT_CHARACTER=tim -DDEVICE_CREATURE_GALLERY=0 \
  -DDEVICE_FORCE_PROD=1 -DDEVICE_PERF_BENCH=0 build
```

### Protocol v1

Only the computer's own trusted UI socket may publish `app_companion` or
`app_companion_result`. State contains `v`, `window`, `epoch`, increasing
`revision`, `enabled`, `foreground`, and (when enabled) `phase`, `motion`,
`feeling`, and the real egg/individual. The bridge supplies a monotonic `serial`.
Eggs carry `kind`, `stage`, and their issued `uid` when ready. Tim carries `uid`,
`seed`, `version` (`0.1`, `1.0`, `2.0`), printable name and shiny flag.

Firmware opts in with `hello.companion: 1`. `companion.state` names the artwork
key, followed as needed by `companion.art.begin`, up to eight
`companion.art.frame` messages and `companion.art.end`. Every art message names
both the key and transfer. Begin specifies eight RGB565 material colors, frame
count/cadence and looping; each frame carries equally sized ASCII `rows` and
`mats`, bounded to 56 columns × 30 rows. Only a complete transfer becomes visible.
A fresh connection or changed owner resends art even if it looks the same.

Device input is `companion.action` with `requestId`, `window`, `epoch`, `target`
and `action` (`hatch`, `pet`, `nap`, `wake`). The bridge validates current
ownership, deduplicates, and privately dispatches `dial_companion` to that one
window. The desktop validates again and answers `app_companion_result`. The
bridge returns `companion.action.result` only to the requesting physical session.
An acceptance receipt is not a hatch result: only the desktop's subsequently
published, server-confirmed collection can reveal a baby. Commands time out
without retries or local collection changes.

The Experimental switch clears state without deleting the collection. Account
or selected-individual changes clear cached art and pending actions. Physical
link loss retains the last portrait still and dim; reconnect establishes a fresh
serial baseline and restores authoritative state. Unsupported species remain
outside this Tim-first experiment; existing individuals are never converted.
