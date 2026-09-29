import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/tmux_panes.dart';
import '../shared/theme/app_theme.dart' as grid;
import '../shared/widgets/app_dialog.dart';
import '../terminal/terminal_text.dart';
import '../terminal/terminal_theme.dart';
import '../terminal/terminal_theme_store.dart';
import 'box_chrome.dart';
import 'terminal_text_action.dart';

/// What the picker needs from the app: the machine's three borrowed-tmux RPCs
/// (`AppNotifier.listTmuxPanes` / `enrollTmuxPane`) and a way to put a terminal
/// on screen. A seam so the widget test needs no daemon.
class TmuxPanePickerActions {
  const TmuxPanePickerActions({
    required this.list,
    required this.enroll,
    required this.open,
  });

  final Future<TmuxPaneListing> Function() list;
  final Future<Agent> Function(TmuxPane pane, String serverIdentity) enroll;
  final Future<void> Function(String agentId) open;
}

Future<void> showTmuxPanePicker(
  BuildContext context, {
  required String machineLabel,
  required TmuxPanePickerActions actions,
}) => showAppDialog<void>(
  context: context,
  builder: (_) => TmuxPanePicker(machineLabel: machineLabel, actions: actions),
);

/// The tmux panes already running on one machine, and a way to add one as a
/// terminal. Listing changes nothing; only Enter (or a click) on an available
/// row enrolls it, and only on the tmux server the list was read from.
class TmuxPanePicker extends StatefulWidget {
  const TmuxPanePicker({
    super.key,
    required this.machineLabel,
    required this.actions,
  });

  final String machineLabel;
  final TmuxPanePickerActions actions;

  @override
  State<TmuxPanePicker> createState() => _TmuxPanePickerState();
}

class _TmuxPanePickerState extends State<TmuxPanePicker> {
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'tmux panes');
  TmuxPaneListing? _listing;
  bool _loading = true;
  String? _selected, _opening, _error;
  int _generation = 0;

  List<TmuxPane> get _rows => _listing?.panes ?? const [];

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  /// One read, on open and on an explicit Refresh — never on a timer.
  Future<void> _refresh({String? keepError}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = keepError;
    });
    try {
      final listing = await widget.actions.list();
      if (!mounted || generation != _generation) return;
      setState(() {
        _listing = listing;
        _loading = false;
        if (!_rows.any((pane) => pane.paneId == _selected)) _selected = null;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _listing = null;
        _selected = null;
        _error = error is TmuxPaneError
            ? error.message
            : error is StateError
            ? error.message
            : 'Could not read tmux on ${widget.machineLabel}.';
      });
    }
  }

  void _move(int delta) {
    if (_rows.isEmpty || _opening != null) return;
    final current = _rows.indexWhere((pane) => pane.paneId == _selected);
    final index = current < 0
        ? (delta > 0 ? 0 : _rows.length - 1)
        : (current + delta).clamp(0, _rows.length - 1);
    setState(() => _selected = _rows[index].paneId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final line = terminalCellSizeOf(context).height;
      final top = index * line;
      final bottom = top + line;
      final viewport = _scroll.position.viewportDimension;
      final offset = top < _scroll.offset
          ? top
          : bottom > _scroll.offset + viewport
          ? bottom - viewport
          : _scroll.offset;
      _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  bool _openable(TmuxPane pane) =>
      pane.state == TmuxPaneState.available ||
      (pane.state == TmuxPaneState.enrolled && pane.agentId != null);

  Future<void> _open(TmuxPane pane) async {
    final identity = _listing?.serverIdentity;
    if (_opening != null || !_openable(pane) || identity == null) return;
    setState(() {
      _opening = pane.paneId;
      _error = null;
    });
    try {
      final agentId = pane.state == TmuxPaneState.enrolled
          ? pane.agentId!
          : (await widget.actions.enroll(pane, identity)).id;
      await widget.actions.open(agentId);
      if (mounted) Navigator.of(context).pop();
    } on TmuxPaneError catch (error) {
      if (!mounted) return;
      // The server restarted, or the pane changed hands: the listing is stale.
      if (error.code == 'TMUX_SERVER_CHANGED' ||
          error.code == 'TMUX_PANE_NOT_FOUND' ||
          error.code == 'TMUX_PANE_MANAGED' ||
          error.code == 'TMUX_PANE_SHARED_WINDOW') {
        _opening = null;
        await _refresh(keepError: error.message);
        return;
      }
      setState(() => _error = error.message);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StateError
              ? error.message
              : 'Could not open this pane. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _status(TmuxPane pane) {
    if (pane.paneId == _opening) {
      return pane.state == TmuxPaneState.enrolled ? 'Opening…' : 'Adding…';
    }
    return switch (pane.state) {
      TmuxPaneState.available => '',
      TmuxPaneState.enrolled => 'Added',
      _ => pane.unavailableReason ?? '',
    };
  }

  /// `~` for the home folder a macOS or Linux path starts with.
  static String _shortPath(String path) {
    final home = RegExp(r'^/(?:Users|home)/[^/]+(?=/|$)').firstMatch(path);
    return home == null ? path : '~${path.substring(home.end)}';
  }

  @override
  Widget build(BuildContext context) {
    TerminalFontScope.watch(context);
    grid.AppTheme.watch(context);
    return ValueListenableBuilder(
      valueListenable: terminalThemeStore,
      builder: (context, _, _) {
        final theme = terminalThemeFor(
          grid.AppTheme.palette.value,
          terminalThemeStore.value,
        );
        final cell = terminalCellSizeOf(context);
        final style = terminalContentStyle(color: theme.foreground);
        final muted = style.copyWith(
          color: theme.foreground.withValues(alpha: .55),
        );
        return LayoutBuilder(
          builder: (context, constraints) {
            final columns = math.max(
              24,
              math.min(96, (constraints.maxWidth / cell.width).floor() - 4),
            );
            final width = cell.width * columns;
            // Padding, title, blank, rows, then blank + error — whole rows.
            final listRows = _rows.isEmpty ? 1 : math.min(16, _rows.length);
            final rows = 2 + 2 + listRows + (_error == null ? 0 : 2);
            final height = math.min(
              math.max(0.0, constraints.maxHeight - cell.height * 2),
              cell.height * rows,
            );
            final addressWidth = math.min(24, columns ~/ 4);
            final commandWidth = math.min(12, columns ~/ 6);
            const statusWidth = 16;
            return Dialog(
              insetPadding: EdgeInsets.symmetric(
                horizontal: cell.width,
                vertical: cell.height,
              ),
              backgroundColor: theme.background,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kTerminalCornerRadius),
                side: terminalPaneBorder(focused: true),
              ),
              child: SizedBox(
                key: const ValueKey('tmux-pane-picker'),
                width: width,
                height: height,
                child: Focus(
                  focusNode: _focus,
                  autofocus: true,
                  onKeyEvent: (node, event) {
                    if (!node.hasPrimaryFocus ||
                        event is! KeyDownEvent ||
                        HardwareKeyboard.instance.isMetaPressed ||
                        HardwareKeyboard.instance.isControlPressed ||
                        HardwareKeyboard.instance.isAltPressed) {
                      return KeyEventResult.ignored;
                    }
                    final key = event.logicalKey;
                    if (key == LogicalKeyboardKey.arrowDown ||
                        key == LogicalKeyboardKey.arrowUp) {
                      _move(key == LogicalKeyboardKey.arrowDown ? 1 : -1);
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.enter ||
                        key == LogicalKeyboardKey.numpadEnter) {
                      final pane = _rows
                          .where((pane) => pane.paneId == _selected)
                          .firstOrNull;
                      if (pane != null) unawaited(_open(pane));
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.keyR && _opening == null) {
                      unawaited(_refresh());
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: DefaultTextStyle(
                    style: style,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: cell.width * 2,
                        vertical: cell.height,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: cell.height,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'tmux panes on ${widget.machineLabel}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                TerminalTextAction(
                                  key: const ValueKey('tmux-pane-refresh'),
                                  label: 'Refresh',
                                  onPressed: _loading || _opening != null
                                      ? null
                                      : () => unawaited(_refresh()),
                                ),
                                SizedBox(width: cell.width * 2),
                                TerminalTextAction(
                                  label: 'x',
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: cell.height),
                          Expanded(
                            child: _rows.isEmpty
                                ? Text(
                                    _loading
                                        ? 'Reading tmux…'
                                        : _listing == null
                                        ? ''
                                        : _listing!.serverIdentity == null
                                        ? 'No tmux server is running on ${widget.machineLabel}.'
                                        : 'No tmux panes.',
                                    style: muted,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : ListView.builder(
                                    controller: _scroll,
                                    itemCount: _rows.length,
                                    itemExtent: cell.height,
                                    itemBuilder: (context, index) {
                                      final pane = _rows[index];
                                      final selected = pane.paneId == _selected;
                                      final openable =
                                          _openable(pane) && _opening == null;
                                      final onTap = openable
                                          ? () => unawaited(_open(pane))
                                          : null;
                                      final rowStyle = _openable(pane)
                                          ? style
                                          : muted;
                                      final status = _status(pane);
                                      final path = _shortPath(pane.cwd);
                                      return Semantics(
                                        label: [
                                          pane.address,
                                          if (pane.command.isNotEmpty)
                                            pane.command,
                                          if (pane.cwd.isNotEmpty) pane.cwd,
                                          if (status.isNotEmpty) status,
                                        ].join(', '),
                                        button: true,
                                        excludeSemantics: true,
                                        enabled: onTap != null,
                                        onTap: onTap,
                                        selected: selected,
                                        child: MouseRegion(
                                          cursor: onTap != null
                                              ? SystemMouseCursors.click
                                              : SystemMouseCursors.basic,
                                          onEnter: (_) {
                                            if (_opening == null) {
                                              setState(
                                                () => _selected = pane.paneId,
                                              );
                                            }
                                          },
                                          child: GestureDetector(
                                            key: ValueKey(
                                              'tmux-pane:${pane.paneId}',
                                            ),
                                            behavior: HitTestBehavior.opaque,
                                            onTap: onTap,
                                            child: ColoredBox(
                                              color: selected
                                                  ? theme.selection
                                                  : Colors.transparent,
                                              child: DefaultTextStyle(
                                                style: rowStyle,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                child: Row(
                                                  children: [
                                                    SizedBox(
                                                      width:
                                                          cell.width *
                                                          addressWidth,
                                                      child: Text(pane.address),
                                                    ),
                                                    SizedBox(
                                                      width: cell.width * 2,
                                                    ),
                                                    SizedBox(
                                                      width:
                                                          cell.width *
                                                          commandWidth,
                                                      child: Text(pane.command),
                                                    ),
                                                    SizedBox(
                                                      width: cell.width * 2,
                                                    ),
                                                    Expanded(
                                                      child: Tooltip(
                                                        message: pane.cwd,
                                                        child: Text(
                                                          path,
                                                          style: muted,
                                                        ),
                                                      ),
                                                    ),
                                                    SizedBox(
                                                      width: cell.width * 2,
                                                    ),
                                                    SizedBox(
                                                      width:
                                                          cell.width *
                                                          statusWidth,
                                                      child: Text(
                                                        status,
                                                        textAlign:
                                                            TextAlign.right,
                                                        style: muted,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                          if (_error != null) ...[
                            SizedBox(height: cell.height),
                            SizedBox(
                              height: cell.height,
                              child: Text(
                                _error!,
                                key: const ValueKey('tmux-pane-error'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: style.copyWith(color: theme.red),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
