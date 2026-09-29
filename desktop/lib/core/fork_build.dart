/// Rock OpenHarness — the one place the desktop app says it is a fork of
/// upstream Harness.
///
/// The upstream update manifests only ever carry stock builds, so a fork must
/// not follow them: the app does not offer or install app updates
/// (`DesktopUpdater`), and it never runs the stock CLI installer over
/// `~/.harness/cli` (`EnvironmentProvisioner`). A fork CLI is installed from
/// the fork checkout with `make install-cli`.
///
/// Kept in a file upstream does not have, so merging upstream never conflicts
/// here; the hooks in upstream files are one expression each.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;

import '../logging/app_log.dart';
import 'app_version.dart';
import 'test_run.dart';

const bool kRockForkBuild = true;
const String kRockForkName = 'Rock OpenHarness';

/// The commit the app was built from, stamped by the release build with
/// `--dart-define=ROCK_BUILD_SHA=<short sha>`. macOS keeps
/// `CFBundleShortVersionString` to three integers, so the fork label cannot
/// ride in `--build-name`; it is appended here instead.
const String kRockBuildSha = String.fromEnvironment('ROCK_BUILD_SHA');

/// What the CLI step tells the person when a fork build finds no working CLI.
const String kRockForkCliInstallHint =
    'make install-cli   # from the Rock OpenHarness checkout';

/// `1.2.27` → `1.2.27-rock.<sha>` (or `1.2.27-rock` for a release build with
/// no sha stamped). A debug build with no sha keeps the bare version.
/// Idempotent, so a version that already carries the label is left alone.
String rockForkVersion(
  String base, {
  String sha = kRockBuildSha,
  bool releaseMode = kReleaseMode,
}) {
  if (!kRockForkBuild || base.contains('-rock')) return base;
  if (sha.isEmpty && !releaseMode) return base;
  return sha.isEmpty ? '$base-rock' : '$base-rock.$sha';
}

/// One log line at start-up naming the fork and its version, so a log file
/// says which build wrote it.
void logRockForkBuild() {
  if (!kRockForkBuild || kUnderTest) return;
  unawaited(
    runningAppVersion()
        .then(
          (version) => appLog.info(
            'app',
            '$kRockForkName $version · app self-update off',
          ),
        )
        .catchError((Object error) {
          appLog.warn('app', '$kRockForkName version unreadable', error: error);
        }),
  );
}
