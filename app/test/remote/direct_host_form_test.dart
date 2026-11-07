// The direct-host form: URL/token validation, saving through the hosts
// controller with the token only in the secret store, editing with a stored
// cookie, and the "测试连接" feedback card.

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/direct_host_form.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';

const _existing = DirectHostConfig(
  id: 'direct-edit',
  name: '家里的电脑',
  baseUrl: 'https://dsh.example.com',
);

const _cookie = DshCookie(
  name: 'dsh-auth-form',
  value: 'v1.payload.signature',
  authority: 'dsh.example.com',
);

void main() {
  late MemorySecretStore secrets;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = MemorySecretStore();
  });

  Future<void> frames(WidgetTester tester, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<ProviderContainer> pumpForm(WidgetTester tester, {DirectHostConfig? existing}) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: DirectHostFormPage(existing: existing),
        brightness: Brightness.light,
        overrides: [secretStoreProvider.overrideWithValue(secrets)],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  testWidgets('an unusable server URL is explained under the field and nothing is saved', (tester) async {
    final c = await pumpForm(tester);

    await tester.enterText(find.byType(TextField).at(0), '实验室');
    await tester.enterText(find.byType(TextField).at(1), 'https://dsh.example.com/dsh');
    await tester.enterText(find.byType(TextField).at(2), 'tok-widget');
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('服务器地址无效'), findsOneWidget);
    expect(find.text('请填写访问 Token'), findsNothing, reason: 'the URL is the problem, not the token');
    expect(c.read(hostsProvider).direct, isEmpty);
  });

  testWidgets('a new host without a token cannot be saved', (tester) async {
    final c = await pumpForm(tester);

    await tester.enterText(find.byType(TextField).at(0), '实验室');
    await tester.enterText(find.byType(TextField).at(1), 'dsh.example.com');
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('请填写访问 Token'), findsOneWidget);
    expect(find.text('服务器地址无效'), findsNothing);
    expect(c.read(hostsProvider).direct, isEmpty);
  });

  testWidgets('a valid bare host saves normalized and keeps the token out of preferences', (tester) async {
    final c = await pumpForm(tester);

    await tester.enterText(find.byType(TextField).at(0), '家里电脑');
    await tester.enterText(find.byType(TextField).at(1), 'dsh.example.com/');
    await tester.enterText(find.byType(TextField).at(2), 'tok-widget');
    await tester.tap(find.text('保存'));
    await frames(tester);

    final saved = c.read(hostsProvider).direct.single;
    expect(saved.name, '家里电脑');
    expect(saved.baseUrl, 'https://dsh.example.com', reason: 'the trailing slash is dropped');
    expect(secrets.values[DirectSecretKeys.token(saved.id)], 'tok-widget');
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(HostsController.directPrefsKey);
    expect(raw, contains('https://dsh.example.com'));
    expect(raw, isNot(contains('tok-widget')), reason: 'the token belongs to the secret store only');
  });

  testWidgets('editing a host with a stored cookie saves without asking for the token again', (tester) async {
    secrets.values[DirectSecretKeys.cookie(_existing.id)] = encodeDirectCookie(_cookie);
    final c = await pumpForm(tester, existing: _existing);
    await frames(tester, 3);

    await tester.tap(find.text('保存'));
    await frames(tester);

    expect(find.text('请填写访问 Token'), findsNothing, reason: 'the cookie resumes the session');
    final saved = c.read(hostsProvider).direct.single;
    expect(saved.id, _existing.id);
    expect(saved.baseUrl, _existing.baseUrl);
    expect(decodeDirectCookie(secrets.values[DirectSecretKeys.cookie(saved.id)])?.value, _cookie.value);
  });

  testWidgets('moving a saved host to another domain asks for the token again and does not save', (tester) async {
    secrets.values[DirectSecretKeys.cookie(_existing.id)] = encodeDirectCookie(_cookie);
    final c = await pumpForm(tester, existing: _existing);
    await frames(tester, 3);

    await tester.enterText(find.byType(TextField).at(1), 'https://new.example.com');
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('请填写访问 Token'), findsOneWidget, reason: 'the old cookie cannot resume the new authority');
    expect(c.read(hostsProvider).direct, isEmpty, reason: 'a host without a usable credential must not be saved');
  });

  testWidgets('saving a moved host with a token drops the stale authority-bound cookie', (tester) async {
    secrets.values[DirectSecretKeys.cookie(_existing.id)] = encodeDirectCookie(_cookie);
    final c = await pumpForm(tester, existing: _existing);
    await frames(tester, 3);

    await tester.enterText(find.byType(TextField).at(1), 'https://new.example.com');
    await tester.enterText(find.byType(TextField).at(2), 'tok-new');
    await tester.tap(find.text('保存'));
    await frames(tester);

    expect(find.text('请填写访问 Token'), findsNothing);
    final saved = c.read(hostsProvider).direct.single;
    expect(saved.baseUrl, 'https://new.example.com');
    expect(secrets.values[DirectSecretKeys.token(saved.id)], 'tok-new');
    expect(
      secrets.values.containsKey(DirectSecretKeys.cookie(saved.id)),
      isFalse,
      reason: 'the cookie was bound to the old authority, so it must not survive the move',
    );
  });

  testWidgets('测试连接 explains an unusable URL instead of starting a probe', (tester) async {
    await pumpForm(tester);

    await tester.enterText(find.byType(TextField).at(1), 'ftp://dsh.example.com');
    await tester.enterText(find.byType(TextField).at(2), 'tok-widget');
    await tester.tap(find.text('测试连接'));
    await tester.pump();

    expect(find.text('服务器地址无效'), findsOneWidget);
    expect(find.text('正在测试'), findsNothing);
    expect(find.text('连接失败'), findsNothing);
  });

  testWidgets('测试连接 reports a failed connection without leaking the token', (tester) async {
    await pumpForm(tester);

    await tester.enterText(find.byType(TextField).at(1), 'dsh.example.com');
    await tester.enterText(find.byType(TextField).at(2), 'tok-widget');
    await tester.tap(find.text('测试连接'));
    // The test binding answers every HTTP request with 400, so the probe fails
    // deterministically and quickly; no network is touched.
    await frames(tester, 20);

    expect(find.text('连接失败'), findsOneWidget);
    expect(find.text('正在测试'), findsNothing);
    final shown = tester.widgetList<Text>(find.byType(Text)).map((text) => text.data ?? '');
    expect(shown.where((text) => text.contains('tok-widget')), isEmpty, reason: 'a failed probe must not echo the token');
  });
}