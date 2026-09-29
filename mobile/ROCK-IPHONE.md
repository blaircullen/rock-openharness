# Rock OpenHarness on an iPhone

From `mobile/`, with team `U9SB3CXF74` signed into Xcode and the iPhone trusted:

```bash
~/development/flutter/bin/flutter pub get
~/development/flutter/bin/flutter build ios --release --dart-define=ROCK_BUILD_SHA="$(git rev-parse --short HEAD)"
~/development/flutter/bin/flutter install -d <device-id>
```

`ios/Flutter/RockFork.xcconfig` holds the fork display name, both bundle IDs and the signing team. Debug, Release and Profile include it. Runner has no `.entitlements` file, no associated domains, app groups, push, iCloud or custom keychain group. Automatic signing therefore needs an ordinary development profile for `com.blaircullen.rockopenharness`.

The phone signs in with an emailed code through `lib/viewer/email_code_api.dart`, or a one-time code in the machine's Add Phone QR. Neither path requires an OAuth callback, universal link or Autonomous's associated domain. The same access token is accepted by the Harness backend's account check. The phone has no self-updater or forced update screen; `lib/core/fork_build.dart` supplies its fork version label.

The tmux picker is under New Harness on a linked machine. It reads on entry and on pull-to-refresh. Borrowed panes are identified by the daemon's `external.kind: tmux` field, opened by agent ID and removed with `tmux_pane_unenroll`; removing one does not stop its tmux process.
