// Klien API untuk rest-tempmail (Cloudflare Worker / Hono).
//
// Base URL & token TIDAK ditulis di kode: disuntik saat build lewat
//   flutter build apk --dart-define=API_BASE=https://... --dart-define=API_TOKEN=...
// Di CI, nilai itu datang dari GitHub Secrets repo.
//
// Versi publik (--flavor public --dart-define=PUBLIC_BUILD=true) TIDAK membawa
// token admin: pengguna login dengan akun buatan admin, dan token sesi
// perangkat disimpan di [TempmailApi.sessionToken].
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String kApiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'https://rest-tempmail.rosdiyttaa.workers.dev',
);
const String kApiToken = String.fromEnvironment('API_TOKEN');

/// APK publik (login akun) vs APK admin (token admin bawaan).
const bool kPublic = bool.fromEnvironment('PUBLIC_BUILD');

/// Kode galat server yang berarti sesi akun tidak berlaku lagi.
const kSessionLostCodes = {
  'SESSION_REVOKED',
  'SESSION_INVALID',
  'ACCOUNT_EXPIRED',
  'ACCOUNT_DISABLED',
};

class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  final dynamic details;
  ApiException(this.status, this.code, this.message, [this.details]);
  @override
  String toString() => '[$code] $message';
}

class ApiResult {
  final dynamic data;
  final Map<String, dynamic> meta;
  ApiResult(this.data, this.meta);
}

class TempmailApi {
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);

  /// Token sesi akun (APK publik). Diisi AuthState setelah login / saat start.
  static String? sessionToken;

  /// Dipanggil saat server menolak sesi (dikeluarkan, kedaluwarsa, dihapus).
  static void Function(ApiException e)? onSessionLost;

  String get _token => kPublic ? (sessionToken ?? '') : kApiToken;

  /// Ada kredensial untuk memanggil server?
  bool get hasCredentials => _token.isNotEmpty;

  Uri _u(String path, [Map<String, String?>? q]) {
    final clean = <String, String>{};
    q?.forEach((k, v) {
      if (v != null && v.isNotEmpty) clean[k] = v;
    });
    return Uri.parse('$kApiBase$path')
        .replace(queryParameters: clean.isEmpty ? null : clean);
  }

  Map<String, String> get _headers => {
    if (_token.isNotEmpty) 'Authorization': 'Bearer $_token',
    if (_token.isNotEmpty) 'X-API-Key': _token,
    'Accept': 'application/json',
  };

  /// Ubah galat jaringan mentah (SocketException dkk.) jadi pesan yang
  /// bisa dibaca pengguna.
  Future<T> _guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(
        0,
        'TIMEOUT',
        'Server terlalu lama merespons. Coba lagi.',
      );
    } on SocketException {
      throw ApiException(
        0,
        'NETWORK',
        'Tidak bisa terhubung ke server. Periksa koneksi internet.',
      );
    } on HandshakeException {
      throw ApiException(
        0,
        'TLS',
        'Koneksi aman ke server gagal (sertifikat/TLS).',
      );
    } on HttpException catch (e) {
      throw ApiException(0, 'NETWORK', 'Koneksi terputus: ${e.message}');
    }
  }

  /// Kirim permintaan dan kembalikan (status, JSON/teks hasil parse).
  Future<(int, dynamic)> _send(
    String method,
    String path, {
    Map<String, String?>? query,
    Object? body,
    String? rawBody,
    ContentType? contentType,
    Duration timeout = const Duration(seconds: 70),
  }) => _guard(() async {
    final req = await _http.openUrl(method, _u(path, query)).timeout(timeout);
    _headers.forEach(req.headers.set);
    if (rawBody != null) {
      req.headers.contentType = contentType ?? ContentType.text;
      req.write(rawBody);
    } else if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close().timeout(timeout);
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    dynamic parsed;
    try {
      parsed = jsonDecode(text);
    } catch (_) {
      parsed = text;
    }
    return (res.statusCode, parsed);
  });

  /// Bongkar amplop standar {ok, data, meta} / {ok:false, error}.
  ApiResult _unwrap(
    int status,
    dynamic parsed, [
    String? fallbackMsg,
    String? usedToken,
  ]) {
    if (parsed is Map && parsed['ok'] == true) {
      return ApiResult(
        parsed['data'],
        (parsed['meta'] as Map?)?.cast<String, dynamic>() ?? {},
      );
    }
    throw _error(status, parsed, fallbackMsg, usedToken);
  }

  /// [usedToken] = token yang dipakai permintaan itu. Sesi dianggap hilang hanya
  /// untuk kode sesi eksplisit DAN bila tokennya masih token saat ini (respons
  /// telat dari sesi lama tidak boleh mengeluarkan sesi baru).
  ApiException _error(
    int status,
    dynamic parsed, [
    String? fallbackMsg,
    String? usedToken,
  ]) {
    if (parsed is Map && parsed['error'] is Map) {
      final e = parsed['error'] as Map;
      final err = ApiException(
        status,
        e['code']?.toString() ?? 'ERROR',
        e['message']?.toString() ?? fallbackMsg ?? 'Permintaan gagal ($status)',
        e['details'],
      );
      if (kPublic &&
          kSessionLostCodes.contains(err.code) &&
          usedToken != null &&
          usedToken.isNotEmpty &&
          usedToken == sessionToken) {
        onSessionLost?.call(err);
      }
      return err;
    }
    if (status == 401 || status == 403) {
      return ApiException(
        status,
        'UNAUTHORIZED',
        kPublic
            ? 'Sesi ditolak server. Silakan login lagi.'
            : 'Token API ditolak server. Pastikan API_TOKEN benar saat build.',
      );
    }
    return ApiException(
      status,
      'HTTP_$status',
      fallbackMsg ?? 'Respons tak terduga ($status)',
    );
  }

  Future<ApiResult> call(
    String method,
    String path, {
    Map<String, String?>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 70),
  }) async {
    final tok = _token;
    final (status, parsed) = await _send(
      method,
      path,
      query: query,
      body: body,
      timeout: timeout,
    );
    return _unwrap(status, parsed, null, tok);
  }

  Future<dynamic> get(
    String path, {
    Map<String, String?>? query,
    Duration? timeout,
  }) async => (await call(
    'GET',
    path,
    query: query,
    timeout: timeout ?? const Duration(seconds: 70),
  )).data;

  Future<dynamic> post(
    String path, {
    Map<String, String?>? query,
    Object? body,
    Duration? timeout,
  }) async => (await call(
    'POST',
    path,
    query: query,
    body: body,
    timeout: timeout ?? const Duration(seconds: 70),
  )).data;

  Future<dynamic> put(
    String path, {
    Map<String, String?>? query,
    Object? body,
  }) async => (await call('PUT', path, query: query, body: body)).data;

  Future<dynamic> patch(String path, {Object? body}) async =>
      (await call('PATCH', path, body: body)).data;

  Future<dynamic> delete(String path, {Map<String, String?>? query}) async =>
      (await call('DELETE', path, query: query)).data;

  String enc(String ref) => Uri.encodeComponent(ref);

  // ---------- dasar ----------
  /// Health lengkap (/v1/health: upstream + KV); jatuh ke /health polos
  /// bila versi server belum punya.
  Future<dynamic> health() async {
    try {
      return await get('/v1/health', timeout: const Duration(seconds: 20));
    } on ApiException catch (e) {
      if (e.status == 0) rethrow;
      final (_, parsed) = await _send(
        'GET',
        '/health',
        timeout: const Duration(seconds: 20),
      );
      return parsed;
    }
  }

  Future<dynamic> me() => get('/v1/me');

  // ---------- akun (APK publik) ----------
  Future<dynamic> login(String username, String password, {String? device}) =>
      post(
        '/v1/auth/login',
        body: {'username': username, 'password': password, 'device': ?device},
        timeout: const Duration(seconds: 30),
      );

  Future<dynamic> logout() => post('/v1/auth/logout');

  Future<dynamic> authMe() => get('/v1/auth/me');

  Future<dynamic> changePassword(String current, String next) =>
      put('/v1/auth/password', body: {'current': current, 'new': next});

  Future<dynamic> revokeSession(String id) =>
      delete('/v1/auth/sessions/${enc(id)}');

  Future<dynamic> revokeOtherSessions() => delete('/v1/auth/sessions');

  /// Alamat milik akun + alamat akun lain yang sudah dibuka dengan password.
  Future<dynamic> myMailboxes({String? q, int? limit, int? offset}) => get(
    '/v1/mailboxes',
    query: {'q': q, 'limit': limit?.toString(), 'offset': offset?.toString()},
  );

  Future<dynamic> dropAccess(String address) =>
      delete('/v1/mailboxes/${enc(address)}/access');

  /// Buka alamat milik akun lain dengan password email-nya.
  Future<dynamic> unlockMailbox(String ref, String password) =>
      post('/v1/mailbox/${enc(ref)}/unlock', body: {'password': password});

  Future<dynamic> mailboxPassword(String ref) =>
      get('/v1/mailbox/${enc(ref)}/password');

  /// Ganti password email. [password] null/kosong = dibuatkan acak.
  Future<dynamic> setMailboxPassword(String ref, {String? password}) => put(
    '/v1/mailbox/${enc(ref)}/password',
    body: {if (password != null && password.isNotEmpty) 'password': password},
  );

  // ---------- mailbox ----------
  Future<dynamic> createMailbox({
    String? alias,
    String? domain,
    String? group,
    bool? check,
    String? saveAs,
    List<String>? exclude,
    bool? randomAlias,
    String? password,
  }) => post(
    '/v1/mailbox',
    body: {
      if (password != null && password.isNotEmpty) 'password': password,
      if (alias != null && alias.isNotEmpty) 'alias': alias,
      if (domain != null && domain.isNotEmpty) 'domain': domain,
      if (group != null && group.isNotEmpty) 'group': group,
      'check': ?check,
      if (saveAs != null && saveAs.isNotEmpty) 'save_as': saveAs,
      if (exclude != null && exclude.isNotEmpty) 'exclude': exclude,
      'random_alias': ?randomAlias,
    },
  );

  /// Alamat acak per grup domain. [exclude] = alamat/alias yang tidak boleh
  /// terpilih lagi (biasanya alamat aktif saat ini).
  Future<dynamic> quickCreate(
    String group, {
    List<String>? exclude,
    bool? randomAlias,
    String? saveAs,
  }) => post(
    '/v1/mailbox/quick/${enc(group)}',
    body: {
      if (exclude != null && exclude.isNotEmpty) 'exclude': exclude,
      'random_alias': ?randomAlias,
      if (saveAs != null && saveAs.isNotEmpty) 'save_as': saveAs,
    },
  );

  Future<dynamic> mailboxInfo(String ref) => get('/v1/mailbox/${enc(ref)}');

  Future<dynamic> messages(
    String ref, {
    String? from,
    String? subject,
    String? since,
    bool? hasOtp,
    String? order,
    int? limit,
    int? offset,
    bool text = false,
    bool html = false,
    bool? fresh,
  }) => get(
    '/v1/mailbox/${enc(ref)}/messages',
    query: {
      'from': from,
      'subject': subject,
      'since': since,
      'has_otp': hasOtp == true ? '1' : null,
      'order': order,
      'limit': limit?.toString(),
      'offset': offset?.toString(),
      'text': text ? '1' : null,
      'html': html ? '1' : null,
      'fresh': fresh == true ? '1' : null,
    },
  );

  Future<dynamic> messageDetail(String ref, String id, {bool html = true}) =>
      get(
        '/v1/mailbox/${enc(ref)}/messages/${enc(id)}',
        query: {'html': html ? '1' : '0'},
      );

  String rawMessageUrl(String ref, String id) =>
      '$kApiBase/v1/mailbox/${enc(ref)}/messages/${enc(id)}/raw';

  Map<String, String> get authHeaders => _headers;

  Future<dynamic> latestMessage(String ref, {String? from, String? subject}) =>
      get(
        '/v1/mailbox/${enc(ref)}/latest',
        query: {'from': from, 'subject': subject},
      );

  Future<dynamic> links(String ref, {bool all = false, String? kind}) => get(
    '/v1/mailbox/${enc(ref)}/links',
    query: {'all': all ? '1' : null, 'kind': kind},
  );

  Future<dynamic> deleteMessage(String ref, String id) =>
      delete('/v1/mailbox/${enc(ref)}/messages/${enc(id)}');

  Future<dynamic> deleteAllMessages(String ref) =>
      delete('/v1/mailbox/${enc(ref)}/messages', query: {'confirm': '1'});

  Future<dynamic> deleteMailbox(String ref) =>
      delete('/v1/mailbox/${enc(ref)}', query: {'confirm': '1'});

  Future<dynamic> markRead(String ref) => post('/v1/mailbox/${enc(ref)}/read');

  Future<dynamic> clearCache(String ref) =>
      delete('/v1/mailbox/${enc(ref)}/cache');

  // ---------- OTP & verifikasi ----------
  /// [fresh] = lewati cache server supaya email yang baru masuk ikut terbaca.
  Future<dynamic> otpLatest(String ref, {bool fresh = true}) =>
      get('/v1/otp/${enc(ref)}/latest', query: {'fresh': fresh ? '1' : null});

  Future<dynamic> otpWait(
    String ref, {
    int timeout = 50,
    int? interval,
    String? from,
    String? subject,
    int? length,
    bool includeExisting = false,
  }) => get(
    '/v1/otp/${enc(ref)}/wait',
    query: {
      'timeout': timeout.toString(),
      'interval': interval?.toString(),
      'from': from,
      'subject': subject,
      'length': length?.toString(),
      'include_existing': includeExisting ? '1' : null,
    },
    timeout: Duration(seconds: timeout + 25),
  );

  Future<dynamic> otpWaitAny({
    required List<String> refs,
    int timeout = 50,
    String mode = 'otp',
    String? from,
    String? subject,
    int? length,
    bool includeExisting = false,
  }) => post(
    '/v1/otp/wait-any',
    body: {
      'refs': refs,
      'timeout': timeout,
      'mode': mode,
      'from': ?from,
      'subject': ?subject,
      'length': ?length,
      'include_existing': includeExisting,
    },
    timeout: Duration(seconds: timeout + 25),
  );

  /// SSE: GET /v1/otp/{ref}/stream — event: ready/message/otp/ping/timeout
  Stream<Map<String, dynamic>> otpStream(String ref) async* {
    final tok = _token;
    final uri = _u('/v1/otp/${enc(ref)}/stream', {'token': tok});
    final res = await _guard(() async {
      final req = await _http.getUrl(uri);
      _headers.forEach(req.headers.set);
      req.headers.set('Accept', 'text/event-stream');
      return req.close();
    });
    if (res.statusCode >= 400) {
      final text = await res.transform(utf8.decoder).join();
      dynamic parsed;
      try {
        parsed = jsonDecode(text);
      } catch (_) {
        parsed = text;
      }
      throw _error(res.statusCode, parsed, 'Stream ditolak server', tok);
    }
    var event = 'message';
    await for (final line
        in res.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        final raw = line.substring(5).trim();
        try {
          final d = jsonDecode(raw);
          if (d is Map) {
            yield {'event': event, ...d.cast<String, dynamic>()};
          } else {
            yield {'event': event, 'data': d};
          }
        } catch (_) {
          yield {'event': event, 'raw': raw};
        }
        event = 'message';
      }
    }
  }

  Future<dynamic> otpHistory(String ref) => get('/v1/otp/${enc(ref)}/history');

  Future<dynamic> clearOtpHistory(String ref) =>
      delete('/v1/otp/${enc(ref)}/history');

  Future<dynamic> otpExtract(String text, {dynamic patterns}) =>
      post('/v1/otp/extract', body: {'text': text, 'patterns': ?patterns});

  Future<dynamic> verifyLatest(String ref) =>
      get('/v1/verify/${enc(ref)}/latest');

  Future<dynamic> verifyWait(String ref, {int timeout = 50}) => get(
    '/v1/verify/${enc(ref)}/wait',
    query: {'timeout': timeout.toString()},
    timeout: Duration(seconds: timeout + 25),
  );

  // ---------- favorit ----------
  Future<dynamic> favorites() => get('/v1/favorites');

  Future<dynamic> addFavorite(
    String address, {
    String? label,
    String? note,
    bool? pinned,
  }) => post(
    '/v1/favorites',
    body: {
      'address': address,
      'label': ?label,
      'note': ?note,
      'pinned': ?pinned,
    },
  );

  Future<dynamic> favoriteOne(String address) =>
      get('/v1/favorites/${enc(address)}');

  Future<dynamic> patchFavorite(
    String address, {
    String? label,
    String? note,
    bool? pinned,
  }) => patch(
    '/v1/favorites/${enc(address)}',
    body: {'label': ?label, 'note': ?note, 'pinned': ?pinned},
  );

  Future<dynamic> removeFavorite(String address) =>
      delete('/v1/favorites/${enc(address)}');

  Future<dynamic> clearFavorites() =>
      delete('/v1/favorites', query: {'confirm': '1'});

  Future<dynamic> exportFavorites() => rawGet('/v1/favorites/export');

  /// GET yang mengembalikan JSON apa adanya (untuk endpoint di luar
  /// amplop {ok,data} standar, mis. ekspor favorit {version,items}).
  Future<dynamic> rawGet(String path, {Map<String, String?>? query}) async {
    final tok = _token;
    final (status, parsed) = await _send('GET', path, query: query);
    if ((parsed is Map && parsed['error'] is Map) || status >= 400) {
      throw _error(status, parsed, 'Permintaan gagal', tok);
    }
    return parsed;
  }

  Future<dynamic> importFavorites(List<dynamic> items) =>
      post('/v1/favorites/import', body: {'items': items});

  // ---------- varian & gmail ----------
  Future<dynamic> variants(
    String ref, {
    String mode = 'both',
    int? count,
    String? tag,
  }) => get(
    '/v1/variants/${enc(ref)}',
    query: {'mode': mode, 'count': count?.toString(), 'tag': tag},
  );

  Future<dynamic> variantCreate(
    String ref, {
    required String mode,
    String? tag,
    List<String>? exclude,
    String? saveAs,
  }) => post(
    '/v1/mailbox/variant/${enc(ref)}',
    body: {'mode': mode, 'tag': ?tag, 'exclude': ?exclude, 'save_as': ?saveAs},
  );

  Future<dynamic> gmailVariants({
    required String email,
    String mode = 'both',
    String? order,
    int? dots,
    int? offset,
    int? limit,
    String? prefix,
    String? tags,
    String? q,
  }) => get(
    '/v1/gmail/variants',
    query: {
      'email': email,
      'mode': mode,
      'order': order,
      'dots': dots?.toString(),
      'offset': offset?.toString(),
      'limit': limit?.toString(),
      'prefix': prefix,
      'tags': tags,
      'q': q,
    },
  );

  // ---------- alias.md ----------
  Future<dynamic> aliasGet() => get('/v1/alias');

  Future<ApiResult> aliasPutRaw(
    String markdown, {
    String? domain,
    String? group,
  }) async {
    final (status, parsed) = await _send(
      'PUT',
      '/v1/alias',
      query: {'domain': domain, 'group': group},
      rawBody: markdown,
      contentType: ContentType('text', 'markdown', charset: 'utf-8'),
    );
    return _unwrap(status, parsed, 'Gagal menyimpan alias');
  }

  Future<dynamic> aliasValidate(
    String markdown, {
    String? domain,
    String? group,
  }) async {
    final (status, parsed) = await _send(
      'POST',
      '/v1/alias/validate',
      query: {'domain': domain, 'group': group},
      rawBody: markdown,
      contentType: ContentType('text', 'markdown', charset: 'utf-8'),
    );
    return _unwrap(status, parsed, 'Validasi gagal').data;
  }

  Future<dynamic> aliasDelete() => delete('/v1/alias');

  Future<dynamic> aliasOne(String name) => get('/v1/alias/${enc(name)}');

  Future<dynamic> aliasPutOne(String name, Object body) =>
      put('/v1/alias/${enc(name)}', body: body);

  Future<dynamic> aliasDeleteOne(String name) =>
      delete('/v1/alias/${enc(name)}');

  // ---------- domain ----------
  Future<dynamic> domains({
    String? q,
    String? group,
    int? page,
    int? perPage,
  }) => get(
    '/v1/domains',
    query: {
      'q': q,
      'group': group,
      'page': page?.toString(),
      'per_page': perPage?.toString(),
    },
  );

  Future<dynamic> domainRandom({String? group}) =>
      get('/v1/domains/random', query: {'group': group});

  Future<dynamic> domainGroups() => get('/v1/domains/groups');

  Future<dynamic> domainCheck(String domain) =>
      get('/v1/domains/check', query: {'domain': domain});

  // ---------- riwayat ----------
  Future<dynamic> history({int? limit, String? q}) =>
      get('/v1/history', query: {'limit': limit?.toString(), 'q': q});

  Future<dynamic> historyEvents({
    String? type,
    String? ref,
    int? hours,
    String? q,
    int? limit,
    int? offset,
    String? format,
  }) => get(
    '/v1/history/events',
    query: {
      'type': type,
      'ref': ref,
      'hours': hours?.toString(),
      'q': q,
      'limit': limit?.toString(),
      'offset': offset?.toString(),
      'format': format,
    },
  );

  Future<dynamic> deleteRecent(String address) =>
      delete('/v1/history/recent/${enc(address)}');

  Future<dynamic> clearHistory({String scope = 'all'}) =>
      delete('/v1/history', query: {'confirm': '1', 'scope': scope});

  // ---------- pantauan & notifikasi ----------
  Future<dynamic> watchList() => get('/v1/watch');

  Future<dynamic> watchCreate({
    required String ref,
    String? mode,
    String? from,
    String? subject,
    int? length,
    int? ttlMinutes,
    bool? once,
    bool? includeExisting,
    dynamic notify,
  }) => post(
    '/v1/watch',
    body: {
      'ref': ref,
      'mode': ?mode,
      'from': ?from,
      'subject': ?subject,
      'length': ?length,
      'ttl_minutes': ?ttlMinutes,
      'once': ?once,
      'include_existing': ?includeExisting,
      'notify': ?notify,
    },
  );

  Future<dynamic> watchRun() => post('/v1/watch/run');

  Future<dynamic> watchDelete(String id) => delete('/v1/watch/${enc(id)}');

  Future<dynamic> notifyTest({dynamic targets}) =>
      post('/v1/notify/test', body: targets ?? {});

  // ---------- debug & admin ----------
  Future<dynamic> debugRef(String ref, {String? mid, bool inbox = false}) =>
      get(
        '/v1/debug/${enc(ref)}',
        query: {'mid': mid, 'inbox': inbox ? '1' : null},
      );

  Future<dynamic> adminLogs({int limit = 100, String? level}) =>
      get('/v1/admin/logs', query: {'limit': limit.toString(), 'level': level});

  Future<dynamic> adminClearLogs() => delete('/v1/admin/logs');

  Future<dynamic> adminConfig() => get('/v1/admin/config');

  Future<dynamic> adminReload() => post('/v1/admin/reload');

  Future<dynamic> adminDomains() => get('/v1/admin/domains');

  Future<dynamic> adminPutDomains(Map<String, dynamic> groups) =>
      put('/v1/admin/domains', body: {'groups': groups});

  Future<dynamic> adminDeleteDomains() => delete('/v1/admin/domains');

  Future<dynamic> adminOtpPatterns() => get('/v1/admin/otp-patterns');

  Future<dynamic> adminPutOtpPatterns(dynamic patterns) =>
      put('/v1/admin/otp-patterns', body: {'patterns': patterns});

  Future<dynamic> adminDeleteOtpPatterns() => delete('/v1/admin/otp-patterns');

  // ---------- admin: akun APK publik ----------
  Future<dynamic> adminUsers({String? q}) =>
      get('/v1/admin/users', query: {'q': q, 'limit': '500'});

  /// [password] kosong = dibuatkan acak (dikembalikan sekali di respons).
  Future<dynamic> adminCreateUser({
    required String username,
    String? password,
    int? dailyQuota,
    int? maxDevices,
    String? expiresAt,
    String? note,
  }) => post(
    '/v1/admin/users',
    body: {
      'username': username,
      if (password != null && password.isNotEmpty) 'password': password,
      'daily_quota': ?dailyQuota,
      'max_devices': ?maxDevices,
      if (expiresAt != null && expiresAt.isNotEmpty) 'expires_at': expiresAt,
      if (note != null && note.isNotEmpty) 'note': note,
    },
  );

  Future<dynamic> adminUser(String username) =>
      get('/v1/admin/users/${enc(username)}');

  /// Kirim hanya field yang diubah. 'password': '' = reset acak,
  /// 'expires_at': null = permanen.
  Future<dynamic> adminPatchUser(String username, Map<String, dynamic> body) =>
      patch('/v1/admin/users/${enc(username)}', body: body);

  Future<dynamic> adminDeleteUser(String username) =>
      delete('/v1/admin/users/${enc(username)}', query: {'confirm': '1'});

  Future<dynamic> adminRevokeUserSessions(String username) =>
      delete('/v1/admin/users/${enc(username)}/sessions');

  Future<dynamic> adminMailboxes({String? q, String? owner, int? limit}) => get(
    '/v1/admin/mailboxes',
    query: {'q': q, 'owner': owner, 'limit': (limit ?? 100).toString()},
  );

  Future<dynamic> adminPatchMailbox(
    String address, {
    String? owner,
    bool? locked,
  }) => patch(
    '/v1/admin/mailboxes/${enc(address)}',
    body: {'owner': ?owner, 'locked': ?locked},
  );

  Future<dynamic> adminClaimExisting() =>
      post('/v1/admin/mailboxes/claim-existing', body: {});

  void close() => _http.close(force: true);
}
