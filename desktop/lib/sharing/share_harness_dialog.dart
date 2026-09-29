import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';

import '../shared/theme/app_theme.dart' as grid;
import '../shortcuts/app_keymap.dart';
import '../shortcuts/keymap.dart';
import '../shortcuts/keymap_commands.dart';
import '../shortcuts/keymap_keyboard.dart';
import '../terminal/terminal_text.dart';
import '../terminal/terminal_theme.dart';
import '../terminal/terminal_theme_store.dart';
import '../widgets/box_chrome.dart';
import '../widgets/terminal_prompt.dart';
import '../widgets/terminal_text_action.dart';
import 'harness_comments.dart';
import '../state/app_state.dart';
import '../ws/ws_conn.dart';

typedef ShareAction = Future<Map<String, dynamic>> Function(
  String action,
  Map<String, dynamic> payload,
);

Future<void> showShareHarnessDialog(
  BuildContext context,
  AppNotifier app,
  String machineId,
  String agentId,
  String name,
) => showTerminalPrompt<void>(
  context,
  builder: (_) => ShareHarnessDialog(
    name: name,
    manage: (action, payload) =>
        app.manageHarnessShares(machineId, agentId, action, payload),
  ),
);

class ShareHarnessDialog extends StatefulWidget {
  const ShareHarnessDialog({
    super.key,
    required this.name,
    required this.manage,
  });
  final String name;
  final ShareAction manage;
  @override
  State<ShareHarnessDialog> createState() => _ShareHarnessDialogState();
}

enum _ShareRow { access, people, options, expiry, comments, stop, copy, retry }

class _ShareHarnessDialogState extends State<ShareHarnessDialog> {
  final _focus = FocusNode(debugLabel: 'share-form');
  final _emailFocus = FocusNode(debugLabel: 'share-emails');
  final _commentsFocus = FocusNode(debugLabel: 'share-comments');
  final _commentsKey = GlobalKey();
  final _formScroll = ScrollController();
  final _sideScroll = ScrollController();
  final _rowKeys = {for (final row in _ShareRow.values) row: GlobalKey()};
  final _choiceKeys = <int, GlobalKey>{};
  _ShareRow _row = _ShareRow.copy;
  bool _options = false, _picking = false, _hideChoices = false;
  int _choice = 0;
  double _column = 8, _line = 20;

  final _emails = TextEditingController();
  List<Map<String, dynamic>> _shares = [];
  bool _loading = true, _busy = false;
  String? _error, _notice;
  int _days = 30;
  Map<String, dynamic>? _link;
  bool _collaboration = false, _manualCopy = false;
  Timer? _presence;
  int _revision = 0;
  bool _refreshing = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _presence = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_busy) unawaited(_load(quiet: true));
    });
  }

  @override
  void dispose() {
    _presence?.cancel();
    _emails.dispose();
    _focus.dispose();
    _emailFocus.dispose();
    _commentsFocus.dispose();
    _formScroll.dispose();
    _sideScroll.dispose();
    super.dispose();
  }

  String _message(Object error) =>
      error is WsRequestFailure && error.code == 'UNSUPPORTED'
      ? 'Update Harness on this machine to start sharing.'
      : error is WsRequestFailure && error.detail != null
      ? error.detail!
      : 'Could not reach this harness. Check the connection and try again.';
  void _accept(Map<String, dynamic> response) {
    final recipientId =
        _row == _ShareRow.people && _choice >= 2 && _choice - 2 < _shares.length
        ? _shares[_choice - 2]['id']
        : null;
    _collaboration = response['collaboration'] == true;
    _link = response['link'] is Map
        ? Map<String, dynamic>.from(response['link'] as Map)
        : null;
    _shares = [
      for (final row in response['shares'] as List? ?? const [])
        Map<String, dynamic>.from(row as Map),
    ];
    if (recipientId != null) {
      final index = _shares.indexWhere((share) => share['id'] == recipientId);
      _choice = index < 0 ? 0 : index + 2;
      if (_picking && index < 0) _focusPane();
    }
  }

  Future<void> _load({bool quiet = false}) async {
    if (_refreshing || _busy) return;
    _refreshing = true;
    final revision = _revision;
    try {
      final response = await widget.manage('list', const {});
      if (mounted && revision == _revision) {
        setState(() {
          _accept(response);
          _loading = false;
          if (!quiet) _error = null;
        });
      }
    } catch (error) {
      if (mounted && !quiet && revision == _revision) {
        setState(() {
          _loading = false;
          _error = _message(error);
        });
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _invite() async {
    if (_busy) return;
    final emails = _emails.text
        .split(RegExp(r'[,;\s]+'))
        .where((e) => e.isNotEmpty)
        .map((e) => e.toLowerCase())
        .toSet()
        .toList();
    if (emails.isEmpty ||
        emails.length > 20 ||
        emails.any((e) => !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e))) {
      setState(() {
        _error = 'Enter up to 20 valid email addresses, separated by commas.';
        _notice = null;
      });
      return;
    }
    setState(() {
      _revision++;
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final response = await widget.manage('invite', {
        'emails': emails,
        'days': _days,
      });
      if (mounted) {
        setState(() {
          _accept(response);
          _emails.clear();
          _notice = _shares.any((s) => s['error'] != null)
              ? 'Some invitations could not be shared. Check the details below.'
              : _shares.any((s) => s['pending'] == true)
              ? 'Invitations saved. They will appear when the connection returns.'
              : '${emails.length == 1 ? '1 person now has' : '${emails.length} people now have'} view-only access.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_picking && _row == _ShareRow.people) _focusPane();
      }
    }
  }

  Future<void> _remove(String id) async {
    if (_busy) return;
    setState(() {
      _revision++;
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final response = await widget.manage('remove', {'id': id});
      if (mounted) {
        setState(() {
          _accept(response);
          _notice = 'Access removed.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_picking && _row == _ShareRow.people) _focusPane();
      }
    }
  }

  Future<void> _linkAction(String visibility, {bool copy = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _revision++;
      _error = null;
      _notice = null;
    });
    try {
      if (!copy || _link == null || _link?['visibility'] == 'off') {
        _accept(await widget.manage('link', {'visibility': visibility}));
      }
      if (copy && _link?['pending'] != true && _link?['error'] == null) {
        final url = _link?['url'] as String?;
        if (url == null) throw StateError('Link unavailable');
        await Clipboard.setData(ClipboardData(text: url));
        _manualCopy = false;
        if (mounted) setState(() => _notice = 'Link copied.');
      } else if (mounted) {
        setState(
          () => _notice =
              _link?['error'] as String? ??
              (_link?['pending'] == true
                  ? 'Saved. Waiting for the connection before the link is ready.'
                  : visibility == 'off'
                  ? 'Sharing stopped.'
                  : 'Access updated.'),
        );
      }
    } catch (error) {
      _manualCopy = copy && _link?['url'] != null;
      if (mounted) {
        setState(
          () => _error = copy && _link?['url'] != null
              ? 'Could not copy. Select the link below and copy it.'
              : _message(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _disabled => _busy || _loading;
  bool get _isPublic => _link?['visibility'] == 'public';
  bool get _linkActive => _link != null && _link?['visibility'] != 'off';
  bool get _composing =>
      _emails.value.composing.isValid && !_emails.value.composing.isCollapsed;
  bool get _hasChoices =>
      _row == _ShareRow.access ||
      _row == _ShareRow.people ||
      _row == _ShareRow.expiry ||
      _row == _ShareRow.comments;
  List<_ShareRow> get _rows => [
    if (_collaboration) _ShareRow.access,
    if (!_isPublic) _ShareRow.people,
    _ShareRow.options,
    if (_options) ...[
      if (!_isPublic) _ShareRow.expiry,
      if (_collaboration) _ShareRow.comments,
      if (_linkActive) _ShareRow.stop,
    ],
    _ShareRow.copy,
    if (_error != null) _ShareRow.retry,
  ];

  String _label(_ShareRow row) => switch (row) {
    _ShareRow.access => 'Access',
    _ShareRow.people => 'People',
    _ShareRow.options => 'Options',
    _ShareRow.expiry => 'Invite for',
    _ShareRow.comments => 'Comments',
    _ShareRow.stop => 'Stop sharing',
    _ShareRow.copy => _busy ? 'Saving…' : 'Copy link',
    _ShareRow.retry => 'Retry',
  };
  String? _value(_ShareRow row) => switch (row) {
    _ShareRow.access => _isPublic ? 'Public' : 'Private',
    _ShareRow.people =>
      _shares.isEmpty
          ? 'Only you'
          : '${_shares.length} ${_shares.length == 1 ? 'person' : 'people'}',
    _ShareRow.options => _options ? '[-]' : '[+]',
    _ShareRow.expiry => '$_days days',
    _ShareRow.comments => 'Open discussion',
    _ => null,
  };
  bool _enabled(_ShareRow row) =>
      !_disabled && (row != _ShareRow.copy || _collaboration);

  void _select(_ShareRow row, {bool enter = false}) {
    if (!_enabled(row)) return;
    setState(() {
      _row = row;
      _picking = enter && _hasChoices;
      _hideChoices = false;
      _choice = switch (row) {
        _ShareRow.access => _isPublic ? 1 : 0,
        _ShareRow.expiry => const [7, 30, 90].indexOf(_days),
        _ => 0,
      };
    });
    _focusPane();
  }

  void _focusPane() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_picking && _row == _ShareRow.people && _choice == 0) {
        _emailFocus.requestFocus();
      } else if (_picking && _row == _ShareRow.comments) {
        _commentsFocus.requestFocus();
      } else {
        _focus.requestFocus();
      }
      final target =
          (_picking ? _choiceKeys[_choice] : _rowKeys[_row])?.currentContext;
      if (target != null) Scrollable.ensureVisible(target, alignment: .5);
    });
  }

  void _backToForm({bool selectCopy = false}) {
    setState(() {
      _picking = false;
      _hideChoices = true;
      if (selectCopy) _row = _ShareRow.copy;
    });
    _focusPane();
  }

  void _cancel() {
    if (_picking || (_hasChoices && !_hideChoices)) {
      _backToForm();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _switchPane() {
    if (_disabled || !_hasChoices) return;
    if (_picking) {
      _backToForm();
    } else {
      setState(() {
        _picking = true;
        _hideChoices = false;
      });
      _focusPane();
    }
  }

  void _step(int delta) {
    if (_disabled) return;
    if (_picking) {
      final count = switch (_row) {
        _ShareRow.access => 2,
        _ShareRow.expiry => 3,
        _ShareRow.people => _shares.length + 2,
        _ => 0,
      };
      if (count == 0) return;
      setState(() => _choice = (_choice + delta) % count);
      _focusPane();
    } else {
      final rows = _rows.where(_enabled).toList();
      if (rows.isNotEmpty) {
        _select(rows[(rows.indexOf(_row) + delta) % rows.length]);
      }
    }
  }

  Future<void> _chooseVisibility(int index) async {
    final visibility = index == 0 ? 'private' : 'public';
    if (_linkActive && _link?['visibility'] == visibility) {
      _backToForm(selectCopy: true);
      return;
    }
    await _linkAction(visibility);
    if (mounted && _error == null) _backToForm(selectCopy: true);
  }

  void _activate() {
    if (_disabled) return;
    if (!_picking) {
      if (!_enabled(_row)) return;
      switch (_row) {
        case _ShareRow.options:
          _toggleOptions();
        case _ShareRow.copy:
          unawaited(_linkAction('private', copy: true));
        case _ShareRow.stop:
          unawaited(_stopSharing());
        case _ShareRow.retry:
          unawaited(_load());
        default:
          _switchPane();
      }
    } else {
      switch (_row) {
        case _ShareRow.access:
          unawaited(_chooseVisibility(_choice));
        case _ShareRow.expiry:
          setState(() => _days = const [7, 30, 90][_choice]);
          _backToForm(selectCopy: true);
        case _ShareRow.people:
          if (_choice < 2) {
            if (_emails.text.trim().isNotEmpty) unawaited(_invite());
          } else if (_choice - 2 < _shares.length) {
            unawaited(_remove(_shares[_choice - 2]['id'] as String));
          }
        default:
          break;
      }
    }
  }

  Future<void> _stopSharing() async {
    await _linkAction('off');
    if (mounted && _error == null) _backToForm(selectCopy: true);
  }

  void _toggleOptions() {
    if (_disabled) return;
    setState(() {
      _options = !_options;
      if (!_rows.contains(_row)) {
        _row = _ShareRow.options;
        _picking = false;
        _hideChoices = true;
      }
    });
    _focusPane();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_composing) return KeyEventResult.skipRemainingHandlers;
    if (_picking && _row == _ShareRow.comments) return KeyEventResult.ignored;
    final stroke = keyStrokeForEvent(event);
    final map =
        KeymapTheme.of(context, listen: false)?.current ?? harnessDefaultKeymap;
    final command = stroke == null
        ? null
        : map.match(KeymapContext.picker, [stroke]).command;
    final action = _keyActions[command];
    // Left/right retain caret behavior while an email address is being edited.
    if (_emailFocus.hasFocus &&
        (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight)) {
      return KeyEventResult.ignored;
    }
    if (action != null) {
      if (event is! KeyRepeatEvent ||
          command == 'picker.next' ||
          command == 'picker.previous') {
        action();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.handled;
    }
    if (_emailFocus.hasFocus) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.space &&
        _row == _ShareRow.options) {
      if (event is KeyDownEvent) _activate();
      return KeyEventResult.handled;
    }
    // Like Cmd-N, typing on People enters its editor with that first character.
    final character = event.character;
    if (_row == _ShareRow.people &&
        !_disabled &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isControlPressed &&
        character != null &&
        character.isNotEmpty &&
        character.codeUnitAt(0) >= 32) {
      _emails.text += character;
      _emails.selection = TextSelection.collapsed(offset: _emails.text.length);
      setState(() {
        _picking = true;
        _hideChoices = false;
        _choice = 0;
      });
      _focusPane();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Map<String, VoidCallback> get _keyActions => {
    'picker.accept': _activate,
    'picker.cancel': _cancel,
    'picker.next': () => _step(1),
    'picker.previous': () => _step(-1),
    'picker.complete': _switchPane,
    'picker.complete_back': _switchPane,
    'picker.control_next': () {
      if (!_picking) _switchPane();
    },
    'picker.control_previous': () {
      if (_picking) _backToForm();
    },
    'picker.more_options': _toggleOptions,
  };

  @override
  Widget build(BuildContext context) {
    grid.AppTheme.watch(context);
    TerminalFontScope.watch(context);
    return ListenableBuilder(
      listenable: Listenable.merge([terminalFontStore, terminalThemeStore]),
      builder: (context, _) {
        final cell = terminalCellSizeOf(context);
        _column = cell.width;
        _line = cell.height;
        final theme = terminalThemeFor(
          grid.AppTheme.palette.value,
          terminalThemeStore.value,
        );
        final style = terminalContentStyle(color: theme.foreground);
        final muted = theme.muted;
        Widget surface(Key key, Widget child) => Material(
          key: key,
          color: theme.background,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kTerminalCornerRadius),
            side: terminalPaneBorder(focused: true),
          ),
          clipBehavior: Clip.antiAlias,
          child: DefaultTextStyle(style: style, child: child),
        );
        return KeymapRegion(
          contextKind: KeymapContext.picker,
          composing: () => _composing,
          actions: _keyActions,
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _key,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: _column * 2,
                vertical: _line,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = math.max(
                    1,
                    (constraints.maxWidth / _column).floor(),
                  );
                  final formColumns = math.min(56, columns);
                  final left = (columns - formColumns) ~/ 2;
                  final available = columns - left - formColumns - 1;
                  final beside = available >= 28;
                  final showChoices = _hasChoices && !_hideChoices;
                  final replaceForm = _picking && !beside;
                  final formWidth = formColumns * _column;
                  final rows = _rows;
                  var formRows = 5 + rows.length + 3;
                  if (rows.contains(_ShareRow.people)) formRows++;
                  // Copy follows the fields with one blank row; notices get their own rows.
                  for (final message in _messages) {
                    final painter =
                        TextPainter(
                          text: TextSpan(text: message, style: style),
                          textDirection: TextDirection.ltr,
                          textScaler: MediaQuery.textScalerOf(context),
                        )..layout(
                          maxWidth: math.max(_column, formWidth - _column * 4),
                        );
                    formRows += 1 + (painter.height / _line).ceil();
                    painter.dispose();
                  }
                  final formHeight = math.min(
                    constraints.maxHeight,
                    formRows * _line,
                  );
                  final sideHeight = math.min(
                    constraints.maxHeight,
                    ((_row == _ShareRow.access
                                ? 12
                                : _row == _ShareRow.expiry
                                ? 11
                                : _row == _ShareRow.people
                                ? math.min(20, 12 + _shares.length * 4)
                                : 20) +
                            (replaceForm ? 2 : 0)) *
                        _line,
                  );
                  final top = math.max(
                    0.0,
                    ((constraints.maxHeight - formHeight) / (2 * _line))
                            .floor() *
                        _line,
                  );
                  final sideTop = math.min(
                    top,
                    constraints.maxHeight - sideHeight,
                  );
                  return Stack(
                    children: [
                      Positioned(
                        left: left * _column,
                        top: replaceForm ? sideTop : top,
                        width: formWidth,
                        height: replaceForm ? sideHeight : formHeight,
                        child: surface(
                          const ValueKey('share-form-surface'),
                          replaceForm
                              ? _sidePane(
                                  theme.foreground,
                                  muted,
                                  theme.selection,
                                  narrow: true,
                                )
                              : _formPane(
                                  theme.foreground,
                                  muted,
                                  theme.selection,
                                ),
                        ),
                      ),
                      if (showChoices && beside)
                        Positioned(
                          left: (left + formColumns + 1) * _column,
                          top: sideTop,
                          width: math.min(40, available) * _column,
                          height: sideHeight,
                          child: surface(
                            const ValueKey('share-choices-surface'),
                            _sidePane(theme.foreground, muted, theme.selection),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  List<String> get _messages => [
    if (_loading) 'Loading sharing…',
    if (!_loading && !_collaboration && _error == null)
      'Update Harness on this machine to share browser links and comments.',
    ?_error,
    ?_notice,
    if (_link?['error'] != null && _link?['error'] != _error)
      '${_link!['error']}',
    if (_manualCopy && _link?['url'] is String) _link!['url'] as String,
  ];

  Widget _plainRow({
    required String label,
    String? value,
    required bool selected,
    required bool enabled,
    required Color foreground,
    required Color muted,
    required Color selection,
    required VoidCallback onTap,
    Key? key,
    Key? rowKey,
  }) => Semantics(
    key: key,
    label: value == null ? label : '$label, $value',
    button: true,
    selected: selected,
    enabled: enabled,
    onTap: enabled ? onTap : null,
    excludeSemantics: true,
    child: MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          key: rowKey,
          height: _line,
          color: selected && enabled ? selection : Colors.transparent,
          padding: EdgeInsets.symmetric(horizontal: _column),
          alignment: Alignment.centerLeft,
          child: value == null
              ? Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: terminalContentStyle(
                    color: enabled ? foreground : muted,
                  ),
                )
              : Row(
                  children: [
                    SizedBox(
                      width: _column * 11,
                      child: Text(
                        label,
                        style: terminalContentStyle(color: muted),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: terminalContentStyle(
                          color: enabled ? foreground : muted,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    ),
  );

  Widget _formPane(Color foreground, Color muted, Color selection) =>
      SingleChildScrollView(
        controller: _formScroll,
        padding: EdgeInsets.symmetric(horizontal: _column, vertical: _line),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: _column),
              child: Text(
                'Share ${widget.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: terminalContentStyle(color: foreground)
                    .copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            SizedBox(height: _line),
            for (final row in _rows) ...[
              if (row == _ShareRow.people ||
                  row == _ShareRow.options ||
                  row == _ShareRow.copy)
                SizedBox(height: _line),
              _plainRow(
                key: ValueKey('share-field-${row.name}'),
                rowKey: _rowKeys[row],
                label: _label(row),
                value: _value(row),
                selected: _row == row && !_picking,
                enabled: _enabled(row),
                foreground: foreground,
                muted: muted,
                selection: selection,
                onTap: () {
                  _select(row);
                  _activate();
                },
              ),
            ],
            if (!_picking) ..._messageWidgets(foreground),
            SizedBox(height: _line),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: _column),
              child: Text(
                'Keep your machine online.',
                style: terminalContentStyle(color: muted),
              ),
            ),
          ],
        ),
      );

  List<Widget> _messageWidgets(Color foreground) => [
    for (final message in _messages) ...[
      SizedBox(height: _line),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: _column),
        child: Semantics(
          liveRegion: true,
          child: _manualCopy && message == _link?['url']
              ? SelectableText(
                  message,
                  style: terminalContentStyle(color: foreground),
                )
              : Text(message, style: terminalContentStyle(color: foreground)),
        ),
      ),
    ],
  ];

  Widget _sidePane(
    Color foreground,
    Color muted,
    Color selection, {
    bool narrow = false,
  }) {
    Widget choice(
      String label,
      int index,
      VoidCallback activate, {
      bool enabled = true,
      String? value,
    }) => _plainRow(
      key: ValueKey('share-choice-$index'),
      rowKey: _choiceKeys.putIfAbsent(index, GlobalKey.new),
      label: label,
      value: value,
      selected: _picking && _choice == index,
      enabled: enabled && !_disabled,
      foreground: foreground,
      muted: muted,
      selection: selection,
      onTap: () {
        setState(() {
          _picking = true;
          _choice = index;
        });
        activate();
      },
    );
    Widget note(String text) => Padding(
      padding: EdgeInsets.symmetric(horizontal: _column),
      child: Text(text, style: terminalContentStyle(color: muted)),
    );
    if (_row == _ShareRow.comments && _picking) {
      return TerminalPromptKeys(
        focusNode: _commentsFocus,
        cancel: _backToForm,
        child: Padding(
          padding: EdgeInsets.all(_column * 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TerminalTextAction(
                  label: 'Back',
                  onPressed: _backToForm,
                ),
              ),
              SizedBox(height: _line),
              Expanded(
                child: HarnessComments(
                  key: _commentsKey,
                  manage: widget.manage,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SingleChildScrollView(
      controller: _sideScroll,
      padding: EdgeInsets.symmetric(horizontal: _column, vertical: _line),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (narrow) ...[
            _plainRow(
              key: const ValueKey('share-back'),
              label: '< Back',
              selected: false,
              enabled: true,
              foreground: foreground,
              muted: muted,
              selection: selection,
              onTap: _backToForm,
            ),
            SizedBox(height: _line),
          ],
          if (_row == _ShareRow.access) ...[
            choice('Private', 0, () => unawaited(_chooseVisibility(0))),
            note('Only invited emails can view and comment.'),
            SizedBox(height: _line),
            choice('Public', 1, () => unawaited(_chooseVisibility(1))),
            note('Anyone with the link can view. Sign in to comment.'),
            SizedBox(height: _line),
            note('Viewers cannot control your harness.'),
          ],
          if (_row == _ShareRow.expiry) ...[
            for (var i = 0; i < 3; i++)
              choice('${const [7, 30, 90][i]} days', i, () {
                setState(() => _days = const [7, 30, 90][i]);
                _backToForm(selectCopy: true);
              }),
            SizedBox(height: _line),
            note(
              'Applies to new invitations. Your link stays active until you stop sharing.',
            ),
          ],
          if (_row == _ShareRow.people) ...[
            Padding(
              padding: EdgeInsets.symmetric(horizontal: _column),
              child: TextField(
                key: _choiceKeys.putIfAbsent(0, GlobalKey.new),
                controller: _emails,
                focusNode: _emailFocus,
                enabled: !_disabled,
                keyboardType: TextInputType.emailAddress,
                style: terminalContentStyle(color: foreground),
                cursorWidth: 2,
                decoration: InputDecoration(
                  hintText: 'Add emails',
                  hintStyle: terminalContentStyle(color: muted),
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                onTap: () => setState(() {
                  _picking = true;
                  _choice = 0;
                }),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (!_composing && !_disabled) unawaited(_invite());
                },
              ),
            ),
            choice(
              'Add people',
              1,
              () => unawaited(_invite()),
              enabled: _emails.text.trim().isNotEmpty,
            ),
            note('Invited for $_days days. Copy and send them the link.'),
            SizedBox(height: _line),
            if (_shares.isEmpty) note('No invited people yet.'),
            for (final (index, share) in _shares.indexed) ...[
              note('${share['email']}'),
              note(_recipientStatus(share)),
              choice(
                'Remove ${share['email']}',
                index + 2,
                () => unawaited(_remove(share['id'] as String)),
              ),
              SizedBox(height: _line),
            ],
            note('Viewers can comment; they cannot control your harness.'),
          ],
          if (_row == _ShareRow.comments) note('Enter to open the discussion.'),
          if (_picking) ..._messageWidgets(foreground),
        ],
      ),
    );
  }

  String _recipientStatus(Map<String, dynamic> share) {
    final expires = DateTime.tryParse(share['expiresAt'] as String? ?? '')
        ?.toLocal();
    return share['error'] as String? ??
        (share['pending'] == true
            ? 'Waiting for connection'
            : share['expired'] == true
            ? 'Expired · add again to renew'
            : (share['watching'] as num? ?? 0) > 0
            ? 'Watching now · Can view'
            : 'Can view${expires == null ? '' : ' · Until ${expires.month}/${expires.day}/${expires.year}'}');
  }
}
