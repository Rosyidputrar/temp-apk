// Tes pembaruan APK dengan server HTTP lokal (Range, redirect, putus, dll).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tempmail/update.dart';

/// Server tiruan GitHub: API rilis, redirect /releases/latest, dan file APK.
class FakeGitHub {
  late HttpServer server;
  final List<int> apk;
  bool apiFails = false;
  bool ignoreRange = false; // server membalas 200 walau diminta Range
  int? dropAfter; // putuskan koneksi setelah N byte (sekali)
  final ranges = <String?>[];

  FakeGitHub(this.apk);

  String get base => 'http://127.0.0.1:${server.port}';
  String get sha => sha256.convert(apk).toString();

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    final p = req.uri.path;
    final res = req.response;
    if (p == '/repos/o/r/releases') {
      if (apiFails) {
        res.statusCode = 403;
        res.write(jsonEncode({'message': 'API rate limit exceeded'}));
        return res.close();
      }
      res.headers.contentType = ContentType.json;
      res.write(
        jsonEncode([
          {
            'tag_name': 'b11',
            'name': 'Build 11',
            'draft': false,
            'prerelease': false,
            'assets': [
              {
                'name': 'app-arm64-v8a-release.apk',
                'size': 10,
                'browser_download_url': '$base/old.apk',
              },
            ],
          },
          {
            'tag_name': 'b13',
            'draft': true, // draft diabaikan
            'assets': [
              {'name': 'app-arm64-v8a-release.apk', 'size': 1},
            ],
          },
          {
            'tag_name': 'b12',
            'name': 'Build 12',
            'body': 'Perbaikan',
            'html_url': '$base/o/r/releases/tag/b12',
            'published_at': '2026-10-20T10:00:00Z',
            'draft': false,
            'prerelease': false,
            'assets': [
              {
                'name': 'app-armeabi-v7a-release.apk',
                'size': 5,
                'browser_download_url': '$base/v7.apk',
              },
              {
                'name': 'app-arm64-v8a-release.apk',
                'size': apk.length,
                'digest': 'sha256:$sha',
                'browser_download_url': '$base/o/r/releases/download/b12/a.apk',
              },
            ],
          },
        ]),
      );
      return res.close();
    }
    if (p == '/o/r/releases/latest') {
      res.statusCode = 302;
      res.headers.set('Location', '$base/o/r/releases/tag/b12');
      return res.close();
    }
    if (p.startsWith('/o/r/releases/download/')) {
      // Seperti GitHub: alihkan ke "CDN".
      res.statusCode = 302;
      res.headers.set('Location', '/cdn/app.apk');
      return res.close();
    }
    if (p == '/cdn/app.apk') {
      final range = req.headers.value('range');
      ranges.add(range);
      var from = 0;
      if (range != null && !ignoreRange) {
        from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        if (from >= apk.length) {
          res.statusCode = 416;
          return res.close();
        }
        res.statusCode = 206;
        res.headers.set(
          'Content-Range',
          'bytes $from-${apk.length - 1}/${apk.length}',
        );
      }
      res.contentLength = apk.length - from;
      final drop = dropAfter;
      dropAfter = null;
      var sent = 0;
      for (var i = from; i < apk.length; i += 16 * 1024) {
        final end = min(i + 16 * 1024, apk.length);
        if (drop != null && sent + (end - i) > drop) {
          // Putus di tengah jalan (body lebih pendek dari Content-Length).
          res.add(apk.sublist(i, i + (drop - sent)));
          await res.flush();
          await res.close().catchError((_) {});
          return;
        }
        res.add(apk.sublist(i, end));
        sent += end - i;
        try {
          await res.flush();
        } catch (_) {
          return; // klien menutup (jeda/batal)
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return res.close();
    }
    res.statusCode = 404;
    return res.close();
  }
}

Future<void> until(bool Function() cond, {int ms = 10000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('kondisi tidak terpenuhi');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakeGitHub gh;
  late Directory dir;
  final apk = List<int>.generate(600 * 1024, (i) => (i * 31 + 7) & 0xff);

  UpdateService svc() => UpdateService.forTest(
    apiBase: gh.base,
    webBase: gh.base,
    repo: 'o/r',
    dir: dir,
    currentBuild: 10,
  )..abis = const ['arm64-v8a', 'armeabi-v7a'];

  setUp(() async {
    gh = FakeGitHub(apk);
    await gh.start();
    dir = await Directory.systemTemp.createTemp('upd');
  });
  tearDown(() async {
    await gh.server.close(force: true);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File apkFile() => File('${dir.path}/tempmail-b12.apk');

  test('buildFromTag & pickApkAsset', () {
    expect(buildFromTag('b12'), 12);
    expect(buildFromTag('v1.2.0+34'), 34);
    expect(buildFromTag('latest'), isNull);
    final assets = [
      {'name': 'app-armeabi-v7a-release.apk'},
      {'name': 'app-arm64-v8a-release.apk'},
      {'name': 'notes.txt'},
    ];
    expect(pickApkAsset(assets, ['arm64-v8a'])!['name'], contains('arm64'));
    expect(pickApkAsset(assets, ['x86_64'])!['name'], endsWith('.apk'));
    expect(pickApkAsset([], ['arm64-v8a']), isNull);
  });

  test(
    'cek via API: pilih build terbesar (bukan draft) + APK sesuai ABI',
    () async {
      final u = svc();
      await u.check();
      expect(u.status, UpdateStatus.available);
      expect(u.release!.tag, 'b12');
      expect(u.release!.assetName, 'app-arm64-v8a-release.apk');
      expect(u.release!.sha256, gh.sha);
      expect(u.release!.size, apk.length);
    },
  );

  test('API gagal → cadangan redirect /releases/latest', () async {
    gh.apiFails = true;
    final u = svc();
    await u.check();
    expect(u.status, UpdateStatus.available);
    expect(u.release!.tag, 'b12');
    expect(
      u.release!.url,
      '${gh.base}/o/r/releases/download/b12/app-arm64-v8a-release.apk',
    );
  });

  test('sudah terbaru bila build terpasang >= rilis', () async {
    final u = UpdateService.forTest(
      apiBase: gh.base,
      webBase: gh.base,
      repo: 'o/r',
      dir: dir,
      currentBuild: 12,
    );
    await u.check();
    expect(u.status, UpdateStatus.upToDate);
  });

  test('unduh sampai selesai + verifikasi SHA-256', () async {
    final u = svc();
    await u.check();
    await u.download();
    expect(u.status, UpdateStatus.downloaded, reason: u.downloadError);
    expect(apkFile().readAsBytesSync(), apk);
  });

  test('jeda lalu lanjutkan memakai Range', () async {
    final u = svc();
    await u.check();
    final f = u.download();
    await until(() => u.received > 100 * 1024);
    u.pause();
    await f;
    expect(u.status, UpdateStatus.paused);
    final at = u.received;
    expect(at, lessThan(apk.length));
    await u.download();
    expect(u.status, UpdateStatus.downloaded, reason: u.downloadError);
    expect(gh.ranges.last, 'bytes=$at-');
    expect(apkFile().readAsBytesSync(), apk);
  });

  test('batal menghapus file dan kembali ke "tersedia"', () async {
    final u = svc();
    await u.check();
    final f = u.download();
    await until(() => u.received > 50 * 1024);
    await u.cancel();
    await f;
    expect(u.status, UpdateStatus.available);
    expect(u.received, 0);
    expect(
      dir.listSync().whereType<File>().where((e) => e.path.contains('b12')),
      isEmpty,
    );
  });

  test('koneksi putus → gagal, "coba lagi" melanjutkan', () async {
    gh.dropAfter = 200 * 1024;
    final u = svc();
    await u.check();
    await u.download();
    expect(u.status, UpdateStatus.failed);
    expect(u.downloadError, isNotNull);
    expect(u.received, greaterThan(0));
    await u.download();
    expect(u.status, UpdateStatus.downloaded, reason: u.downloadError);
    expect(gh.ranges.last, startsWith('bytes='));
    expect(apkFile().readAsBytesSync(), apk);
  });

  test(
    'server mengabaikan Range → mulai ulang dari awal, hasil tetap benar',
    () async {
      final u = svc();
      await u.check();
      final f = u.download();
      await until(() => u.received > 100 * 1024);
      u.pause();
      await f;
      gh.ignoreRange = true;
      await u.download();
      expect(u.status, UpdateStatus.downloaded, reason: u.downloadError);
      expect(apkFile().readAsBytesSync(), apk);
    },
  );

  test('checksum tidak cocok → gagal dan file dihapus', () async {
    final u = svc();
    await u.check();
    u.release = ReleaseInfo.fromJson({
      ...u.release!.toJson(),
      'sha256': 'deadbeef',
    });
    await u.download();
    expect(u.status, UpdateStatus.failed);
    expect(u.downloadError, contains('SHA-256'));
    expect(apkFile().existsSync(), isFalse);
  });

  test(
    'aplikasi dibuka lagi → unduhan tertunda dipulihkan sebagai "dijeda"',
    () async {
      final u = svc();
      await u.check();
      final f = u.download();
      await until(() => u.received > 100 * 1024);
      u.pause();
      await f;
      final at = u.received;
      final u2 = svc();
      await u2.restoreForTest();
      expect(u2.status, UpdateStatus.paused);
      expect(u2.received, at);
      expect(u2.release!.tag, 'b12');
    },
  );
}
