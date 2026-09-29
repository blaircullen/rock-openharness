import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:harness_mobile/core/models.dart';
import 'package:harness_mobile/state/app_state.dart';

import 'phone_navigation.dart';
import 'phone_sheet.dart';

/// The only actions on a borrowed pane. Never send agent lifecycle requests to it.
Future<void> showBorrowedPaneActions(
  BuildContext context,
  AppNotifier notifier,
  String machineId,
  Agent agent,
) => showPhoneSheet(
  context,
  title: '${agent.displayName} · tmux',
  actions: [
    PhoneSheetAction(
      icon: LucideIcons.squareTerminal300,
      label: 'Open',
      onTap: () => openAgent(context, notifier, machineId, agent.id),
    ),
    PhoneSheetAction(
      icon: LucideIcons.unplug300,
      label: 'Disconnect',
      onTap: () {
        final pane = notifier.paneOfAgent(machineId, agent.id);
        if (pane != null) unawaited(notifier.closePane(pane.id));
      },
    ),
    PhoneSheetAction(
      icon: LucideIcons.unlink300,
      label: 'Remove from Harness',
      destructive: true,
      onTap: () => unawaited(
        confirmUnenrollTmuxPane(context, notifier, machineId, agent),
      ),
    ),
  ],
);

Future<void> confirmUnenrollTmuxPane(
  BuildContext context,
  AppNotifier notifier,
  String machineId,
  Agent agent,
) async {
  final confirmed = await confirmPhoneAction(
    context,
    icon: LucideIcons.unlink300,
    title: 'Remove tmux pane?',
    detail: agent.external?.address ?? agent.displayName,
    message: 'Harness will forget this pane. Its tmux session and running process will continue.',
    confirmLabel: 'Remove',
  );
  if (!confirmed || !context.mounted) {
    return;
  }
  try {
    await notifier.unenrollTmuxPane(machineId, agent.id);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}
