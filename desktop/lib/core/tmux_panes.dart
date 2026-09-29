/// Existing tmux panes on a machine's default tmux server, as its daemon lists them
/// (cli/src/lib/externalTmux.ts `tmux_panes_list`). Only an explicit enroll turns one
/// into a terminal Harness can open; listing never changes anything on the machine.
library;

/// What Harness may do with a listed pane.
enum TmuxPaneState {
  /// Can be added.
  available,

  /// Already added on this machine; opening it opens that terminal.
  enrolled,

  /// A Harness session's own pane.
  managed,

  /// Shares its window with other panes; Harness opens whole windows only.
  sharedWindow,
}

TmuxPaneState? _stateFrom(Object? value) => switch (value) {
  'available' => TmuxPaneState.available,
  'enrolled' => TmuxPaneState.enrolled,
  'managed' => TmuxPaneState.managed,
  'shared_window' => TmuxPaneState.sharedWindow,
  _ => null,
};

class TmuxPane {
  const TmuxPane({
    required this.paneId,
    required this.sessionName,
    required this.windowIndex,
    required this.paneIndex,
    required this.windowName,
    required this.command,
    required this.cwd,
    required this.state,
    this.agentId,
  });

  final String paneId;
  final String sessionName;
  final int windowIndex;
  final int paneIndex;
  final String windowName;
  final String command;
  final String cwd;
  final TmuxPaneState state;

  /// The terminal this pane is enrolled as, when [state] is [TmuxPaneState.enrolled].
  final String? agentId;

  /// `session:window.pane`, the address a tmux user types.
  String get address => '$sessionName:$windowIndex.$paneIndex';

  bool get canEnroll => state == TmuxPaneState.available;

  /// Why the pane cannot be added, or null when it can (or is already added).
  String? get unavailableReason => switch (state) {
    TmuxPaneState.managed => 'Harness session',
    TmuxPaneState.sharedWindow => 'Split window',
    _ => null,
  };

  /// Null for a row that does not parse; the list shows what it can read.
  static TmuxPane? fromJson(Object? json) {
    if (json is! Map) return null;
    final paneId = json['paneId'];
    final sessionName = json['sessionName'];
    final windowIndex = json['windowIndex'];
    final paneIndex = json['paneIndex'];
    final state = _stateFrom(json['state']);
    if (paneId is! String ||
        !RegExp(r'^%\d+$').hasMatch(paneId) ||
        sessionName is! String ||
        windowIndex is! int ||
        paneIndex is! int ||
        state == null) {
      return null;
    }
    final agentId = json['agentId'];
    return TmuxPane(
      paneId: paneId,
      sessionName: sessionName,
      windowIndex: windowIndex,
      paneIndex: paneIndex,
      windowName: json['windowName'] is String
          ? json['windowName'] as String
          : '',
      command: json['command'] is String ? json['command'] as String : '',
      cwd: json['cwd'] is String ? json['cwd'] as String : '',
      state: state,
      agentId: agentId is String && agentId.isNotEmpty ? agentId : null,
    );
  }
}

/// One `tmux_panes_list` answer. [serverIdentity] is the server incarnation the listing was
/// read from; enrolling sends it back so a restarted server is refused instead of matched.
class TmuxPaneListing {
  const TmuxPaneListing({required this.serverIdentity, required this.panes});

  /// Null when no tmux server is running on the machine.
  final String? serverIdentity;
  final List<TmuxPane> panes;

  factory TmuxPaneListing.fromJson(Map<String, dynamic> json) {
    final server = json['server'];
    final identity = server is Map ? server['serverIdentity'] : null;
    final panes = json['panes'];
    return TmuxPaneListing(
      serverIdentity: identity is String && identity.isNotEmpty
          ? identity
          : null,
      panes: panes is List
          ? panes.map(TmuxPane.fromJson).whereType<TmuxPane>().toList()
          : const [],
    );
  }
}

/// A daemon refusal or transport failure, worded for the picker.
class TmuxPaneError implements Exception {
  const TmuxPaneError(this.code, this.message);
  final String code;
  final String message;

  /// Plain wording for the codes the daemon returns; its own detail otherwise.
  static TmuxPaneError fromReply(Map<String, dynamic> reply) {
    final code = reply['error'] is String ? reply['error'] as String : 'ERROR';
    final detail = reply['detail'] is String ? reply['detail'] as String : '';
    final message = switch (code) {
      'OWNER_REQUIRED' => 'Only the machine\'s owner can add tmux panes.',
      'TMUX_UNAVAILABLE' => 'tmux is not available on this machine.',
      'UNSUPPORTED' => 'This machine\'s Harness is too old to add tmux panes.',
      'TMUX_SERVER_CHANGED' =>
        'tmux restarted since the list was read. The list was refreshed.',
      _ => detail.isNotEmpty ? detail : code,
    };
    return TmuxPaneError(code, message);
  }

  @override
  String toString() => message;
}
