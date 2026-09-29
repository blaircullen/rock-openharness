import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/auth/auth_session.dart';
import 'package:harness_mobile/core/config.dart';
import 'package:harness_mobile/core/fork_build.dart';
import 'package:harness_mobile/core/models.dart';
import 'package:harness_mobile/core/tmux_panes.dart';
import 'package:harness_mobile/e2ee/envelope.dart';
import 'package:harness_mobile/phone/agents_page.dart';
import 'package:harness_mobile/phone/tmux_pane_picker.dart';
import 'package:harness_mobile/state/app_state.dart';
import 'package:harness_mobile/ws/ws_conn.dart';

class _Conn extends WsConn {
  _Conn()
    : super(
        wsBaseUrl: 'ws://fixture.invalid',
        autonomousEnv: 'test',
        machineId: 'm',
        accessTokenProvider: (_, _) async => '',
        onAuthFailure: (_) {},
        onEvent: (_) {},
        onStatus: (_) {},
      );

  final calls = <(String, Map<String, dynamic>)>[];
  final answers = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>> request(
    String type, {
    Map<String, dynamic> payload = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    calls.add((type, payload));
    return answers[type] ?? {};
  }
}

AppNotifier _app(_Conn conn, {List<Agent> agents = const []}) {
  final app = AppNotifier(
    config: AppConfig.dev,
    authSession: AuthSession(),
    configStore: null,
    connectionForTest: (_) => conn,
  );
  const machine = Machine(
    machineId: 'm',
    authMode: MachineAuthMode.remote,
    name: 'Studio',
  );
  app.machines = [machine];
  app.machineStates['m'] = MachineState(machine)
    ..nodeOnline = true
    ..connectionStatus = ConnectionStatus.connected
    ..agentLoadStatus = AgentLoadStatus.loaded
    ..agents = agents;
  return app;
}

Map<String, dynamic> _pane(String id, String state) => {
  'paneId': id,
  'sessionName': 'work',
  'windowIndex': 1,
  'paneIndex': 0,
  'command': 'vim',
  'cwd': '/code/project',
  'state': state,
};

Map<String, dynamic> _borrowed(String id) => {
  'id': id,
  'name': 'work',
  'engine': 'terminal',
  'terminal': {'available': true, 'primary': '', 'runtimes': []},
  'external': {
    'kind': 'tmux',
    'sessionName': 'work',
    'windowIndex': 1,
    'paneIndex': 0,
    'available': true,
  },
};

void main() {
  test('only an explicit external marker makes a masked row borrowed', () {
    final borrowed = Agent.fromJson(_borrowed('borrowed'));
    expect(borrowed.isExternal, isTrue);
    expect(borrowed.external?.address, 'work:1.0');
    expect(borrowed.terminalAvailable, isTrue);
    expect(
      Agent.fromJson({..._borrowed('plain'), 'external': null}).isExternal,
      isFalse,
    );
  });

  test(
    'listing parses states and never uses a bare pane id as an agent route',
    () {
      final listing = TmuxPaneListing.fromJson({
        'server': {'serverIdentity': 's1'},
        'panes': [
          _pane('%1', 'available'),
          _pane('%2', 'managed'),
          _pane('%3', 'shared_window'),
          {..._pane('%4', 'enrolled'), 'agentId': 'a4'},
          _pane('4', 'available'),
        ],
      });
      expect(listing.panes.map((p) => p.address), [
        'work:1.0',
        'work:1.0',
        'work:1.0',
        'work:1.0',
      ]);
      expect(listing.panes.where((p) => p.canEnroll).map((p) => p.paneId), [
        '%1',
      ]);
      expect(listing.panes[1].unavailableReason, 'Harness session');
      expect(listing.panes[2].unavailableReason, 'Split window');
      expect(listing.panes[3].agentId, 'a4');
    },
  );

  test(
    'enroll and unenroll use agent id and preserve server identity',
    () async {
      final conn = _Conn();
      final app = _app(conn);
      addTearDown(app.dispose);
      conn.answers['tmux_panes_list'] = {
        'server': {'serverIdentity': 's1'},
        'panes': [_pane('%7', 'available')],
      };
      conn.answers['tmux_pane_enroll'] = {'agent': _borrowed('borrowed-7')};
      final listing = await app.listTmuxPanes('m');
      final agent = await app.enrollTmuxPane(
        'm',
        listing.panes.single,
        listing.serverIdentity!,
      );
      expect(agent.isExternal, isTrue);
      expect(conn.calls[1].$1, 'tmux_pane_enroll');
      expect(conn.calls[1].$2, {'paneId': '%7', 'serverIdentity': 's1'});
      expect(app.stateOf('m')!.agents.single.id, 'borrowed-7');
      expect(
        await app.renameAgent('m', 'borrowed-7', 'other'),
        contains('cannot'),
      );
      expect(
        await app.deleteAgent('m', 'borrowed-7'),
        contains('Remove from Harness'),
      );
      expect(
        (await app.restartAgent('m', 'borrowed-7')).error,
        contains('cannot'),
      );
      expect(
        (await app.resumeAgent('m', 'borrowed-7')).error,
        contains('cannot'),
      );
      expect(
        await app.retargetAgentToGridModel('m', 'borrowed-7', 'model'),
        contains('cannot'),
      );
      expect(
        conn.calls.where(
          (call) => [
            'agent_update',
            'agent_delete',
            'agent_restart',
            'agent_resume',
            'agent_retarget',
          ].contains(call.$1),
        ),
        isEmpty,
      );
      await app.unenrollTmuxPane('m', 'borrowed-7');
      expect(conn.calls.last.$1, 'tmux_pane_unenroll');
      expect(conn.calls.last.$2, {'agentId': 'borrowed-7'});
      expect(app.stateOf('m')!.agents, isEmpty);
      expect(conn.calls.where((call) => call.$1 == 'agent_delete'), isEmpty);
    },
  );

  testWidgets(
    'picker dims managed and split panes and refreshes only on pull',
    (tester) async {
      final conn = _Conn();
      final app = _app(conn);
      addTearDown(app.dispose);
      conn.answers['tmux_panes_list'] = {
        'server': {'serverIdentity': 's1'},
        'panes': [
          _pane('%1', 'available'),
          _pane('%2', 'managed'),
          _pane('%3', 'shared_window'),
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: TmuxPanePicker(notifier: app, machineId: 'm'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Harness session'), findsOneWidget);
      expect(find.textContaining('Split window'), findsOneWidget);
      expect(
        conn.calls.where((call) => call.$1 == 'tmux_panes_list').length,
        1,
      );
      await tester.tap(find.textContaining('Harness session'));
      await tester.pump();
      expect(
        conn.calls.where((call) => call.$1 == 'tmux_pane_enroll'),
        isEmpty,
      );
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(
        conn.calls.where((call) => call.$1 == 'tmux_panes_list').length,
        2,
      );
    },
  );

  testWidgets('borrowed menu has only Open, Disconnect and Remove', (
    tester,
  ) async {
    final conn = _Conn();
    final agent = Agent.fromJson(_borrowed('borrowed'));
    final app = _app(conn, agents: [agent]);
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AgentsPage(notifier: app, machineId: 'm'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('tmux'), findsOneWidget);
    await tester.longPress(find.text('work').first);
    await tester.pumpAndSettle();
    for (final label in ['Open', 'Disconnect', 'Remove from Harness']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in ['Stop Harness…', 'Rename…', 'Restart', 'Model']) {
      expect(find.text(label), findsNothing);
    }
  });

  test('fork version and sealed tmux requests', () {
    expect(kRockForkBuild, isTrue);
    expect(rockForkVersion('1.0.0', sha: 'abc123'), '1.0.0-rock.abc123');
    for (final type in [
      'tmux_panes_list',
      'tmux_pane_enroll',
      'tmux_pane_unenroll',
    ]) {
      expect(sealsDown(type, strictDown: false), isTrue);
    }
  });
}
