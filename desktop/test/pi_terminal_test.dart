import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/terminal/terminal_font_store.dart';
import 'package:harness/terminal/terminal_theme.dart';
import 'package:harness/terminal/terminal_theme_store.dart';
import 'package:harness/terminal/terminal_typography.dart';
import 'package:xterm/xterm.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fork opens Pi and Hack at Warp zoom size with Warp line height', () {
    expect(TerminalThemeChoice.fallback, TerminalThemeChoice.pi);
    expect(TerminalFontChoice.defaultForPlatform, TerminalFontChoice.hack);
    expect(terminalFontSize, 16.25);
    expect(TerminalFontStore().value.height, 1.2);
  });

  test('Pi palette is the Warp palette', () {
    const t = piTerminalTheme;
    expect(t.background, const Color(0xff1a1a19));
    expect(t.foreground, const Color(0xffe7e6e1));
    expect(t.cursor, const Color(0xff6da7ec));
    expect(t.selection, const Color(0x666da7ec));
    expect(
      [
        t.black,
        t.red,
        t.green,
        t.yellow,
        t.blue,
        t.magenta,
        t.cyan,
        t.white,
        t.brightBlack,
        t.brightRed,
        t.brightGreen,
        t.brightYellow,
        t.brightBlue,
        t.brightMagenta,
        t.brightCyan,
        t.brightWhite,
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

  test('Hack regular, bold, italic and bold italic assets load', () async {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    final hack = manifest.cast<Map>().singleWhere(
      (entry) => entry['family'] == 'Hack',
    );
    expect((hack['fonts'] as List).length, 4);
    for (final font in hack['fonts'] as List) {
      final path = (font as Map)['asset'] as String;
      expect((await rootBundle.load(path)).lengthInBytes, greaterThan(100000));
    }
    expect(
      await rootBundle.loadString('assets/fonts/hack/LICENSE.md'),
      contains('MIT License'),
    );
  });

  test('vendored xterm preserves 24-bit foreground and background', () {
    final terminal = Terminal()..write('\x1b[38;2;18;52;86;48;2;171;205;239mX');
    final line = terminal.buffer.lines[0];
    expect(line.getForeground(0), CellColor.rgb | 0x123456);
    expect(line.getBackground(0), CellColor.rgb | 0xabcdef);
    final painter = TerminalPainter(
      theme: piTerminalTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    expect(
      painter.resolveForegroundColor(line.getForeground(0)),
      const Color(0xff123456),
    );
    expect(
      painter.resolveBackgroundColor(line.getBackground(0)),
      const Color(0xffabcdef),
    );
  });
}
