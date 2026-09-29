import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:harness_mobile/core/tmux_panes.dart';
import 'package:harness_mobile/shared/theme/app_theme.dart';
import 'package:harness_mobile/state/app_state.dart';

import 'phone_card.dart';
import 'phone_header.dart';
import 'phone_navigation.dart';

/// Lists only on entry or a deliberate pull; a tmux server is never polled by this page.
class TmuxPanePicker extends StatefulWidget {
  const TmuxPanePicker({
    super.key,
    required this.notifier,
    required this.machineId,
  });
  final AppNotifier notifier;
  final String machineId;

  @override
  State<TmuxPanePicker> createState() => _TmuxPanePickerState();
}

class _TmuxPanePickerState extends State<TmuxPanePicker> {
  TmuxPaneListing? _listing;
  String? _error;
  bool _loading = false;
  String? _adding;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await widget.notifier.listTmuxPanes(widget.machineId);
      if (mounted) setState(() => _listing = listing);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(TmuxPane pane) async {
    if (_adding != null) return;
    if (pane.state == TmuxPaneState.enrolled && pane.agentId != null) {
      openAgent(context, widget.notifier, widget.machineId, pane.agentId!);
      return;
    }
    final identity = _listing?.serverIdentity;
    if (!pane.canEnroll || identity == null) return;
    setState(() {
      _adding = pane.paneId;
      _error = null;
    });
    try {
      final agent = await widget.notifier.enrollTmuxPane(
        widget.machineId,
        pane,
        identity,
      );
      if (!mounted) return;
      openAgent(context, widget.notifier, widget.machineId, agent.id);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _adding = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final panes = _listing?.panes ?? const <TmuxPane>[];
    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      body: SafeArea(
        child: Column(
          children: [
            const PhoneHeader(title: 'Add tmux pane'),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(color: AppPalette.textPrimary),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: phoneListPadding(context),
                  itemCount: panes.isEmpty ? 1 : panes.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: kPhoneCardGap),
                  itemBuilder: (context, index) {
                    if (panes.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: Text(
                          _loading
                              ? 'Reading tmux panes…'
                              : 'No tmux panes found. Pull down to refresh.',
                          style: TextStyle(color: AppPalette.textSecondary),
                        ),
                      );
                    }
                    final pane = panes[index];
                    final enabled =
                        pane.canEnroll ||
                        (pane.state == TmuxPaneState.enrolled &&
                            pane.agentId != null);
                    return PhoneCard(
                      key: ValueKey('tmux-${pane.paneId}'),
                      height: kPhoneAgentCardHeight,
                      onTap: enabled ? () => _open(pane) : null,
                      child: Row(
                        children: [
                          const Icon(LucideIcons.panelTop300, size: 22),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  pane.address,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: AppPalette.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  pane.command,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: AppPalette.textSecondary,
                                  ),
                                ),
                                Text(
                                  [
                                        pane.cwd,
                                        if (pane.unavailableReason != null)
                                          pane.unavailableReason!,
                                        if (pane.state ==
                                            TmuxPaneState.enrolled)
                                          'Already added · Open',
                                      ]
                                      .where((part) => part.isNotEmpty)
                                      .join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: AppPalette.textFaint),
                                ),
                              ],
                            ),
                          ),
                          if (_adding == pane.paneId)
                            const CircularProgressIndicator(),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
