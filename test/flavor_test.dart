// Jalankan dua kali: `flutter test` (APK admin) dan
// `flutter test --dart-define=PUBLIC_BUILD=true` (APK publik).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tempmail/account.dart';
import 'package:tempmail/api.dart';
import 'package:tempmail/main.dart';
import 'package:tempmail/screens_main.dart';

Future<List<String>> _menuTitles(WidgetTester tester) async {
  // Layar tinggi supaya semua item menu (ListView malas) ikut dibangun.
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pump();
  await tester.tap(find.text('Menu').last);
  await tester.pump(const Duration(milliseconds: 100));
  return tester
      .widgetList<ListTile>(find.byType(ListTile))
      .map((t) => t.title is Text ? (t.title as Text).data ?? '' : '')
      .toList();
}

void main() {
  test('helper akun', () {
    expect(quotaText({'used_today': 3, 'daily_quota': 20}), '3/20');
    expect(quotaText(null), '');
    expect(expiryText(null), 'Permanen');
    expect(expiryText('2026-12-31T16:59:59.000Z'), startsWith('Aktif s/d '));
  });

  if (!kPublic) {
    testWidgets('APK admin: tanpa login, ada Kelola akun & fitur admin', (
      tester,
    ) async {
      await tester.pumpWidget(const TempMailApp());
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Buat cepat'), findsOneWidget);
      final titles = await _menuTitles(tester);
      expect(titles, containsAll(['Kelola akun', 'Admin', 'Debug']));
      expect(titles, isNot(contains('Akun')));
      expect(titles, isNot(contains('Alamat saya')));
      await tester.pumpWidget(const SizedBox());
    });
    return;
  }

  testWidgets('APK publik: wajib login, fitur admin hilang, sesi dicabut', (
    tester,
  ) async {
    await tester.pumpWidget(const TempMailApp());
    await tester.runAsync(() => authState.load());
    await tester.pump(const Duration(milliseconds: 100));

    // Belum login → layar Login, bukan Beranda.
    expect(find.text('Masuk'), findsOneWidget);
    expect(find.text('Buat cepat'), findsNothing);

    authState.debugSignIn('tms_test', {
      'username': 'budi',
      'daily_quota': 20,
      'used_today': 2,
      'max_devices': 2,
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Buat cepat'), findsOneWidget);
    expect(find.text('Jatah hari ini: 2/20 alamat baru'), findsOneWidget);
    // Kolom manual: password email, bukan "simpan sbg alias".
    await tester.scrollUntilVisible(
      find.text('Password email'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(HomeScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Password email'), findsOneWidget);
    expect(find.text('Simpan sbg alias'), findsNothing);

    final titles = await _menuTitles(tester);
    expect(titles, containsAll(['Akun', 'Alamat saya', 'Domain', 'Riwayat']));
    for (final hidden in [
      'Kelola akun',
      'Admin',
      'Debug',
      'Alias (alias.md)',
      'Pantauan & notifikasi',
    ]) {
      expect(titles, isNot(contains(hidden)));
    }

    // Server mengeluarkan sesi (login di HP lain) → kembali ke Login + alasan.
    TempmailApi.onSessionLost?.call(
      ApiException(401, 'SESSION_REVOKED', 'Akun ini login di perangkat lain.'),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Masuk'), findsOneWidget);
    expect(find.text('Akun ini login di perangkat lain.'), findsOneWidget);
    expect(TempmailApi.sessionToken, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
