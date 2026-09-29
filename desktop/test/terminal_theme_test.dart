import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/shared/theme/color_palette.dart';
import 'package:harness/state/app_state.dart';
import 'package:harness/terminal/terminal_theme.dart';
import 'package:harness/terminal/terminal_theme_store.dart';

void main() {
  test('Pi uses every Warp terminal color exactly', () {
    const theme = piTerminalTheme;
    expect(TerminalThemeChoice.fallback, TerminalThemeChoice.pi);
    expect(theme.cursor, const Color(0xff6da7ec));
    expect(theme.selection, const Color(0x666da7ec));
    expect(theme.foreground, const Color(0xffe7e6e1));
    expect(theme.background, const Color(0xff1a1a19));
    expect(
      [
        theme.black,
        theme.red,
        theme.green,
        theme.yellow,
        theme.blue,
        theme.magenta,
        theme.cyan,
        theme.white,
        theme.brightBlack,
        theme.brightRed,
        theme.brightGreen,
        theme.brightYellow,
        theme.brightBlue,
        theme.brightMagenta,
        theme.brightCyan,
        theme.brightWhite,
      ],
      const [
        Color(0xff0d0d0d),
        Color(0xffe34948),
        Color(0xff0ca30c),
        Color(0xffb97d10),
        Color(0xff3987e5),
        Color(0xff9d6bf0),
        Color(0xff3fb8a8),
        Color(0xffe7e6e1),
        Color(0xff898781),
        Color(0xffe06c6c),
        Color(0xff5ce05c),
        Color(0xfffab219),
        Color(0xff6da7ec),
        Color(0xffc9a0ff),
        Color(0xff5fd7c9),
        Color(0xfff3f3f0),
      ],
    );
  });
  test('the terminal default follows the app\'s dark background', () {
    expect(darkTerminalTheme.background, const Color(0xff181818));
    expect(darkTerminalTheme.foreground, const Color(0xffffffff));
  });

  test('the colours sent to a daemon are the pane\'s own, as #rrggbb', () {
    terminalThemeStore.value = TerminalThemeChoice.matchApp;
    addTearDown(() {
      grid.AppTheme.palette.value = HarnessPalette.graphite;
      terminalThemeStore.value = TerminalThemeChoice.matchApp;
    });
    expect(AppNotifier.terminalThemeColours(), {
      'background': '#181818',
      'foreground': '#f5f5f5',
    });
    terminalThemeStore.value = TerminalThemeChoice.tango;
    expect(AppNotifier.terminalThemeColours()['background'], '#300a24');
  });
}
