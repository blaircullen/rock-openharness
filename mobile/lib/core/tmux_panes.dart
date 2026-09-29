/// Read-only listing of a machine's default tmux server.
enum TmuxPaneState { available, enrolled, managed, sharedWindow }

class TmuxPane {
  const TmuxPane({
    required this.paneId,
    required this.address,
    required this.command,
    required this.cwd,
    required this.state,
    this.agentId,
  });

  final String paneId;
  final String address;
  final String command;
  final String cwd;
  final TmuxPaneState state;
  final String? agentId;
  bool get canEnroll => state == TmuxPaneState.available;
  String? get unavailableReason => switch (state) {
    TmuxPaneState.managed => 'Harness session',
    TmuxPaneState.sharedWindow => 'Split window',
    _ => null,
  };

  static TmuxPane? fromJson(Object? value) {
    if (value is! Map ||
        value['paneId'] is! String ||
        !RegExp(r'^%\d+$').hasMatch(value['paneId'] as String) ||
        value['sessionName'] is! String ||
        value['windowIndex'] is! int ||
        value['paneIndex'] is! int) {
      return null;
    }
    final state = switch (value['state']) {
      'available' => TmuxPaneState.available,
      'enrolled' => TmuxPaneState.enrolled,
      'managed' => TmuxPaneState.managed,
      'shared_window' => TmuxPaneState.sharedWindow,
      _ => null,
    };
    if (state == null) {
      return null;
    }
    return TmuxPane(
      paneId: value['paneId'] as String,
      address:
          '${value['sessionName']}:${value['windowIndex']}.${value['paneIndex']}',
      command: value['command'] is String ? value['command'] as String : '',
      cwd: value['cwd'] is String ? value['cwd'] as String : '',
      state: state,
      agentId: value['agentId'] is String ? value['agentId'] as String : null,
    );
  }
}

class TmuxPaneListing {
  const TmuxPaneListing({required this.serverIdentity, required this.panes});
  final String? serverIdentity;
  final List<TmuxPane> panes;

  factory TmuxPaneListing.fromJson(Map<String, dynamic> value) {
    final server = value['server'];
    final identity = server is Map ? server['serverIdentity'] : null;
    final rawPanes = value['panes'];
    return TmuxPaneListing(
      serverIdentity: identity is String && identity.isNotEmpty
          ? identity
          : null,
      panes: rawPanes is List
          ? rawPanes.map(TmuxPane.fromJson).whereType<TmuxPane>().toList()
          : const [],
    );
  }
}

class TmuxPaneError implements Exception {
  const TmuxPaneError(this.code, this.message);
  final String code;
  final String message;
  factory TmuxPaneError.fromReply(Map<String, dynamic> reply) {
    final code = reply['error'] is String ? reply['error'] as String : 'ERROR';
    final detail = reply['detail'] is String ? reply['detail'] as String : '';
    return TmuxPaneError(code, switch (code) {
      'OWNER_REQUIRED' => 'Only the machine owner can add tmux panes.',
      'TMUX_UNAVAILABLE' => 'tmux is not available on this machine.',
      'TMUX_SERVER_CHANGED' =>
        'tmux restarted. Refresh the list and try again.',
      'UNSUPPORTED' => 'Update Harness on this machine to add tmux panes.',
      _ => detail.isNotEmpty ? detail : code,
    });
  }
  @override
  String toString() => message;
}
