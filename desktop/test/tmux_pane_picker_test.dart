import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/core/models.dart';
import 'package:harness/core/tmux_panes.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/terminal/terminal_text.dart';
import 'package:harness/widgets/tmux_pane_picker.dart';

TmuxPane _pane(
  String id,
  String session, {
  TmuxPaneState state = TmuxPaneState.available,
  String? agentId,
}) => TmuxPane(
  paneId: id,
  sessionName: session,
  windowIndex: 0,
  paneIndex: 0,
  windowName: 'zsh',
  command: 'vim',
  cwd: '/Users/me/src/$session',
  state: state,
  agentId: agentId,
);

class _Fake {
  final listings = <TmuxPaneListing>[];
  var lists = 0;
  final enrolls = <(String, String)>[];
  final opened = <String>[];
  Object? enrollError;

  TmuxPanePickerActions get actions => TmuxPanePickerActions(
    list: () async {
      lists++;
      return listings[(lists - 1).clamp(0, listings.length - 1)];
    },
    enroll: (pane, identity) async {
      enrolls.add((pane.paneId, identity));
      if (enrollError case final error?) {
        enrollError = null;
        throw error;
      }
      return Agent(id: 'borrowed-${pane.paneId}', name: pane.address);
    },
    open: (agentId) async => opened.add(agentId),
  );
}

void main() {
  late _Fake fake;
  setUp(() => fake = _Fake());

  Future<void> show(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: grid.buildAppTheme(brightness: Brightness.dark),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTmuxPanePicker(
              context,
              machineLabel: 'Goat',
              actions: fake.actions,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Finder row(String id) => find.byKey(ValueKey('tmux-pane:$id'));
  final picker = find.byKey(const ValueKey('tmux-pane-picker'));

  testWidgets(
    'lists once on open, one terminal row per pane, and never polls',
    (tester) async {
      fake.listings.add(
        TmuxPaneListing(
          serverIdentity: '9:1',
          panes: [
            _pane('%1', 'work'),
            _pane('%2', 'harness-codex-1', state: TmuxPaneState.managed),
            _pane('%3', 'split', state: TmuxPaneState.sharedWindow),
          ],
        ),
      );
      await show(tester);
      expect(fake.lists, 1);
      expect(find.text('tmux panes on Goat'), findsOneWidget);
      final cell = terminalCellSizeOf(tester.element(picker));
      for (final id in ['%1', '%2', '%3']) {
        expect(tester.getSize(row(id)).height, cell.height);
      }
      expect(find.text('work:0.0'), findsOneWidget);
      expect(find.text('~/src/work'), findsOneWidget);
      expect(find.text('Harness session'), findsOneWidget);
      expect(find.text('Split window'), findsOneWidget);
      await tester.pump(const Duration(minutes: 5));
      expect(fake.lists, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Enter on an available pane enrolls it with the listed server and opens it',
    (tester) async {
      fake.listings.add(
        TmuxPaneListing(
          serverIdentity: '9:1',
          panes: [
            _pane('%2', 'harness-codex-1', state: TmuxPaneState.managed),
            _pane('%1', 'work'),
          ],
        ),
      );
      await show(tester);
      // The managed row is selectable but Enter on it does nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(fake.enrolls, isEmpty);
      expect(picker, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(fake.enrolls, [('%1', '9:1')]);
      expect(fake.opened, ['borrowed-%1']);
      expect(picker, findsNothing);
    },
  );

  testWidgets('an added pane opens its existing terminal without enrolling', (
    tester,
  ) async {
    fake.listings.add(
      TmuxPaneListing(
        serverIdentity: '9:1',
        panes: [
          _pane(
            '%1',
            'work',
            state: TmuxPaneState.enrolled,
            agentId: 'borrowed-7',
          ),
        ],
      ),
    );
    await show(tester);
    expect(find.text('Added'), findsOneWidget);
    await tester.tap(row('%1'));
    await tester.pumpAndSettle();
    expect(fake.enrolls, isEmpty);
    expect(fake.opened, ['borrowed-7']);
  });

  testWidgets(
    'a server that restarted since the listing is refused and the list re-read',
    (tester) async {
      fake.listings
        ..add(
          TmuxPaneListing(serverIdentity: '9:1', panes: [_pane('%1', 'work')]),
        )
        ..add(
          TmuxPaneListing(
            serverIdentity: '10:5',
            panes: [_pane('%1', 'other')],
          ),
        );
      fake.enrollError = const TmuxPaneError(
        'TMUX_SERVER_CHANGED',
        'tmux restarted since the list was read. The list was refreshed.',
      );
      await show(tester);
      await tester.tap(row('%1'));
      await tester.pumpAndSettle();
      expect(fake.enrolls, [('%1', '9:1')]);
      expect(fake.opened, isEmpty);
      expect(fake.lists, 2);
      expect(find.text('other:0.0'), findsOneWidget);
      expect(find.byKey(const ValueKey('tmux-pane-error')), findsOneWidget);
      expect(picker, findsOneWidget);
      // Enrolling again uses the NEW incarnation.
      await tester.tap(row('%1'));
      await tester.pumpAndSettle();
      expect(fake.enrolls.last, ('%1', '10:5'));
    },
  );

  testWidgets('a failed read is shown as an error, not as no panes', (
    tester,
  ) async {
    final failing = TmuxPanePickerActions(
      list: () async => throw const TmuxPaneError(
        'TMUX_INVENTORY_FAILED',
        'tmux did not answer in time',
      ),
      enroll: (_, _) async => throw UnimplementedError(),
      open: (_) async {},
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: grid.buildAppTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: TmuxPanePicker(machineLabel: 'Goat', actions: failing),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('tmux did not answer in time'), findsOneWidget);
    expect(find.text('No tmux panes.'), findsNothing);
  });

  testWidgets('no server running says so; Refresh reads again', (tester) async {
    fake.listings
      ..add(const TmuxPaneListing(serverIdentity: null, panes: []))
      ..add(TmuxPaneListing(serverIdentity: '9:1', panes: [_pane('%1', 'w')]));
    await show(tester);
    expect(find.text('No tmux server is running on Goat.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tmux-pane-refresh')));
    await tester.pumpAndSettle();
    expect(fake.lists, 2);
    expect(row('%1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
