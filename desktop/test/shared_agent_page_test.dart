import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/auth/auth_session.dart';
import 'package:harness/core/config.dart';
import 'package:harness/sharing/shared_agent_location.dart';
import 'package:harness/sharing/shared_agent_page.dart';
import 'package:harness/sharing/shared_harness_panel.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/state/app_state.dart';

import 'support/real_fonts.dart';

void main() {
  setUpAll(loadRealFonts);
  const id = '11111111-1111-4111-8111-111111111111';
  final key = base64Encode(List.filled(32, 1));
  late AppNotifier app;
  late Dio dio;
  late List<RequestOptions> requests;
  late int status;
  late Map<String, dynamic> metadata;

  setUp(() {
    app = AppNotifier(
      config: AppConfig.dev,
      authSession: AuthSession(),
      configStore: null,
    );
    requests = [];
    status = 200;
    metadata = {'ownerPublicKey': key, 'online': false};
    dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: status,
                data: {'data': metadata},
              ),
            );
          },
        ),
      );
  });
  tearDown(() {
    dio.close();
    app.dispose();
  });

  Future<void> show(WidgetTester tester, {String? pinnedKey}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: grid.buildAppTheme(brightness: Brightness.dark),
        home: SharedAgentPage(
          app: app,
          dio: dio,
          location: SharedAgentLocation(id, pinnedKey, 'stag'),
        ),
      ),
    );
    for (
      var i = 0;
      i < 20 && find.text('Opening shared harness…').evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('incomplete and changed owner identities never open a viewer', (
    tester,
  ) async {
    await show(tester);
    expect(find.textContaining('This link is incomplete'), findsOneWidget);
    expect(requests, isEmpty);
    expect(find.byType(SharedHarnessPanel), findsNothing);
    await tester.pumpWidget(const SizedBox());
    metadata['ownerPublicKey'] = base64Encode(List.filled(32, 2));
    await show(tester, pinnedKey: key);
    expect(
      find.textContaining('The owner identity has changed'),
      findsOneWidget,
    );
    expect(find.byType(SharedHarnessPanel), findsNothing);
    expect(requests.single.headers['x-autonomous-env'], 'stag');
    expect(requests.single.headers.containsKey('Authorization'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'private and denied links show access guidance without opening a viewer',
    (tester) async {
      status = 401;
      await show(tester, pinnedKey: key);
      expect(
        find.textContaining('Sign in with an invited email'),
        findsOneWidget,
      );
      expect(find.text('[ Sign in ]'), findsOneWidget);
      expect(find.byType(SharedHarnessPanel), findsNothing);
      await tester.pumpWidget(const SizedBox());
      status = 403;
      await show(tester, pinnedKey: key);
      expect(
        find.textContaining('your email has not been invited'),
        findsOneWidget,
      );
      expect(find.byType(SharedHarnessPanel), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'offline links retry automatically and stop retrying when closed',
    (tester) async {
      await show(tester, pinnedKey: key);
      expect(find.textContaining('machine is offline'), findsOneWidget);
      expect(find.byType(SharedHarnessPanel), findsNothing);
      expect(requests.length, 1);
      await tester.pump(const Duration(seconds: 10));
      for (
        var i = 0;
        i < 20 && find.text('Opening shared harness…').evaluate().isNotEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(requests.length, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 20));
      expect(requests.length, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
