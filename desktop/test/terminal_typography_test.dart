import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/terminal/terminal_font_store.dart';
import 'package:harness/terminal/terminal_typography.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('the fork defaults to bundled Hack at Warp effective size', () {
    expect(terminalFontFamily, 'Hack');
    expect(terminalFontSize, 16.25);
    expect(const TerminalStyle().height, 1.2);
  });

  test('the default face is the one the store opens on', () {
    expect(
      TerminalFontChoice.defaultForPlatform.fontFamily,
      terminalFontFamily,
    );
    expect(
      TerminalFontChoice.defaultForPlatform.fontFamilyFallback,
      terminalFontFallback,
    );
  });

  test('every face offered here can reach a font that is really there', () {
    // The generic `monospace` at the end of each list is NOT the floor, however
    // much it looks like one: Flutter resolves families through Skia, which
    // does not honour fontconfig's generic aliases, and a real Linux build
    // measures `monospace` at exactly the width of a family that does not
    // exist (see terminal_typography.dart for the numbers). So each chain has
    // to name a face the platform actually ships — otherwise a machine without
    // the chosen font lands on the engine's proportional default and the whole
    // grid shears.
    final anchor = Platform.isMacOS ? 'Menlo' : 'DejaVu Sans Mono';
    for (final choice in TerminalFontChoice.available) {
      expect(choice.fontFamily, isNotEmpty);
      expect(
        [choice.fontFamily, ...choice.fontFamilyFallback],
        contains(anchor),
        reason:
            '${choice.label} can only fall through to faces that may be absent',
      );
      if (choice != TerminalFontChoice.hack) {
        expect(choice.fontFamilyFallback.last, 'monospace');
      }
    }
  });

  test('bundled Hack is an available choice', () {
    final offered = TerminalFontChoice.available
        .map((choice) => choice.fontFamily)
        .toSet();
    expect(offered, contains('Hack'));
  });

  test('ANSI bold uses semibold instead of heavy bold', () {
    expect(
      const TerminalStyle().toTextStyle(bold: true).fontWeight,
      FontWeight.w600,
    );
    expect(const TerminalStyle().toTextStyle().fontWeight, FontWeight.normal);
  });
}
