import 'package:flutter/material.dart';

import '../../shared/theme/app_theme.dart' as grid;
import '../../state/workspace_chrome.dart';
import '../../terminal/terminal_text.dart';
import '../../terminal/terminal_theme.dart';
import '../../terminal/terminal_theme_store.dart';
import 'web_picker_scopes.dart';

/// The row over the picker's input: Back out of a scope, the scopes the
/// prefix keys reach, and close — each a click instead of a key.
class WebPickerBar extends StatelessWidget {
  const WebPickerBar({super.key, required this.picker});

  final WorkspacePicker picker;

  @override
  Widget build(BuildContext context) {
    final search = picker.search;
    final cell = terminalCellSizeOf(context);
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) => Padding(
        key: const ValueKey('web-picker-bar'),
        // Four cells in, like the input and the result titles under it.
        padding: EdgeInsets.fromLTRB(
          cell.width * 4,
          cell.height * .5,
          cell.width,
          0,
        ),
        child: Row(
          children: [
            if (search.canGoBack) ...[
              _BarText(
                key: const ValueKey('web-picker-back'),
                label: '‹ Back',
                onPressed: () {
                  if (search.back()) picker.focus();
                },
              ),
              SizedBox(width: cell.width * 2),
            ],
            Expanded(
              child: Wrap(
                spacing: cell.width * 2,
                children: [
                  for (final scope in webPickerScopes(search))
                    _BarText(
                      key: ValueKey('web-picker-scope:${scope.prefix}'),
                      label: scope.label,
                      active:
                          !search.isHelpMode &&
                          search.scopePrefix == scope.prefix,
                      onPressed: () {
                        search.setQuery(webPickerQuery(scope));
                        picker.focus();
                      },
                    ),
                ],
              ),
            ),
            _BarText(
              key: const ValueKey('web-picker-close'),
              label: '×',
              onPressed: picker.close,
            ),
          ],
        ),
      ),
    );
  }
}

/// A line of picker text that is also a button: dim until hovered, full ink
/// and underlined when it names where the picker is.
class _BarText extends StatelessWidget {
  const _BarText({
    super.key,
    required this.label,
    required this.onPressed,
    this.active = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = terminalThemeFor(
      grid.AppTheme.palette.value,
      terminalThemeStore.value,
    );
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: theme.foreground.withValues(alpha: active ? 1 : .54),
        textStyle: terminalContentStyle().copyWith(
          decoration: active ? TextDecoration.underline : null,
        ),
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const RoundedRectangleBorder(),
      ),
      child: SizedBox(
        height: terminalCellSizeOf(context).height * 1.5,
        // Centered on the row's height only: a plain Center would take the
        // whole width and stack every scope on a line of its own.
        child: Center(widthFactor: 1, child: Text(label)),
      ),
    );
  }
}
