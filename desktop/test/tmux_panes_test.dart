import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/core/models.dart';
import 'package:harness/core/tmux_panes.dart';
import 'package:harness/e2ee/envelope.dart';
import 'package:harness/screens/swarm_screen.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/shortcuts/app_keymap.dart';
import 'package:harness/state/app_state.dart';
import 'package:harness/state/swarm_catalog.dart';
import 'package:harness/ws/ws_conn.dart';

import 'keymap_host_test.dart' show key, MemoryKeymap;
import 'swarm_screen_test.dart' show terminal;
import 'swarm_state_test.dart' show createApp;

/// Records the borrowed-tmux RPCs and answers each from [replies] (or a
/// completer the test resolves).
class TmuxConnection extends WsConn {
  TmuxConnection()
    : super(
        wsBaseUrl: 'ws://fixture.invalid',
        autonomousEnv: 'test',
        machineId: 'm',
        accessTokenProvider: (_, _) async => '',
        onAuthFailure: (_) {},
        onEvent: (_) {},
        onStatus: (_) {},
      );

  final requests = <(String, Map<String, dynamic>)>[];

  /// Only the borrowed-tmux RPCs; the app's own background reads are not ours.
  List<(String, Map<String, dynamic>)> get tmux =>
      requests.where((r) => r.$1.startsWith('tmux_')).toList();
  final replies = <String, Map<String, dynamic>>{};
  Object? failure;

  @override
  bool get isReady => true;

  @override
  Future<void> waitUntilReady({required Duration timeout}) async {}

  @override
  Future<Map<String, dynamic>> request(
    String type, {
    Map<String, dynamic> payload = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    requests.add((type, Map.of(payload)));
    if (failure != null && type.startsWith('tmux_')) throw failure!;
    return replies[type] ?? {};
  }
}

const _borrowedFrame = <String, dynamic>{
  'id': 'borrowed-1',
  'name': 'work:1.0',
  'engine': 'terminal',
  'status': 'active',
  'tmuxPane': null,
  'terminal': {'available': true, 'primary': '', 'runtimes': []},
  'external': {
    'kind': 'tmux',
    'sessionName': 'work',
    'windowIndex': 1,
    'paneIndex': 0,
    'windowName': 'vim',
    'command': 'vim',
    'available': true,
    'reason': null,
  },
  'forkable': false,
};

void main() {
  group('model', () {
    test('parses a listing, dropping rows it cannot read', () {
      final listing = TmuxPaneListing.fromJson({
        'server': {
          'socketPath': '/private/tmp/tmux-501/default',
          'serverIdentity': '100:1700000000',
        },
        'panes': [
          {
            'paneId': '%3',
            'sessionName': 'work',
            'windowIndex': 1,
            'paneIndex': 0,
            'windowPanes': 1,
            'windowName': 'vim',
            'command': 'vim',
            'cwd': '/Users/me/src',
            'state': 'available',
          },
          {
            'paneId': '%4',
            'sessionName': 'harness-codex-1',
            'windowIndex': 0,
            'paneIndex': 0,
            'state': 'managed',
          },
          {
            'paneId': '%5',
            'sessionName': 'x',
            'windowIndex': 0,
            'paneIndex': 0,
            'state': 'enrolled',
            'agentId': 'borrowed-1',
          },
          {'paneId': 'nope', 'sessionName': 'x', 'state': 'available'},
          {'paneId': '%6', 'sessionName': 'x', 'windowIndex': 0},
        ],
      });
      expect(listing.serverIdentity, '100:1700000000');
      expect(listing.panes.map((p) => p.paneId), ['%3', '%4', '%5']);
      expect(listing.panes[0].address, 'work:1.0');
      expect(listing.panes[0].canEnroll, isTrue);
      expect(listing.panes[1].canEnroll, isFalse);
      expect(listing.panes[1].unavailableReason, 'Harness session');
      expect(listing.panes[2].agentId, 'borrowed-1');
      expect(
        TmuxPaneListing.fromJson({'server': null, 'panes': []}).serverIdentity,
        isNull,
      );
    });

    test('a borrowed pane is an agent that offers no lifecycle actions', () {
      final agent = Agent.fromJson(Map.of(_borrowedFrame));
      expect(agent.isExternal, isTrue);
      expect(agent.external!.address, 'work:1.0');
      expect(agent.external!.command, 'vim');
      expect(agent.terminalAvailable, isTrue);
      expect(agent.canFork, isFalse);
      expect(agent.canClone, isFalse);
      expect(agent.canPauseAndResume, isFalse);
      final managed = Agent.fromJson({
        'id': 'a1',
        'name': 'Shell',
        'engine': 'terminal',
        'external': null,
      });
      expect(managed.isExternal, isFalse);
      expect(managed.canPauseAndResume, isTrue);
      expect(agent.copyWith(name: 'x').external, agent.external);
    });

    test('a change of availability alone is a change to the agent list', () {
      final before = Agent.fromJson(Map.of(_borrowedFrame));
      final after = Agent.fromJson({
        ..._borrowedFrame,
        'external': {
          ...(_borrowedFrame['external'] as Map<String, dynamic>),
          'available': false,
          'reason': 'TMUX_SERVER_RESTARTED',
        },
      });
      expect(AppNotifier.agentsEqual([before], [after]), isFalse);
      expect(AppNotifier.agentsEqual([before], [before]), isTrue);
    });

    test('the three RPCs are always sealed', () {
      for (final type in [
        'tmux_panes_list',
        'tmux_pane_enroll',
        'tmux_pane_unenroll',
      ]) {
        expect(encryptedDownTypes, contains(type));
        expect(sealsDown(type, strictDown: false), isTrue);
      }
    });
  });

  group('app state', () {
    late TmuxConnection connection;
    late AppNotifier app;
    setUp(() {
      connection = TmuxConnection();
      app = createApp(connectionForTest: (_) => connection, connected: true);
    });
    tearDown(() => app.dispose());

    test(
      'lists without enrolling, and enrolls with the listed server',
      () async {
        connection.replies['tmux_panes_list'] = {
          'server': {'socketPath': '/tmp/s', 'serverIdentity': '9:1'},
          'panes': [
            {
              'paneId': '%3',
              'sessionName': 'work',
              'windowIndex': 1,
              'paneIndex': 0,
              'state': 'available',
            },
          ],
        };
        final listing = await app.listTmuxPanes('m');
        expect(connection.tmux.single.$1, 'tmux_panes_list');
        expect(connection.tmux.single.$2.containsKey('socketPath'), isFalse);
        expect(app.stateOf('m')!.agents.any((a) => a.isExternal), isFalse);

        connection.replies['tmux_pane_enroll'] = {
          'agent': _borrowedFrame,
          'alreadyEnrolled': false,
        };
        final agent = await app.enrollTmuxPane(
          'm',
          listing.panes.single,
          listing.serverIdentity!,
        );
        expect(connection.tmux.last.$1, 'tmux_pane_enroll');
        expect(connection.tmux.last.$2, {
          'paneId': '%3',
          'serverIdentity': '9:1',
        });
        expect(agent.id, 'borrowed-1');
        expect(
          app.stateOf('m')!.agents.where((a) => a.id == 'borrowed-1').single,
          isA<Agent>().having((a) => a.isExternal, 'isExternal', isTrue),
        );
      },
    );

    test(
      'words refusals, and a failed read is an error, not an empty list',
      () async {
        connection.failure = const WsRequestFailure(
          responseType: 'tmux_panes_list_result',
          code: 'TMUX_INVENTORY_FAILED',
          detail: 'tmux did not answer in time',
        );
        await expectLater(
          app.listTmuxPanes('m'),
          throwsA(
            isA<TmuxPaneError>().having(
              (e) => e.message,
              'message',
              'tmux did not answer in time',
            ),
          ),
        );
        connection.failure = const WsRequestTimeout('tmux_panes_list');
        await expectLater(
          app.listTmuxPanes('m'),
          throwsA(
            isA<TmuxPaneError>().having((e) => e.code, 'code', 'TIMEOUT'),
          ),
        );
      },
    );

    test('never asks to change a borrowed pane\'s model', () async {
      final machine = app.stateOf('m')!;
      machine.agents = [
        ...machine.agents,
        Agent.fromJson(Map.of(_borrowedFrame)),
      ];
      await app.retargetAgentToGridModel('m', 'borrowed-1', 'model');
      await app.retargetAgentToApiModel(
        'm',
        'borrowed-1',
        connectionId: 'c',
        modelId: 'model',
      );
      expect(
        connection.requests.map((r) => r.$1),
        isNot(contains('agent_retarget')),
      );
    });

    test('refuses a machine that is not connected before asking it', () async {
      app.stateOf('m')!.connectionStatus = ConnectionStatus.disconnected;
      await expectLater(app.listTmuxPanes('m'), throwsA(isA<TmuxPaneError>()));
      expect(connection.requests, isEmpty);
    });

    test(
      'unenroll forgets the row; nothing stops or deletes the pane',
      () async {
        final machine = app.stateOf('m')!;
        machine.agents = [
          ...machine.agents,
          Agent.fromJson(Map.of(_borrowedFrame)),
        ];
        expect(
          await app.deleteAgent('m', 'borrowed-1'),
          'This tmux pane was added from its machine. Unenroll it instead.',
        );
        expect(
          connection.requests.map((r) => r.$1),
          isNot(contains('agent_delete')),
        );

        connection.replies['tmux_pane_unenroll'] = {'removed': true};
        await app.unenrollTmuxPane('m', 'borrowed-1');
        expect(connection.tmux.map((r) => r.$1), ['tmux_pane_unenroll']);
        expect(connection.tmux.single.$2, {'agentId': 'borrowed-1'});
        expect(
          connection.requests.map((r) => r.$1),
          isNot(contains('agent_delete')),
        );
        expect(machine.agents.any((a) => a.id == 'borrowed-1'), isFalse);
      },
    );
  });

  group('command palette', () {
    late TmuxConnection connection;
    late AppNotifier app;
    late MemoryKeymap map;
    late SwarmProjectStore projects;
    setUp(() {
      connection = TmuxConnection();
      app = createApp(connectionForTest: (_) => connection, connected: true);
      map = MemoryKeymap();
      projects = SwarmProjectStore();
    });
    tearDown(() {
      app.dispose();
      map.dispose();
      projects.dispose();
    });

    Future<void> mount(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: grid.buildAppTheme(brightness: Brightness.dark),
          home: KeymapProvider(
            keymap: map,
            child: SwarmScreen(
              notifier: app,
              nativeTabs: false,
              projectStore: projects,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> search(WidgetTester tester, String query) async {
      await key(tester, LogicalKeyboardKey.keyP, cmd: true, shift: true);
      await tester.enterText(
        find.byKey(const ValueKey('swarm-search-input')),
        query,
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'a focused borrowed pane offers Unenroll and none of the lifecycle actions',
      (tester) async {
        app.stateOf('m')!.agents[0] = Agent.fromJson({
          ..._borrowedFrame,
          'id': 'a0',
        });
        app.adoptSessionForTest(terminal('a0', []));
        await mount(tester);
        await search(tester, '> tmux');
        expect(
          find.text('Unenroll tmux Pane', findRichText: true),
          findsWidgets,
        );
        expect(find.text('Add tmux Pane…', findRichText: true), findsWidgets);
        for (final (query, label) in [
          ('> restart', 'Restart Terminal'),
          ('> stop', 'Stop Terminal'),
          ('> fork', 'Fork Harness'),
          ('> rename', 'Rename Harness'),
          ('> clone', 'Clone Harness'),
        ]) {
          await tester.enterText(
            find.byKey(const ValueKey('swarm-search-input')),
            query,
          );
          await tester.pumpAndSettle();
          expect(
            find.text(label, findRichText: true),
            findsNothing,
            reason: label,
          );
        }

        connection.replies['tmux_pane_unenroll'] = {'removed': true};
        await tester.enterText(
          find.byKey(const ValueKey('swarm-search-input')),
          '> unenroll',
        );
        await tester.pumpAndSettle();
        await key(tester, LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(connection.tmux.map((r) => r.$1), ['tmux_pane_unenroll']);
        expect(app.stateOf('m')!.agents.any((a) => a.id == 'a0'), isFalse);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'an unavailable borrowed pane says why on its tile and offers Unenroll',
      (tester) async {
        app.stateOf('m')!.agents[0] = Agent.fromJson({
          ..._borrowedFrame,
          'id': 'a0',
          'terminal': {
            'available': false,
            'primary': '',
            'runtimes': [],
            'reason': 'the tmux server restarted since this pane was added',
          },
          'external': {
            ...(_borrowedFrame['external'] as Map<String, dynamic>),
            'available': false,
            'reason': 'TMUX_SERVER_RESTARTED',
          },
        });
        app.adoptSessionForTest(terminal('a0', []));
        await mount(tester);
        expect(find.textContaining('the tmux server restarted'), findsWidgets);
        connection.replies['tmux_pane_unenroll'] = {'removed': true};
        await tester.tap(find.text('Unenroll'));
        await tester.pumpAndSettle();
        expect(connection.tmux.map((r) => r.$1), ['tmux_pane_unenroll']);
        expect(
          connection.requests.map((r) => r.$1),
          isNot(contains('agent_delete')),
        );
        expect(app.stateOf('m')!.agents.any((a) => a.id == 'a0'), isFalse);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('a managed pane is not offered Unenroll', (tester) async {
      app.adoptSessionForTest(terminal('a0', []));
      await mount(tester);
      await search(tester, '> tmux');
      expect(find.text('Unenroll tmux Pane', findRichText: true), findsNothing);
      expect(find.text('Add tmux Pane…', findRichText: true), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
