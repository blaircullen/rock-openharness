@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/auth/auth_session.dart';
import 'package:harness/core/config.dart';
import 'package:harness/core/models.dart';
import 'package:harness/settings/settings_screen.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/state/app_state.dart';
import 'package:harness/state/new_harness.dart';
import 'package:harness/web/shell/web_workspace.dart';
import 'package:harness/widgets/new_harness_form.dart';
import 'package:harness/widgets/swarm_switcher.dart';

Future<AppNotifier> _mount(
  WidgetTester tester, {
  String? connectedMachine,
}) async {
  final app = AppNotifier(config: AppConfig.dev, authSession: AuthSession())
    ..newSwarm(newTabPage: true);
  if (connectedMachine != null) {
    final machine = Machine(
      machineId: connectedMachine,
      name: connectedMachine,
      authMode: MachineAuthMode.remote,
    );
    app.machines.add(machine);
    app.machineStates[connectedMachine] = MachineState(machine)
      ..nodeOnline = true
      ..connectionStatus = ConnectionStatus.connected;
  }
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: grid.buildAppTheme(brightness: Brightness.dark),
      home: WebWorkspace(app: app),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
  return app;
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('web-app-menu-button')));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('the menu button opens Settings with one click', (tester) async {
    final app = await _mount(tester);
    await _openMenu(tester);
    expect(
      find.byKey(const ValueKey('web-menu:machines.list')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('web-menu:web.sign_out')), findsOneWidget);
    // An empty tab has no pane to split, zoom or close.
    expect(find.byKey(const ValueKey('web-menu:pane.close')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('web-menu:app.settings')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('New harness opens the form on a connected machine', (
    tester,
  ) async {
    // The app opens New Harness in the box; tests default to the old form.
    newHarnessOpensInBox = true;
    addTearDown(() => newHarnessOpensInBox = false);
    final app = await _mount(tester, connectedMachine: 'remote-box');
    // New work starts where a new tab opens: its "Start an agent" row.
    await tester.tap(find.byKey(const ValueKey('welcome-agent.new')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NewHarnessForm), findsOneWidget);
    expect(find.byType(SwarmSearchResults), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('New harness with nothing connected opens Machines', (
    tester,
  ) async {
    final app = await _mount(tester);
    // New work starts where a new tab opens: its "Start an agent" row.
    await tester.tap(find.byKey(const ValueKey('welcome-agent.new')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NewHarnessForm), findsNothing);
    expect(
      tester
          .widget<SwarmSearchResults>(find.byType(SwarmSearchResults))
          .search
          .scopePrefix,
      '@',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('keys still reach Settings beside the menu', (tester) async {
    final app = await _mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });
}
