// Klien API untuk rest-tempmail (Cloudflare Worker / Hono).
//
// Base URL & token TIDAK ditulis di kode: disuntik saat build lewat
//   flutter build apk --dart-define=API_BASE=https://... --dart-define=API_TOKEN=...
// Di CI, nilai itu datang dari GitHub Secrets repo.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String kApiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'https://rest-tempmail.rosdiyttaa.workers.dev',
);
const String kApiToken = String.fromEnvironment('API_TOKEN');

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

  TempmailApi() {
    // Lewat proxy bila lingkungan menyediakan (tidak wajib di HP).
    final proxy = Platform.environment['https_proxy'];
    if (proxy != null && proxy.isNotEmpty) {
      // HttpClient bawaan mengabaikan env; biarkan langsung (HP user normal).
    }
  }

  Uri _u(String path, [Map<String, String?>? q]) {
    final clean = <String, String>{};
    q?.forEach((k, v) {
      if (v != null && v.isNotEmpty) clean[k] = v;
    });
    return Uri.parse('$kApiBase$path')
        .replace(queryParameters: clean.isEmpty ? null : clean);
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $kApiToken',
        'X-API-Key': kApiToken,
        'Accept': 'application/json',
      };

  Future<ApiResult> call(
    String method,
    String path, {
    Map<String, String?>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 70),
  }) async {
    final req = await _http.openUrl(method, _u(path, query));
    _headers.forEach(req.headers.set);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close().timeout(timeout);
    final text = await res.transform(utf8.decoder).join();
    dynamic parsed;
    try {
      parsed = jsonDecode(text);
    } catch (_) {
      parsed = text;
    }
    if (parsed is Map && parsed['ok'] == true) {
      return ApiResult(parsed['data'],
          (parsed['meta'] as Map?)?.cast<String, dynamic>() ?? {});
    }
    if (parsed is Map && parsed['error'] is Map) {
      final e = parsed['error'] as Map;
      throw ApiException(
        res.statusCode,
        e['code']?.toString() ?? 'ERROR',
        e['message']?.toString() ?? 'Permintaan gagal (${res.statusCode})',
        e['details'],
      );
    }
    throw ApiException(res.statusCode, 'HTTP_${res.statusCode}',
        'Respons tak terduga (${res.statusCode})');
  }

  Future<dynamic> get(String path,
          {Map<String, String?>? query, Duration? timeout}) async =>
      (await call('GET', path, query: query,
              timeout: timeout ?? const Duration(seconds: 70)))
          .data;

  Future<dynamic> post(String path,
          {Map<String, String?>? query,
          Object? body,
          Duration? timeout}) async =>
      (await call('POST', path, query: query, body: body,
              timeout: timeout ?? const Duration(seconds: 70)))
          .data;

  Future<dynamic> put(String path,
          {Map<String, String?>? query, Object? body}) async =>
      (await call('PUT', path, query: query, body: body)).data;

  Future<dynamic> patch(String path, {Object? body}) async =>
      (await call('PATCH', path, body: body)).data;

  Future<dynamic> delete(String path, {Map<String, String?>? query}) async =>
      (await call('DELETE', path, query: query)).data;

  String enc(String ref) => Uri.encodeComponent(ref);

  // ---------- dasar ----------
  Future<dynamic> health() async {
    final req = await _http.getUrl(Uri.parse('$kApiBase/health'));
    final res = await req.close();
    return jsonDecode(await res.transform(utf8.decoder).join());
  }

  Future<dynamic> me() => get('/v1/me');

  // ---------- mailbox ----------
  Future<dynamic> createMailbox({
    String? alias,
    String? domain,
    String? group,
    bool? check,
    String? saveAs,
    List<String>? exclude,
    bool? randomAlias,
  }) =>
      post('/v1/mailbox', body: {
        if (alias != null && alias.isNotEmpty) 'alias': alias,
        if (domain != null && domain.isNotEmpty) 'domain': domain,
        if (group != null && group.isNotEmpty) 'group': group,
        if (check != null) 'check': check,
        if (saveAs != null && saveAs.isNotEmpty) 'save_as': saveAs,
        if (exclude != null && exclude.isNotEmpty) 'exclude': exclude,
        if (randomAlias != null) 'random_alias': randomAlias,
      });

  Future<dynamic> quickCreate(String group,
          {String? exclude, bool? randomAlias, String? saveAs}) =>
      post('/v1/mailbox/quick/${enc(group)}', query: {
        'exclude': exclude,
        'random_alias': randomAlias == true ? '1' : null,
        'save_as': saveAs,
      });

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
  }) =>
      get('/v1/mailbox/${enc(ref)}/messages', query: {
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
      });

  Future<dynamic> messageDetail(String ref, String id, {bool html = true}) =>
      get('/v1/mailbox/${enc(ref)}/messages/${enc(id)}',
          query: {'html': html ? '1' : '0'});

  String rawMessageUrl(String ref, String id) =>
      '$kApiBase/v1/mailbox/${enc(ref)}/messages/${enc(id)}/raw';

  Map<String, String> get authHeaders => _headers;

  Future<dynamic> latestMessage(String ref, {String? from, String? subject}) =>
      get('/v1/mailbox/${enc(ref)}/latest',
          query: {'from': from, 'subject': subject});

  Future<dynamic> links(String ref, {bool all = false, String? kind}) =>
      get('/v1/mailbox/${enc(ref)}/links',
          query: {'all': all ? '1' : null, 'kind': kind});

  Future<dynamic> deleteMessage(String ref, String id) =>
      delete('/v1/mailbox/${enc(ref)}/messages/${enc(id)}');

  Future<dynamic> deleteAllMessages(String ref) =>
      delete('/v1/mailbox/${enc(ref)}/messages', query: {'confirm': '1'});

  Future<dynamic> deleteMailbox(String ref) =>
      delete('/v1/mailbox/${enc(ref)}', query: {'confirm': '1'});

  Future<dynamic> markRead(String ref) =>
      post('/v1/mailbox/${enc(ref)}/read');

  Future<dynamic> clearCache(String ref) =>
      delete('/v1/mailbox/${enc(ref)}/cache');

  // ---------- OTP & verifikasi ----------
  Future<dynamic> otpLatest(String ref) => get('/v1/otp/${enc(ref)}/latest');

  Future<dynamic> otpWait(
    String ref, {
    int timeout = 50,
    int? interval,
    String? from,
    String? subject,
    int? length,
    bool includeExisting = false,
  }) =>
      get('/v1/otp/${enc(ref)}/wait',
          query: {
            'timeout': timeout.toString(),
            'interval': interval?.toString(),
            'from': from,
            'subject': subject,
            'length': length?.toString(),
            'include_existing': includeExisting ? '1' : null,
          },
          timeout: Duration(seconds: timeout + 25));

  Future<dynamic> otpWaitAny({
    required List<String> refs,
    int timeout = 50,
    String mode = 'otp',
    String? from,
    String? subject,
    int? length,
    bool includeExisting = false,
  }) =>
      post('/v1/otp/wait-any',
          body: {
            'refs': refs,
            'timeout': timeout,
            'mode': mode,
            if (from != null) 'from': from,
            if (subject != null) 'subject': subject,
            if (length != null) 'length': length,
            'include_existing': includeExisting,
          },
          timeout: Duration(seconds: timeout + 25));

  /// SSE: GET /v1/otp/{ref}/stream — event: ready/message/otp/ping/timeout
  Stream<Map<String, dynamic>> otpStream(String ref) async* {
    final uri = _u('/v1/otp/${enc(ref)}/stream', {'token': kApiToken});
    final req = await _http.getUrl(uri);
    _headers.forEach(req.headers.set);
    final res = await req.close();
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

  Future<dynamic> otpHistory(String ref) =>
      get('/v1/otp/${enc(ref)}/history');

  Future<dynamic> clearOtpHistory(String ref) =>
      delete('/v1/otp/${enc(ref)}/history');

  Future<dynamic> otpExtract(String text, {dynamic patterns}) =>
      post('/v1/otp/extract', body: {
        'text': text,
        if (patterns != null) 'patterns': patterns,
      });

  Future<dynamic> verifyLatest(String ref) =>
      get('/v1/verify/${enc(ref)}/latest');

  Future<dynamic> verifyWait(String ref, {int timeout = 50}) =>
      get('/v1/verify/${enc(ref)}/wait',
          query: {'timeout': timeout.toString()},
          timeout: Duration(seconds: timeout + 25));

  // ---------- favorit ----------
  Future<dynamic> favorites() => get('/v1/favorites');

  Future<dynamic> addFavorite(String address,
          {String? label, String? note, bool? pinned}) =>
      post('/v1/favorites', body: {
        'address': address,
        if (label != null) 'label': label,
        if (note != null) 'note': note,
        if (pinned != null) 'pinned': pinned,
      });

  Future<dynamic> favoriteOne(String address) =>
      get('/v1/favorites/${enc(address)}');

  Future<dynamic> patchFavorite(String address,
          {String? label, String? note, bool? pinned}) =>
      patch('/v1/favorites/${enc(address)}', body: {
        if (label != null) 'label': label,
        if (note != null) 'note': note,
        if (pinned != null) 'pinned': pinned,
      });

  Future<dynamic> removeFavorite(String address) =>
      delete('/v1/favorites/${enc(address)}');

  Future<dynamic> clearFavorites() =>
      delete('/v1/favorites', query: {'confirm': '1'});

  Future<dynamic> exportFavorites() => rawGet('/v1/favorites/export');

  /// GET yang mengembalikan JSON apa adanya (untuk endpoint di luar
  /// amplop {ok,data} standar, mis. ekspor favorit {version,items}).
  Future<dynamic> rawGet(String path,
      {Map<String, String?>? query}) async {
    final req = await _http.openUrl('GET', _u(path, query));
    _headers.forEach(req.headers.set);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    dynamic parsed;
    try {
      parsed = jsonDecode(text);
    } catch (_) {
      parsed = text;
    }
    if (parsed is Map && parsed['error'] is Map) {
      final e = parsed['error'] as Map;
      throw ApiException(res.statusCode, e['code']?.toString() ?? 'ERROR',
          e['message']?.toString() ?? 'Permintaan gagal');
    }
    if (res.statusCode >= 400) {
      throw ApiException(
          res.statusCode, 'HTTP_${res.statusCode}', 'Respons tak terduga');
    }
    return parsed;
  }

  Future<dynamic> importFavorites(List<dynamic> items) =>
      post('/v1/favorites/import', body: {'items': items});

  // ---------- varian & gmail ----------
  Future<dynamic> variants(String ref,
          {String mode = 'both', int? count, String? tag}) =>
      get('/v1/variants/${enc(ref)}', query: {
        'mode': mode,
        'count': count?.toString(),
        'tag': tag,
      });

  Future<dynamic> variantCreate(String ref,
          {required String mode, String? tag, List<String>? exclude, String? saveAs}) =>
      post('/v1/mailbox/variant/${enc(ref)}', body: {
        'mode': mode,
        if (tag != null) 'tag': tag,
        if (exclude != null) 'exclude': exclude,
        if (saveAs != null) 'save_as': saveAs,
      });

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
  }) =>
      get('/v1/gmail/variants', query: {
        'email': email,
        'mode': mode,
        'order': order,
        'dots': dots?.toString(),
        'offset': offset?.toString(),
        'limit': limit?.toString(),
        'prefix': prefix,
        'tags': tags,
        'q': q,
      });

  // ---------- alias.md ----------
  Future<dynamic> aliasGet() => get('/v1/alias');

  Future<ApiResult> aliasPutRaw(String markdown,
      {String? domain, String? group}) async {
    final req = await _http.putUrl(_u('/v1/alias', {
      'domain': domain,
      'group': group,
    }));
    _headers.forEach(req.headers.set);
    req.headers.contentType = ContentType('text', 'markdown');
    req.write(markdown);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final parsed = jsonDecode(text);
    if (parsed is Map && parsed['ok'] == true) {
      return ApiResult(parsed['data'],
          (parsed['meta'] as Map?)?.cast<String, dynamic>() ?? {});
    }
    final e = (parsed as Map)['error'] as Map;
    throw ApiException(res.statusCode, e['code']?.toString() ?? 'ERROR',
        e['message']?.toString() ?? 'Gagal menyimpan alias');
  }

  Future<dynamic> aliasValidate(String markdown) async {
    final req = await _http.postUrl(_u('/v1/alias/validate'));
    _headers.forEach(req.headers.set);
    req.headers.contentType = ContentType('text', 'markdown');
    req.write(markdown);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final parsed = jsonDecode(text);
    if (parsed is Map && parsed['ok'] == true) return parsed['data'];
    final e = (parsed as Map)['error'] as Map;
    throw ApiException(res.statusCode, e['code']?.toString() ?? 'ERROR',
        e['message']?.toString() ?? 'Validasi gagal');
    }

  Future<dynamic> aliasDelete() => delete('/v1/alias');

  Future<dynamic> aliasOne(String name) => get('/v1/alias/${enc(name)}');

  Future<dynamic> aliasPutOne(String name, Object body) =>
      put('/v1/alias/${enc(name)}', body: body);

  Future<dynamic> aliasDeleteOne(String name) =>
      delete('/v1/alias/${enc(name)}');

  // ---------- domain ----------
  Future<dynamic> domains({String? q, String? group, int? page}) =>
      get('/v1/domains', query: {
        'q': q,
        'group': group,
        'page': page?.toString(),
      });

  Future<dynamic> domainRandom({String? group}) =>
      get('/v1/domains/random', query: {'group': group});

  Future<dynamic> domainGroups() => get('/v1/domains/groups');

  Future<dynamic> domainCheck(String domain) =>
      get('/v1/domains/check', query: {'domain': domain});

  // ---------- riwayat ----------
  Future<dynamic> history({int? limit, String? q}) => get('/v1/history',
      query: {'limit': limit?.toString(), 'q': q});

  Future<dynamic> historyEvents({
    String? type,
    String? ref,
    int? hours,
    String? q,
    int? limit,
    int? offset,
    String? format,
  }) =>
      get('/v1/history/events', query: {
        'type': type,
        'ref': ref,
        'hours': hours?.toString(),
        'q': q,
        'limit': limit?.toString(),
        'offset': offset?.toString(),
        'format': format,
      });

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
  }) =>
      post('/v1/watch', body: {
        'ref': ref,
        if (mode != null) 'mode': mode,
        if (from != null) 'from': from,
        if (subject != null) 'subject': subject,
        if (length != null) 'length': length,
        if (ttlMinutes != null) 'ttl_minutes': ttlMinutes,
        if (once != null) 'once': once,
        if (includeExisting != null) 'include_existing': includeExisting,
        if (notify != null) 'notify': notify,
      });

  Future<dynamic> watchRun() => post('/v1/watch/run');

  Future<dynamic> watchDelete(String id) => delete('/v1/watch/${enc(id)}');

  Future<dynamic> notifyTest({dynamic targets}) =>
      post('/v1/notify/test', body: targets ?? {});

  // ---------- debug & admin ----------
  Future<dynamic> debugRef(String ref, {String? mid, bool inbox = false}) =>
      get('/v1/debug/${enc(ref)}', query: {
        'mid': mid,
        'inbox': inbox ? '1' : null,
      });

  Future<dynamic> adminLogs({int limit = 100, String? level}) =>
      get('/v1/admin/logs',
          query: {'limit': limit.toString(), 'level': level});

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

  Future<dynamic> adminDeleteOtpPatterns() =>
      delete('/v1/admin/otp-patterns');

  void close() => _http.close(force: true);
}
