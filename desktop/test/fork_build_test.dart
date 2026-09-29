import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness/auth/auth_session.dart';
import 'package:harness/bootstrap/environment_provisioner.dart';
import 'package:harness/core/app_version.dart';
import 'package:harness/core/config.dart';
import 'package:harness/core/fork_build.dart';
import 'package:harness/state/app_state.dart';
import 'package:harness/update/desktop_updater.dart';

ProcessResult _result(int exitCode, {String stdout = ''}) =>
    ProcessResult(1, exitCode, stdout, '');

void main() {
  test('this tree is a Rock OpenHarness fork build', () {
    expect(kRockForkBuild, isTrue);
    expect(kRockForkName, 'Rock OpenHarness');
  });

  group('app self-update', () {
    test('the default updater never checks, downloads or applies, even in release mode', () async {
      final updater = DesktopUpdater(
        releaseMode: true,
        metadataUrl: 'https://fixture.invalid/metadata.json',
      );
      expect(updater.canCheck, isFalse);
      expect(
        await updater.checkOnce(currentVersion: '0.0.1'),
        isNull,
      );
      expect(
        await updater.downloadAndStage(
          const UpdateInfo(
            version: '99.0.0',
            url: 'https://fixture.invalid/update.zip',
            sha256: 'unused',
            size: 1,
          ),
        ),
        isNull,
      );
      expect(
        await updater.applyStaged(
          const StagedUpdate(
            version: '99.0.0',
            bundlePath: '/nonexistent/fixture.app',
            stagingDirPath: '/nonexistent',
          ),
          selfPid: 1,
        ),
        isFalse,
      );
    });

    test('the app never prompts: update checks are off and a manual check reports disabled', () async {
      final app = AppNotifier(
        config: AppConfig.dev,
        authSession: AuthSession(),
        configStore: null,
      );
      addTearDown(app.dispose);
      expect(app.updateChecksEnabled, isFalse);
      final manual = await app.checkForUpdates();
      expect(manual.check.status, DesktopUpdateCheck.disabled().status);
      expect(app.availableUpdate, isNull);
    });
  });

  group('fork version label', () {
    test('a stamped build carries -rock.<sha>', () {
      expect(rockForkVersion('1.2.27', sha: 'abc1234'), '1.2.27-rock.abc1234');
      expect(
        rockForkVersion('1.2.27', sha: 'abc1234', releaseMode: false),
        '1.2.27-rock.abc1234',
      );
    });

    test('an unstamped release build still says -rock; a debug one keeps the bare version', () {
      expect(rockForkVersion('1.2.27', sha: '', releaseMode: true), '1.2.27-rock');
      expect(rockForkVersion('1.2.27', sha: '', releaseMode: false), '1.2.27');
    });

    test('is idempotent', () {
      expect(
        rockForkVersion('1.2.27-rock.abc1234', sha: 'def5678'),
        '1.2.27-rock.abc1234',
      );
    });

    test('runningAppVersion goes through the fork label', () async {
      final version = await runningAppVersion(
        packageInfoVersion: () async => '1.2.27',
      );
      expect(version, rockForkVersion('1.2.27'));
    });
  });

  group('CLI install', () {
    late Directory scratch;
    late List<String> calls;

    setUp(() async {
      scratch = await Directory.systemTemp.createTemp('rock-fork-cli-');
      calls = <String>[];
    });

    tearDown(() async {
      if (await scratch.exists()) await scratch.delete(recursive: true);
    });

    Future<ProcessResult> run(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
    }) async {
      calls.add('$executable ${arguments.join(' ')}');
      if (arguments.contains('version')) {
        return _result(0, stdout: 'harness 1.2.27-dev.abc1234');
      }
      return _result(0);
    }

    bool ranStockInstaller() =>
        calls.any((line) => line.contains('cdn.autonomous.ai/harness/cli/install.sh') &&
            line.contains('--desktop'));

    EnvironmentProvisioner provisioner() => EnvironmentProvisioner(
      harnessHome: scratch,
      isMacOS: true,
      isLinux: false,
      run: run,
    );

    test('a fork (-dev) CLI on the developer\'s own Node is kept, never replaced', () async {
      final cli = File('${scratch.path}/cli/cli.js');
      await cli.parent.create(recursive: true);
      await cli.writeAsString('fork cli');
      // No ~/.harness/runtime/current-node: install-cli.sh ran it on system Node.

      final readiness = await provisioner().ensureReady(
        onProgress: (_) {},
        install: true,
        mode: EnvironmentSetupMode.automatic,
      );

      expect(readiness.isReady, isTrue);
      expect(ranStockInstaller(), isFalse);
      expect(await cli.readAsString(), 'fork cli');
    });

    test('with no CLI at all, setup stops and names the fork install instead of curling the stock one', () async {
      final readiness = await provisioner().ensureReady(
        onProgress: (_) {},
        install: true,
        mode: EnvironmentSetupMode.automatic,
      );

      expect(readiness.isReady, isFalse);
      expect(readiness.phase, EnvironmentSetupPhase.failed);
      expect(ranStockInstaller(), isFalse);
      expect(readiness.failure?.detail, contains('Rock OpenHarness'));
      expect(readiness.failure?.command, kRockForkCliInstallHint);
    });

    test('the plan shows the fork install, not the stock installer', () {
      expect(EnvironmentPlanItem.harnessCli.command, kRockForkCliInstallHint);
    });
  });
}
