import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/teams/team_controller.dart';
import 'package:harness/teams/team_workspace.dart';

import 'support/team_fixture.dart';
import 'support/real_fonts.dart';

void main() {
  setUpAll(loadRealFonts);
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'tab channel history at $width has no team setup or human question composer',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 820);
        addTearDown(tester.view.reset);
        final calls = <Map<String, dynamic>>[];
        final controller = TeamController(
          channelTabId: 'device',
          request: (p) async {
            calls.add(p);
            return {
              'team': {
                ...teamFixture(),
                'name': 'Device',
                'channel': {'tabId': 'device'},
              },
            };
          },
        );
        final capture = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: grid.buildAppTheme(brightness: Brightness.dark),
            home: Scaffold(
              body: RepaintBoundary(
                key: capture,
                child: TeamWorkspace(
                  controller: controller,
                  candidates: const [],
                  machineName: 'Mac',
                  onClose: () {},
                  onOpen: (_, _) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Device'), findsOneWidget);
        expect(find.textContaining('This swarm only'), findsOneWidget);
        expect(find.byKey(const Key('team-question')), findsNothing);
        expect(find.byKey(const Key('team-new')), findsNothing);
        expect(find.text('New question'), findsNothing);
        expect(find.textContaining('Use GET /api/daemons.'), findsOneWidget);
        expect(calls.map((p) => p['action']), everyElement('channel_get'));
        expect(tester.takeException(), isNull);
        final renderDir = Platform.environment['CHANNEL_RENDER_DIR'];
        if (renderDir != null) {
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(renderDir).create(recursive: true);
            await File('$renderDir/channel-${width.toInt()}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }
}
