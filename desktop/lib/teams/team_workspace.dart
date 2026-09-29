import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../shared/theme/app_theme.dart' as grid;
import '../state/app_state.dart';
import '../state/harness_sessions.dart';
import '../terminal/terminal_text.dart';
import '../terminal/terminal_theme.dart';
import '../terminal/terminal_theme_store.dart';
import '../widgets/box_chrome.dart';
import '../widgets/terminal_prompt.dart';
import '../widgets/terminal_text_action.dart';
import 'team_controller.dart';

class TeamCandidate {
  const TeamCandidate({
    required this.machineId,
    required this.agentId,
    required this.name,
    required this.machineName,
    required this.engine,
    required this.status,
    required this.available,
  });
  final String machineId, agentId, name, machineName, engine, status;
  final bool available;
  String get key => '$machineId/$agentId';
}

Future<void> showChannelWorkspace(BuildContext context, AppNotifier app) async {
  final tabId = app.activeSwarmId;
  final gateway = app.channelGateway(app.focusedPane?.machineId);
  if (gateway == null) return;
  final controller = app.channelController(tabId, gateway);
  await showTerminalPrompt<void>(
    context,
    builder: (context) => TeamWorkspace(
      controller: controller,
      candidates: const [],
      machineName: app.activeSwarm.name,
      onClose: () => Navigator.pop(context),
      onOpen: (machine, agent) {
        Navigator.pop(context);
        unawaited(
          app.openAgentFromDial(machine, agent, intent: AttachIntent.person),
        );
      },
    ),
  );
}

Future<void> showTeamWorkspace(BuildContext context, AppNotifier app) async {
  var machineId =
      app.localMachineState?.machine.machineId ??
      app.focusedPane?.machineId ??
      app.machineStates.keys.firstOrNull;
  if (machineId == null) return;
  await showTerminalPrompt<void>(
    context,
    builder: (context) => StatefulBuilder(
      builder: (context, setHost) => ListenableBuilder(
        listenable: app,
        builder: (context, _) => TeamWorkspace(
          key: ValueKey(machineId),
          controller: app.teamController(machineId!),
          machineName:
              app.stateOf(machineId!)?.machine.displayName ?? 'This machine',
          onChooseHost: () async {
            final host = await showTerminalPrompt<String>(
              context,
              builder: (context) => _TeamChoice(
                title: 'Teams live on this machine',
                choices: [
                  for (final state in app.machineStates.values)
                    if (!state.machine.isShared)
                      (
                        id: state.machine.machineId,
                        label: state.machine.displayName,
                        detail: state.machine.machineId == machineId
                            ? 'selected'
                            : '',
                      ),
                ],
              ),
            );
            if (context.mounted && host != null) {
              setHost(() => machineId = host);
            }
          },
          candidates: [
            for (final row in harnessSessions(app))
              if (!row.machine.machine.isShared &&
                  row.agent.engine != 'terminal')
                TeamCandidate(
                  machineId: row.machineId,
                  agentId: row.agent.id,
                  name: row.agent.displayName,
                  machineName: row.machine.machine.displayName,
                  engine: row.agent.engine ?? 'Agent',
                  status: row.status,
                  available: row.online,
                ),
          ],
          onClose: () => Navigator.pop(context),
          onOpen: (machine, agent) {
            Navigator.pop(context);
            unawaited(
              app.openAgentFromDial(
                machine,
                agent,
                intent: AttachIntent.person,
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// Terminal-native team roster, conversations, and question composer. No terminal is
/// attached or written by mounting, searching, selecting, or closing this surface.
class TeamWorkspace extends StatefulWidget {
  const TeamWorkspace({
    super.key,
    required this.controller,
    required this.candidates,
    required this.machineName,
    required this.onClose,
    required this.onOpen,
    this.onChooseHost,
  });
  final TeamController controller;
  final List<TeamCandidate> candidates;
  final String machineName;
  final VoidCallback onClose;
  final void Function(String machineId, String agentId) onOpen;
  final VoidCallback? onChooseHost;
  @override
  State<TeamWorkspace> createState() => _TeamWorkspaceState();
}

class _TeamWorkspaceState extends State<TeamWorkspace> {
  TeamController get model => widget.controller;
  final _search = TextEditingController();
  late final _name = TextEditingController(text: model.newName);
  late final _description = TextEditingController(text: model.newDescription);
  late final _question = TextEditingController(text: model.draft);
  final _questionFocus = FocusNode(debugLabel: 'Team question');
  bool _creating = false;
  String? _selectedMember;
  late Size cell;
  late Color foreground, muted, selection;
  TextStyle get style => terminalContentStyle(color: foreground);
  TextStyle get faint => terminalContentStyle(color: muted);
  @override
  void initState() {
    super.initState();
    model.addListener(_changed);
    model.watch();
    _creating = model.pendingCreate;
  }

  void _changed() {
    if (!mounted) return;
    if (_question.text != model.draft) {
      _question.value = TextEditingValue(
        text: model.draft,
        selection: TextSelection.collapsed(offset: model.draft.length),
      );
    }
    if (model.selectedId != null) _creating = false;
    setState(() {});
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    model.unwatch();
    _search.dispose();
    _name.dispose();
    _description.dispose();
    _question.dispose();
    _questionFocus.dispose();
    super.dispose();
  }

  Widget _line(
    String label,
    VoidCallback? action, {
    String? trailing,
    bool selected = false,
    Key? key,
    String? semantics,
  }) {
    return Semantics(
      selected: selected,
      label: semantics,
      child: SizedBox(
        height: cell.height,
        child: TextButton(
          key: key,
          onPressed: action,
          style:
              TextButton.styleFrom(
                foregroundColor: foreground,
                disabledForegroundColor: muted,
                backgroundColor: selected ? selection : Colors.transparent,
                minimumSize: Size.zero,
                padding: EdgeInsets.symmetric(horizontal: cell.width),
                shape: const RoundedRectangleBorder(),
                textStyle: style,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                splashFactory: NoSplash.splashFactory,
              ).copyWith(
                overlayColor: WidgetStatePropertyAll(
                  selection.withValues(alpha: .45),
                ),
              ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) Text('  $trailing', style: faint),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController text,
    String label, {
    Key? key,
    int lines = 1,
    bool readOnly = false,
    FocusNode? focus,
    ValueChanged<String>? changed,
  }) => TextField(
    key: key,
    controller: text,
    focusNode: focus,
    readOnly: readOnly,
    minLines: lines,
    maxLines: lines == 1 ? 1 : lines + 3,
    style: style,
    cursorWidth: 2,
    decoration: InputDecoration(
      labelText: label,
      labelStyle: faint,
      hintStyle: faint,
      filled: false,
      isDense: true,
      contentPadding: EdgeInsets.symmetric(vertical: cell.height / 2),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
    ),
    onChanged: changed,
  );
  Widget _action(String label, VoidCallback? callback, {Key? key}) =>
      TerminalTextAction(
        key: key,
        label: label,
        onPressed: callback,
        padding: EdgeInsets.zero,
      );
  Widget _gap([double rows = 1]) => SizedBox(height: cell.height * rows);
  String _memberName(String? id) {
    final member = model.members.where((m) => m['id'] == id).firstOrNull;
    final runtime = member?['runtime'] as Map?;
    if (model.isChannel && runtime?['name'] is String) {
      return runtime!['name'] as String;
    }
    return member?['name'] as String? ?? 'Choose';
  }

  Future<void> _choose(bool source) async {
    final choices = model.members
        .where(
          (m) => m['enabled'] != false && (source || m['id'] != model.from),
        )
        .toList();
    final chosen = await showTerminalPrompt<String>(
      context,
      builder: (context) => _TeamChoice(
        title: source ? 'Ask on behalf of' : 'Ask a teammate',
        choices: [
          for (final m in choices)
            (
              id: m['id'] as String,
              label: '@${m['name']}',
              detail: m['role'] as String? ?? '',
            ),
        ],
      ),
    );
    if (!mounted || chosen == null) return;
    setState(() {
      if (source) {
        model.from = chosen;
        if (model.to == chosen) model.to = null;
      } else {
        model.to = chosen;
      }
    });
    _questionFocus.requestFocus();
  }

  void _toggle(TeamCandidate candidate) {
    if (model.pendingCreate || model.operating || !candidate.available) return;
    setState(() {
      if (model.newMembers.remove(candidate.key) != null) return;
      var alias = candidate.name
          .toLowerCase()
          .replaceAll(RegExp('[^a-z0-9_-]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
      if (alias.isEmpty) alias = 'teammate';
      if (alias.length > 32) alias = alias.substring(0, 32);
      final base = alias;
      var n = 2;
      while (model.newMembers.values.any((m) => m['name'] == alias)) {
        alias = '$base-${n++}';
      }
      model.newMembers[candidate.key] = {
        'machineId': candidate.machineId,
        'agentId': candidate.agentId,
        'name': alias,
        'role': candidate.name,
      };
    });
  }

  Widget _home() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Connect the harnesses already doing your work.', style: style),
      _gap(),
      Text(
        'Give each teammate a role. Questions and answers travel between their existing harnesses, across engines and machines.',
        style: faint,
      ),
      _gap(),
      Align(
        alignment: Alignment.centerLeft,
        child: _action(
          'New team',
          () => setState(() => _creating = true),
          key: const Key('team-new'),
        ),
      ),
      _gap(2),
      Text('Your teams · ${widget.machineName}', style: faint),
      if (widget.onChooseHost != null)
        Align(
          alignment: Alignment.centerLeft,
          child: _action(
            'Choose machine',
            model.operating ? null : widget.onChooseHost,
          ),
        ),
      _gap(),
      Expanded(
        child: model.loading
            ? _loadingRows()
            : model.teams.isEmpty
            ? Text('No teams yet. Start with two harnesses.', style: faint)
            : ListView(
                children: [
                  for (final team in model.teams)
                    _line(
                      team['name'] as String,
                      () => unawaited(model.select(team['id'] as String)),
                      trailing: '${team['members']} peers · ${team['state']}',
                      key: ValueKey('team-open-${team['id']}'),
                    ),
                ],
              ),
      ),
    ],
  );
  Widget _loadingRows() => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: EdgeInsets.only(bottom: cell.height),
            child: ColoredBox(
              color: muted.withValues(alpha: .12),
              child: SizedBox(
                width: cell.width * (24 - i * 3),
                height: cell.height,
              ),
            ),
          ),
      ],
    ),
  );
  Widget _create() {
    final query = _search.text.toLowerCase();
    final candidates = widget.candidates
        .where(
          (c) => '${c.name} ${c.engine} ${c.machineName}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(
          _name,
          'Team name',
          key: const Key('team-name'),
          readOnly: model.pendingCreate,
          changed: (v) {
            model.newName = v;
            setState(() {});
          },
        ),
        _field(
          _description,
          'What are you building together?',
          readOnly: model.pendingCreate,
          changed: (v) => model.newDescription = v,
        ),
        _gap(.5),
        _field(
          _search,
          'Find a harness',
          key: const Key('team-search'),
          changed: (_) => setState(() {}),
        ),
        Text(
          '${model.newMembers.length} selected · Connect introduces the team to these harnesses.',
          style: faint,
        ),
        _gap(),
        Expanded(
          child: ListView(
            key: const Key('team-candidates'),
            children: [
              if (candidates.isEmpty)
                Text('No matching harnesses.', style: faint),
              for (final candidate in candidates) ...[
                _line(
                  '${model.newMembers.containsKey(candidate.key) ? '[x]' : '[ ]'} ${candidate.name}',
                  model.pendingCreate || !candidate.available
                      ? null
                      : () => _toggle(candidate),
                  trailing:
                      '${candidate.engine} · ${candidate.available ? candidate.machineName : candidate.status}',
                  key: ValueKey('team-candidate-${candidate.agentId}'),
                  semantics:
                      '${candidate.name}, ${candidate.engine}, ${candidate.status}',
                ),
                if (model.newMembers[candidate.key] case final member?)
                  Padding(
                    padding: EdgeInsets.only(
                      left: cell.width * 4,
                      bottom: cell.height,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final name = TextFormField(
                          key: ValueKey('team-alias-${candidate.agentId}'),
                          initialValue: member['name'] as String,
                          readOnly: model.pendingCreate,
                          style: style,
                          decoration: InputDecoration(
                            labelText: 'Team name',
                            labelStyle: faint,
                            isDense: true,
                            border: InputBorder.none,
                          ),
                          onChanged: (v) => member['name'] = v,
                        );
                        final role = TextFormField(
                          key: ValueKey('team-role-${candidate.agentId}'),
                          initialValue: member['role'] as String,
                          readOnly: model.pendingCreate,
                          style: style,
                          decoration: InputDecoration(
                            labelText: 'Knows about',
                            labelStyle: faint,
                            isDense: true,
                            border: InputBorder.none,
                          ),
                          onChanged: (v) => member['role'] = v,
                        );
                        return constraints.maxWidth < cell.width * 50
                            ? Column(children: [name, role])
                            : Row(
                                children: [
                                  SizedBox(width: cell.width * 22, child: name),
                                  SizedBox(width: cell.width * 2),
                                  Expanded(child: role),
                                ],
                              );
                      },
                    ),
                  ),
              ],
            ],
          ),
        ),
        _gap(),
        Wrap(
          spacing: cell.width * 3,
          runSpacing: cell.height,
          children: [
            _action(
              model.pendingCreate ? 'Check connection' : 'Connect teammates',
              model.operating ||
                      (!model.pendingCreate &&
                          (model.newMembers.length < 2 ||
                              model.newName.trim().isEmpty))
                  ? null
                  : () => unawaited(model.create()),
              key: const Key('team-connect'),
            ),
            _action(
              'Back',
              model.operating ? null : () => setState(() => _creating = false),
            ),
          ],
        ),
      ],
    );
  }

  Widget _roster() {
    final selected = model.members
        .where((m) => m['id'] == _selectedMember)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          model.isChannel ? 'Harnesses in this swarm' : 'Teammates',
          style: faint,
        ),
        _gap(),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final member in model.members)
                _line(
                  model.isChannel
                      ? _memberName(member['id'] as String?)
                      : '@${member['name']}',
                  () =>
                      setState(() => _selectedMember = member['id'] as String),
                  selected: _selectedMember == member['id'],
                  trailing: member['enabled'] == false
                      ? 'Removed'
                      : (member['runtime'] as Map?)?['engine'] as String? ??
                            'Offline',
                  key: ValueKey('team-member-${member['id']}'),
                ),
            ],
          ),
        ),
        if (selected != null) ...[
          _gap(),
          Text(selected['role'] as String? ?? '', style: faint),
          _gap(),
          Text(
            selected['enabled'] == false
                ? 'Removed from team'
                : (selected['runtime'] as Map?)?['available'] == true
                ? 'Available'
                : 'Offline · questions wait here',
            style: faint,
          ),
          _gap(),
          _action(
            'Open harness',
            () => widget.onOpen(
              selected['machineId'] as String,
              selected['agentId'] as String,
            ),
          ),
          if (!model.isChannel) _gap(.5),
          if (!model.isChannel)
            _action(
              'Edit teammate',
              model.operating ? null : () => _editMember(selected),
            ),
        ],
        _gap(2),
        if (!model.isChannel)
          Align(
            alignment: Alignment.centerLeft,
            child: _action(
              'Ask teammate',
              model.active
                  ? () {
                      setState(() {
                        model.selectedExchange = null;
                        if (selected?['enabled'] != false &&
                            selected?['id'] != model.from &&
                            selected != null) {
                          model.to = selected['id'] as String;
                        }
                      });
                      _questionFocus.requestFocus();
                    }
                  : null,
              key: const Key('team-new-question'),
            ),
          ),
      ],
    );
  }

  Future<void> _addMember() async {
    if (model.pendingAdd) {
      await model.addMember();
      return;
    }
    final candidates = widget.candidates
        .where(
          (candidate) =>
              candidate.available &&
              !model.members.any(
                (m) =>
                    m['enabled'] != false &&
                    m['machineId'] == candidate.machineId &&
                    m['agentId'] == candidate.agentId,
              ),
        )
        .toList();
    final chosen = await showTerminalPrompt<String>(
      context,
      builder: (context) => _TeamChoice(
        title: candidates.isEmpty
            ? 'No additional harnesses available'
            : 'Connect an existing harness',
        choices: [
          for (final c in candidates)
            (
              id: c.key,
              label: c.name,
              detail: '${c.engine} · ${c.machineName}',
            ),
        ],
      ),
    );
    if (!mounted || chosen == null) return;
    final candidate = candidates.firstWhere((c) => c.key == chosen);
    var alias = candidate.name
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (alias.isEmpty) alias = 'teammate';
    alias = alias.substring(0, math.min(alias.length, 32));
    final base = alias;
    var suffix = 2;
    while (model.members.any(
      (m) =>
          m['enabled'] != false &&
          m['name'].toString().toLowerCase() == alias.toLowerCase(),
    )) {
      alias = '$base-${suffix++}';
    }
    await _editMember({
      'machineId': candidate.machineId,
      'agentId': candidate.agentId,
      'name': alias,
      'role': candidate.name,
    }, adding: true);
  }

  Future<void> _editMember(
    Map<String, dynamic> member, {
    bool adding = false,
  }) async {
    final name = TextEditingController(text: member['name'] as String);
    final role = TextEditingController(text: member['role'] as String? ?? '');
    final result = await showTerminalPrompt<String>(
      context,
      builder: (context) => TerminalPromptKeys(
        cancel: () => Navigator.pop(context),
        child: _TeamSurface(
          width: 620,
          child: Padding(
            padding: EdgeInsets.all(cell.width * 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  adding ? 'Connect teammate' : 'Edit teammate',
                  style: faint,
                ),
                _field(name, 'Team name'),
                _field(role, 'Knows about'),
                _gap(),
                Wrap(
                  spacing: cell.width * 3,
                  children: [
                    _action(
                      adding ? 'Connect' : 'Save',
                      model.team?['state'] == 'archived'
                          ? null
                          : () => Navigator.pop(context, 'save'),
                    ),
                    if (!adding)
                      _action(
                        'Open harness',
                        () => Navigator.pop(context, 'open'),
                      ),
                    if (!adding &&
                        member['enabled'] != false &&
                        model.team?['state'] != 'archived')
                      _action(
                        'Remove from team',
                        () => Navigator.pop(context, 'remove'),
                      ),
                    _action('Back', () => Navigator.pop(context)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted && result != null) {
      if (result == 'open') {
        widget.onOpen(
          member['machineId'] as String,
          member['agentId'] as String,
        );
      } else if (adding) {
        await model.addMember({
          ...member,
          'name': name.text.trim(),
          'role': role.text.trim(),
        });
      } else {
        await model.act('member', {
          'member': {
            'id': member['id'],
            'name': name.text.trim(),
            'role': role.text.trim(),
            'enabled': result != 'remove' && member['enabled'] != false,
          },
        });
      }
    }
    name.dispose();
    role.dispose();
  }

  Widget _composer() => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Ask a teammate', style: style),
        _gap(),
        Wrap(
          spacing: cell.width * 3,
          runSpacing: cell.height,
          children: [
            _action(
              'From @${_memberName(model.from)}',
              model.pendingAsk ? null : () => _choose(true),
            ),
            _action(
              'To @${_memberName(model.to)}',
              model.pendingAsk ? null : () => _choose(false),
            ),
          ],
        ),
        _gap(),
        _field(
          _question,
          'What do you need to know?',
          key: const Key('team-question'),
          lines: 3,
          readOnly: model.pendingAsk,
          focus: _questionFocus,
          changed: (v) {
            model.draft = v;
            setState(() {});
          },
        ),
        _gap(),
        Text(
          'The answer returns to @${_memberName(model.from)} so it can continue. The exchange records that you initiated this question.',
          style: faint,
        ),
        _gap(),
        Align(
          alignment: Alignment.centerLeft,
          child: _action(
            model.pendingAsk ? 'Check send' : 'Ask',
            model.operating ||
                    !model.active ||
                    (!model.pendingAsk &&
                        (model.draft.trim().isEmpty ||
                            model.to == null ||
                            model.from == model.to))
                ? null
                : () => unawaited(model.ask()),
            key: const Key('team-ask'),
          ),
        ),
      ],
    ),
  );
  Widget _conversation(Map<String, dynamic> exchange) {
    final answer = (exchange['answer'] as Map?)?.cast<String, dynamic>();
    final from =
        model.members.where((m) => m['id'] == exchange['from']).firstOrNull ??
        (exchange['fromPeer'] as Map?)?.cast<String, dynamic>();
    final to =
        model.members.where((m) => m['id'] == exchange['to']).firstOrNull ??
        (exchange['toPeer'] as Map?)?.cast<String, dynamic>();
    final fromName =
        (exchange['fromPeer'] as Map?)?['name'] ??
        _memberName(exchange['from'] as String?);
    final toName =
        (exchange['toPeer'] as Map?)?['name'] ??
        _memberName(exchange['to'] as String?);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            model.isChannel
                ? '$fromName → $toName'
                : '@${from?['name']} → @${to?['name']}',
            style: style,
          ),
          Text(
            '${exchange['origin'] == 'owner' ? 'Requested by you' : 'Agent question'} · ${exchange['state']} · ${teamDeliveryLabel((exchange['delivery'] as Map?)?.cast<String, dynamic>())}',
            style: faint,
          ),
          _gap(),
          SelectableText(exchange['text'] as String? ?? '', style: style),
          if ((exchange['context'] as String? ?? '').isNotEmpty) ...[
            _gap(),
            SelectableText(exchange['context'] as String, style: faint),
          ],
          _gap(),
          if (answer != null) ...[
            Text(
              '${answer['late'] == true ? 'Late answer' : 'Answer'} ${answer['origin'] == 'owner' ? 'supplied by you for' : 'from'} @${to?['name']}',
              style: faint,
            ),
            _gap(.5),
            SelectableText(answer['text'] as String, style: style),
            for (final reference in answer['evidence'] as List? ?? [])
              Padding(
                padding: EdgeInsets.only(top: cell.height / 2),
                child: SelectableText(reference.toString(), style: faint),
              ),
            _gap(),
            Text(
              answer['late'] == true
                  ? 'Retained for reference. No automatic continuation.'
                  : 'Return to @${from?['name']}: ${teamDeliveryLabel((exchange['continuation'] as Map?)?.cast<String, dynamic>())}',
              style: faint,
            ),
          ] else
            Text(
              exchange['state'] == 'pending'
                  ? 'Waiting for a correlated answer. Delivery alone does not mean the question is answered.'
                  : 'This question is ${exchange['state']}.',
              style: faint,
            ),
          if ((exchange['delivery'] as Map?)?['reason']
              case final String reason) ...[
            _gap(.5),
            Text(reason, style: faint),
          ],
          _gap(),
          Wrap(
            spacing: cell.width * 3,
            runSpacing: cell.height,
            children: [
              if (from != null)
                _action(
                  'Open @${from['name']}',
                  () => widget.onOpen(
                    from['machineId'] as String,
                    from['agentId'] as String,
                  ),
                ),
              if (to != null)
                _action(
                  'Open @${to['name']}',
                  () => widget.onOpen(
                    to['machineId'] as String,
                    to['agentId'] as String,
                  ),
                ),
              if (exchange['state'] == 'pending')
                _action(
                  'Cancel question',
                  model.operating
                      ? null
                      : () => unawaited(
                          model.act('cancel', {
                            'questionId':
                                exchange['questionId'] ?? exchange['id'],
                            if (exchange['teamId'] != null)
                              'teamId': exchange['teamId'],
                          }),
                        ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _exchanges() {
    final selected = model.exchanges
        .where((e) => e['id'] == model.selectedExchange)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Exchanges', style: faint),
        _gap(),
        SizedBox(
          height:
              cell.height * math.min(6, math.max(2, model.exchanges.length)),
          child: model.exchanges.isEmpty
              ? Text('Questions and answers will appear here.', style: faint)
              : ListView(
                  children: [
                    for (final exchange in model.exchanges)
                      _line(
                        '${(exchange['fromPeer'] as Map?)?['name'] ?? _memberName(exchange['from'] as String?)} → ${(exchange['toPeer'] as Map?)?['name'] ?? _memberName(exchange['to'] as String?)}  ${exchange['text']}',
                        () => setState(
                          () =>
                              model.selectedExchange = exchange['id'] as String,
                        ),
                        selected: model.selectedExchange == exchange['id'],
                        trailing: exchange['state'] as String,
                        key: ValueKey('team-exchange-${exchange['id']}'),
                      ),
                  ],
                ),
        ),
        _gap(),
        Expanded(
          child: selected == null
              ? model.isChannel
                    ? SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Agents consult relevant peers in this swarm and continue their work.',
                              style: style,
                            ),
                            _gap(),
                            Text(
                              'Add a harness to this swarm to include its agent.',
                              style: faint,
                            ),
                            for (final instruction in teamRows(
                              model.team?['consultations'],
                            ).reversed.take(5)) ...[
                              _gap(),
                              Text(
                                'Consult requested for ${_memberName(instruction['memberId'] as String?)} · ${teamDeliveryLabel((instruction['receipt'] as Map?)?.cast<String, dynamic>())}',
                                style: faint,
                              ),
                            ],
                          ],
                        ),
                      )
                    : _composer()
              : _conversation(selected),
        ),
      ],
    );
  }

  Widget _detail() {
    if (model.team == null) {
      return model.loading
          ? _loadingRows()
          : Align(
              alignment: Alignment.topLeft,
              child: _action(
                model.isChannel ? 'Retry reading swarm' : 'Retry reading team',
                () => unawaited(model.refresh()),
              ),
            );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < cell.width * 90) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: cell.height * 2,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final m in model.members)
                      Padding(
                        padding: EdgeInsets.only(right: cell.width * 2),
                        child: _action(
                          '${m['name']}',
                          () => model.isChannel
                              ? widget.onOpen(
                                  m['machineId'] as String,
                                  m['agentId'] as String,
                                )
                              : _editMember(m),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(child: _exchanges()),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: cell.width * 28, child: _roster()),
            SizedBox(width: cell.width * 3),
            Expanded(child: _exchanges()),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    TerminalFontScope.watch(context);
    grid.AppTheme.watch(context);
    return ListenableBuilder(
      listenable: Listenable.merge([terminalFontStore, terminalThemeStore]),
      builder: (context, _) {
        final theme = terminalThemeFor(
          grid.AppTheme.palette.value,
          terminalThemeStore.value,
        );
        cell = terminalCellSizeOf(context);
        foreground = theme.foreground;
        // Read off the scheme's own ground, not the app palette's: Tango stays
        // dark under a light palette. Near-black at .6 on a light ground is
        // 3.9:1, so a light scheme takes .7 (≥5.4:1); a dark one keeps .6.
        muted = foreground.withValues(
          alpha: theme.background.computeLuminance() > .5 ? .7 : .6,
        );
        selection = theme.selection;
        final title = _creating
            ? 'Connect a team'
            : model.team?['name'] as String? ??
                  (model.isChannel ? 'Swarm conversation' : 'Team');
        return TerminalPromptKeys(
          cancel: widget.onClose,
          refresh: () => unawaited(model.refresh()),
          submit: model.isChannel ? null : () => unawaited(model.ask()),
          child: _TeamSurface(
            width: 1140,
            child: SizedBox(
              height: math.min(
                cell.height * 35,
                MediaQuery.sizeOf(context).height * .82,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: cell.width * 2,
                  vertical: cell.height,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: style,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _action('Close', widget.onClose),
                      ],
                    ),
                    _gap(),
                    if (model.selectedId != null && !_creating) ...[
                      Wrap(
                        spacing: cell.width * 3,
                        runSpacing: cell.height / 2,
                        children: [
                          if (!model.isChannel)
                            _action(
                              'All teams',
                              model.operating
                                  ? null
                                  : () => unawaited(model.select(null)),
                            ),
                          Text(
                            '${model.isChannel ? 'Swarm conversation · ' : ''}${model.members.where((m) => m['enabled'] != false).length} harnesses · ${model.isChannel ? 'This swarm only · ' : ''}${model.team?['state'] ?? 'Connecting'}',
                            style: faint,
                          ),
                          if (model.team?['state'] != 'archived')
                            _action(
                              model.active
                                  ? 'Pause collaboration'
                                  : 'Resume collaboration',
                              model.operating || model.team == null
                                  ? null
                                  : () => unawaited(
                                      model.act(
                                        model.active ? 'pause' : 'resume',
                                      ),
                                    ),
                            ),
                          if (!model.isChannel &&
                              model.team?['state'] != 'archived')
                            _action(
                              model.pendingAdd
                                  ? 'Check teammate'
                                  : 'Add teammate',
                              model.operating ? null : _addMember,
                            ),
                          if (!model.isChannel)
                            _action(
                              'New question',
                              model.active
                                  ? () => setState(() {
                                      model.selectedExchange = null;
                                      _questionFocus.requestFocus();
                                    })
                                  : null,
                              key: const Key('team-compose'),
                            ),
                          if (!model.isChannel &&
                              model.team?['state'] == 'paused')
                            _action(
                              'Archive paused team',
                              model.operating
                                  ? null
                                  : () => unawaited(model.act('archive')),
                            ),
                        ],
                      ),
                      _gap(),
                    ],
                    if (model.error case final message?) ...[
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          message,
                          style: style,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      _gap(),
                    ],
                    Expanded(
                      child: _creating
                          ? _create()
                          : model.selectedId == null && !model.isChannel
                          ? _home()
                          : _detail(),
                    ),
                    _gap(),
                    Text(
                      '${terminalPromptHint(context, 'picker.complete', 'Tab')} move · ${terminalPromptHint(context, 'picker.cancel', 'Esc')} close · conversations stay with the ${model.isChannel ? 'swarm' : 'team'}',
                      style: faint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TeamSurface extends StatelessWidget {
  const _TeamSurface({required this.child, required this.width});
  final Widget child;
  final double width;
  @override
  Widget build(BuildContext context) => Dialog(
    elevation: 0,
    insetPadding: const EdgeInsets.all(20),
    backgroundColor: Colors.transparent,
    child: SizedBox(
      width: width,
      child: Material(
        color: terminalThemeFor(
          grid.AppTheme.palette.value,
          terminalThemeStore.value,
        ).background,
        shape: RoundedRectangleBorder(
          side: terminalPaneBorder(focused: true),
          borderRadius: BorderRadius.circular(kTerminalCornerRadius),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    ),
  );
}

class _TeamChoice extends StatefulWidget {
  const _TeamChoice({required this.title, required this.choices});
  final String title;
  final List<({String id, String label, String detail})> choices;
  @override
  State<_TeamChoice> createState() => _TeamChoiceState();
}

class _TeamChoiceState extends State<_TeamChoice> {
  int _index = 0;
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cell = terminalCellSizeOf(context), style = terminalContentStyle();
    final theme = terminalThemeFor(
      grid.AppTheme.palette.value,
      terminalThemeStore.value,
    );
    void move(int delta) {
      setState(
        () => _index = (_index + delta).clamp(
          0,
          math.max(0, widget.choices.length - 1),
        ),
      );
      if (_scroll.hasClients) {
        final top = _index * cell.height;
        final bottom = top + cell.height;
        final offset = top < _scroll.offset
            ? top
            : bottom > _scroll.offset + _scroll.position.viewportDimension
            ? bottom - _scroll.position.viewportDimension
            : _scroll.offset;
        _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
      }
    }

    return TerminalPromptKeys(
      cancel: () => Navigator.pop(context),
      previous: () => move(-1),
      next: () => move(1),
      accept: () {
        if (widget.choices.isNotEmpty) {
          Navigator.pop(context, widget.choices[_index].id);
        }
      },
      child: _TeamSurface(
        width: 660,
        child: Padding(
          padding: EdgeInsets.all(cell.width * 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                style: style.copyWith(color: theme.foreground),
              ),
              SizedBox(height: cell.height),
              Flexible(
                child: ListView(
                  controller: _scroll,
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < widget.choices.length; i++)
                      SizedBox(
                        height: cell.height,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            textStyle: style,
                            foregroundColor: theme.foreground,
                            backgroundColor: i == _index
                                ? theme.selection
                                : Colors.transparent,
                            minimumSize: Size.zero,
                            padding: EdgeInsets.symmetric(
                              horizontal: cell.width,
                            ),
                            shape: const RoundedRectangleBorder(),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () =>
                              Navigator.pop(context, widget.choices[i].id),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '${widget.choices[i].label}  ${widget.choices[i].detail}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
