// Layar Beranda (mailbox aktif + buat alamat), Inbox, dan detail pesan.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'account.dart';
import 'api.dart';
import 'main.dart';
import 'otp_detect.dart';
import 'update.dart';

/// Parse waktu dari API. String tanpa zona waktu (mis. "2026-10-20 16:04:48",
/// yang oleh web resmi ditampilkan sebagai UTC) dianggap UTC.
DateTime? parseApiTime(dynamic v) {
  if (v == null) return null;
  if (v is num) {
    // detik / milidetik epoch
    final ms = v > 100000000000 ? v.toInt() : (v * 1000).toInt();
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  final hasZone = RegExp(
    r'(Z|[+-]\d\d:?\d\d)$',
    caseSensitive: false,
  ).hasMatch(s);
  return DateTime.tryParse(hasZone ? s : '${s}Z') ?? DateTime.tryParse(s);
}

String fmtTime(dynamic iso) {
  if (iso == null) return '-';
  final d = parseApiTime(iso);
  if (d == null) return iso.toString();
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)} ${two(l.hour)}:${two(l.minute)}';
}

/// Waktu terima email: utamakan field tanggal, lalu `time`, lalu umur.
DateTime? msgDate(Map m) {
  for (final k in ['received_at', 'date', 'created_at', 'time']) {
    final d = parseApiTime(m[k]);
    if (d != null) return d;
  }
  final age = m['age_seconds'];
  if (age is num) {
    return DateTime.now().toUtc().subtract(Duration(seconds: age.round()));
  }
  return null;
}

/// Label waktu singkat untuk daftar inbox.
String msgTimeShort(Map m) {
  final age = m['age_seconds'];
  if (age is num && age < 86400) return agoText(age);
  final d = msgDate(m);
  return d == null ? '' : fmtTime(d.toIso8601String());
}

/// Label waktu lengkap untuk detail email.
String msgTimeFull(Map m) {
  final d = msgDate(m);
  if (d == null) return (m['time'] ?? '-').toString();
  final ago = agoText(m['age_seconds']);
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final abs =
      '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
  return ago.isEmpty ? abs : '$abs ($ago)';
}

/// Huruf pertama untuk avatar; aman untuk string kosong.
String initialOf(dynamic from) {
  final s = (from ?? '').toString().trim();
  final name = s.startsWith('"') ? s.substring(1) : s;
  if (name.isEmpty) return '?';
  return name.characters.first.toUpperCase();
}

String _str(dynamic v, [String fallback = '']) {
  final s = v?.toString() ?? '';
  return s.trim().isEmpty ? fallback : s;
}

/// Jumlah domain per tombol "Buat cepat" dari respons /v1/domains/groups.
/// Nama grup dari server bisa beda huruf besar/spasi ("Premium ",
/// "premium-domains", ...), jadi dicocokkan longgar. `semua` = total.
Map<String, int> quickGroupCounts(dynamic r, List<String> quick) {
  final counts = <String, int>{};
  var total = 0;
  for (final g in listOf(r, ['groups', 'items'])) {
    if (g is! Map) continue;
    final raw = g['count'];
    final c = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
    total += c;
    final names = [
      g['name'],
      g['key'],
      g['id'],
      g['slug'],
    ].where((v) => v != null).map((v) => v.toString().trim().toLowerCase());
    for (final q in quick) {
      if (q != 'semua' && names.any((n) => n == q || n.startsWith(q))) {
        counts[q] = (counts[q] ?? 0) + c;
      }
    }
  }
  if (total > 0) counts['semua'] = total;
  return counts;
}

// ============================ BERANDA ============================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _alias = TextEditingController();
  final _domain = TextEditingController();
  final _group = TextEditingController();
  final _saveAs = TextEditingController();
  bool _busy = false;
  String? _busyGroup;
  dynamic _lastCreated;
  dynamic _info;
  String? _infoRef;
  // Galat akses alamat aktif (password diganti pemilik, dikunci, dll.).
  ApiException? _accessError;
  Map<String, int> _groupCounts = {};
  bool _refreshing = false;

  static const _quickGroups = ['premium', 'basic', 'standard', 'semua'];
  static const _kAccessCodes = {
    'MAILBOX_PASSWORD_REQUIRED',
    'MAILBOX_LOCKED',
    'MAILBOX_UNCLAIMED',
  };

  // Tiga tombol sebaris di layar sempit: padding kecil agar label tidak patah.
  static final _compact = FilledButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 8),
  );

  @override
  void initState() {
    super.initState();
    appState.addListener(_onState);
    currentTab.addListener(_onTab);
    favoriteAddresses.addListener(_onFavorites);
    _loadInfo();
    _loadGroupCounts();
    refreshFavorites();
  }

  void _onFavorites() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    appState.removeListener(_onState);
    currentTab.removeListener(_onTab);
    favoriteAddresses.removeListener(_onFavorites);
    _alias.dispose();
    _domain.dispose();
    _group.dispose();
    _saveAs.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {
      // Info milik alamat lama jangan ikut tampil di alamat baru.
      if (_infoRef != appState.activeRef) _info = null;
      _accessError = null;
    });
    _loadInfo();
  }

  // Kembali ke Beranda dari tab lain → jumlah pesan ikut diperbarui.
  void _onTab() {
    if (currentTab.value == kTabHome) {
      _loadInfo();
      refreshFavorites(); // favorit bisa berubah di tab lain
    }
  }

  /// [showErrors] = tampilkan galat (saat refresh manual); muat otomatis diam.
  Future<void> _loadInfo({bool showErrors = false}) async {
    final ref = appState.activeRef;
    if (ref == null) return;
    try {
      final info = await api.mailboxInfo(ref);
      if (mounted && appState.activeRef == ref) {
        setState(() {
          _info = info;
          _infoRef = ref;
          _accessError = null;
        });
      }
    } catch (e) {
      if (mounted &&
          appState.activeRef == ref &&
          e is ApiException &&
          _kAccessCodes.contains(e.code)) {
        setState(() => _accessError = e);
        return;
      }
      if (showErrors && mounted) showError(context, e);
    }
  }

  /// Tarik ke bawah / tombol refresh: info mailbox + jumlah domain per grup.
  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await Future.wait([
        _loadInfo(showErrors: true),
        _loadGroupCounts(),
        refreshFavorites(),
      ]);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _loadGroupCounts() async {
    try {
      final r = await api.domainGroups();
      final counts = quickGroupCounts(r, _quickGroups);
      if (mounted) setState(() => _groupCounts = counts);
    } catch (_) {}
  }

  Future<void> _create({String? quickGroup}) async {
    setState(() {
      _busy = true;
      _busyGroup = quickGroup;
    });
    try {
      dynamic r;
      final cur = appState.activeRef;
      if (quickGroup != null) {
        // Jangan sampai alamat acak baru = alamat yang sedang aktif.
        r = await api.quickCreate(
          quickGroup,
          exclude: cur == null ? null : [cur],
        );
      } else {
        final alias = _alias.text.trim();
        r = await api.createMailbox(
          alias: alias,
          domain: _domain.text.trim(),
          group: _group.text.trim(),
          // APK publik: kolom ini = password email; admin: simpan sbg alias.
          saveAs: kPublic ? null : _saveAs.text.trim(),
          password: kPublic ? _saveAs.text : null,
          exclude: alias.isEmpty && cur != null ? [cur] : null,
          check: !kPublic,
        );
      }
      final address = r['address'].toString();
      final ref = (r['ref'] ?? r['saved_as'] ?? address).toString();
      await appState.setActive(ref, address);
      if (r is Map) authState.applyQuota(r['quota']);
      if (!mounted) return;
      setState(() => _lastCreated = r);
      // Alamat custom di APK publik: tunjukkan password-nya sekali di depan.
      if (kPublic && quickGroup == null && r is Map && r['password'] != null) {
        _saveAs.clear();
        await showMailboxPasswordDialog(
          context,
          address,
          password: '${r['password']}',
          title: r['created'] == false
              ? 'Alamat ini sudah milikmu'
              : 'Alamat dibuat',
        );
        if (!mounted) return;
      }
      final ws = r is Map ? listOf(r['warnings']) : const [];
      // Satu snackbar saja: catatan server tidak menimpa konfirmasi salin.
      await copyText(
        context,
        address,
        ws.isEmpty
            ? 'Alamat aktif & disalin: $address'
            : 'Alamat aktif & disalin: $address\nCatatan: ${ws.join(' • ')}',
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      // Sudah dipakai akun lain → tawarkan buka dengan password-nya.
      final d = e.details is Map ? e.details as Map : const {};
      if (e.code == 'ADDRESS_TAKEN') {
        final a = d['address']?.toString();
        if (await resolveAccessError(context, e, address: a) && a != null) {
          await appState.setActive(a, a);
          if (mounted) showOk(context, 'Alamat dibuka: $a');
        }
        return;
      }
      showError(context, e);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyGroup = null;
        });
      }
    }
  }

  /// Pilih domain dari daftar server (APK publik hanya boleh domain terdaftar).
  Future<void> _pickDomain() async {
    final d = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _DomainPicker(),
    );
    if (d != null) setState(() => _domain.text = d);
  }

  Future<void> _action(String kind) async {
    final ref = appState.activeRef;
    if (ref == null) return;
    try {
      if (kind == 'read') {
        await api.markRead(ref);
        if (mounted) showOk(context, 'Semua ditandai dibaca');
      } else if (kind == 'cache') {
        await api.clearCache(ref);
        if (mounted) showOk(context, 'Cache mailbox dibersihkan');
      } else if (kind == 'fav') {
        // Toggle seperti web resmi: sudah favorit → hapus (dengan konfirmasi).
        final addr = appState.activeAddress ?? ref;
        if (isFavorite(addr)) {
          final ok = await confirmDialog(
            context,
            title: 'Hapus dari favorit?',
            body: '$addr tidak akan tersimpan permanen lagi.',
          );
          if (!ok) return;
          await api.removeFavorite(addr);
          markFavorite(addr, false);
          if (mounted) showOk(context, 'Dihapus dari favorit');
        } else {
          final r = await api.addFavorite(addr);
          markFavorite(addr, true);
          if (mounted) {
            showOk(
              context,
              r is Map && r['created'] == false
                  ? 'Sudah ada di favorit'
                  : 'Ditambahkan ke favorit',
            );
          }
        }
      } else if (kind == 'wipe') {
        final ok = await confirmDialog(
          context,
          title: 'Hapus inbox?',
          body:
              'Semua email + riwayat OTP untuk ${appState.activeAddress} akan dihapus permanen. '
              'Alamatnya tetap aktif dan tetap bisa menerima email baru.',
        );
        if (!ok) return;
        // Seperti web resmi: hanya isi inbox yang dihapus, alamat tetap aktif.
        final r = await api.deleteMailbox(ref);
        if (mounted) {
          setState(() => _info = null);
          final n = r is Map ? r['deleted_count'] : null;
          showOk(context, n == null ? 'Inbox dikosongkan' : '$n email dihapus');
        }
        _loadInfo();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _groupField() => TextField(
    controller: _group,
    textInputAction: TextInputAction.next,
    autocorrect: false,
    decoration: const InputDecoration(
      labelText: 'Grup domain',
      hintText: 'premium / basic / standard',
      prefixIcon: Icon(Icons.folder_outlined),
    ),
  );

  /// Admin: simpan sbg alias (alias.md). Publik: password email.
  Widget _secondField() => TextField(
    controller: _saveAs,
    autocorrect: false,
    enableSuggestions: !kPublic,
    textInputAction: TextInputAction.done,
    onSubmitted: (_) => _busy ? null : _create(),
    decoration: InputDecoration(
      labelText: kPublic ? 'Password email' : 'Simpan sbg alias',
      hintText: kPublic ? 'Kosongkan untuk dibuatkan acak' : null,
      prefixIcon: Icon(kPublic ? Icons.key_outlined : Icons.bookmark_outline),
    ),
  );

  /// Akses ke alamat aktif menurut server: owner | shared | admin.
  String? get _access => _info is Map && _infoRef == appState.activeRef
      ? (_info as Map)['access']?.toString()
      : null;

  String _countLabel() {
    final i = _info;
    if (i is! Map) return '';
    final n = i['message_count'] ?? i['total'] ?? i['count'];
    return n == null ? '' : '$n pesan';
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final addr = appState.activeAddress;
    final ref = appState.activeRef;
    final count = _countLabel();
    return Scaffold(
      appBar: AppBar(
        title: const Text('TempMail'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _refreshing ? null : _refresh,
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            const UpdateBanner(),
            if (!kPublic && kApiToken.isEmpty) ...[
              Card(
                color: s.errorContainer,
                child: ListTile(
                  leading: Icon(
                    Icons.key_off_outlined,
                    color: s.onErrorContainer,
                  ),
                  title: Text(
                    'Token API belum terpasang',
                    style: TextStyle(
                      color: s.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    'Build ulang dengan --dart-define=API_TOKEN=... agar aplikasi bisa memanggil server.',
                    style: TextStyle(color: s.onErrorContainer),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.alternate_email, color: s.primary),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Mailbox aktif',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (count.isNotEmpty)
                          Chip(
                            label: Text(count),
                            visualDensity: VisualDensity.compact,
                            side: BorderSide.none,
                            backgroundColor: s.secondaryContainer,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (addr == null)
                      Text(
                        'Belum ada alamat aktif. Buat dulu di bawah ya.',
                        style: TextStyle(color: s.onSurfaceVariant),
                      )
                    else ...[
                      SelectableText(
                        addr,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (ref != null && ref != addr)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'ref: $ref',
                            style: TextStyle(color: s.onSurfaceVariant),
                          ),
                        ),
                      if (_access == 'shared')
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Milik akun lain (dibuka dengan password)',
                            style: TextStyle(color: s.onSurfaceVariant),
                          ),
                        ),
                      if (_accessError != null) ...[
                        const SizedBox(height: 10),
                        _AccessBanner(
                          error: _accessError!,
                          onUnlock: () async {
                            if (_accessError!.code == 'MAILBOX_LOCKED') {
                              await appState.clearActive();
                              return;
                            }
                            if (await resolveAccessError(
                              context,
                              _accessError!,
                              address: addr,
                            )) {
                              _loadInfo(showErrors: true);
                            }
                          },
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              style: _compact,
                              onPressed: () =>
                                  copyText(context, addr, 'Alamat disalin'),
                              icon: const Icon(Icons.copy, size: 18),
                              label: const Text('Salin'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              style: _compact,
                              onPressed: () => currentTab.value = kTabInbox,
                              icon: const Icon(Icons.inbox, size: 18),
                              label: const Text('Inbox'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              style: _compact,
                              onPressed: () => currentTab.value = kTabOtp,
                              icon: const Icon(Icons.pin, size: 18),
                              label: const Text('OTP'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Alamat tidak bisa dibuka → aksi lain tidak berguna.
                      if (_accessError == null)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (isFavorite(addr))
                              FilledButton.tonalIcon(
                                onPressed: () => _action('fav'),
                                icon: const Icon(Icons.star, size: 18),
                                label: const Text('Favorit'),
                              )
                            else
                              OutlinedButton.icon(
                                onPressed: () => _action('fav'),
                                icon: const Icon(Icons.star_outline, size: 18),
                                label: const Text('Favoritkan'),
                              ),
                            OutlinedButton.icon(
                              onPressed: () => _action('read'),
                              icon: const Icon(Icons.done_all, size: 18),
                              label: const Text('Tandai dibaca'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => _action('cache'),
                              icon: const Icon(
                                Icons.cleaning_services_outlined,
                                size: 18,
                              ),
                              label: const Text('Bersih cache'),
                            ),
                            if (_access == 'owner' || _access == 'admin')
                              OutlinedButton.icon(
                                onPressed: () =>
                                    showMailboxPasswordDialog(context, addr),
                                icon: const Icon(Icons.key_outlined, size: 18),
                                label: const Text('Password'),
                              ),
                            if (_access != 'shared')
                              OutlinedButton.icon(
                                onPressed: () => _action('wipe'),
                                icon: Icon(
                                  Icons.delete_forever_outlined,
                                  size: 18,
                                  color: s.error,
                                ),
                                label: Text(
                                  'Hapus inbox',
                                  style: TextStyle(color: s.error),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Buat cepat',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Alamat acak per jenis domain, langsung aktif & disalin.',
              style: TextStyle(color: s.onSurfaceVariant),
            ),
            if (kPublic)
              ListenableBuilder(
                listenable: authState,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Jatah hari ini: ${quotaText(authState.user)} alamat baru',
                    style: TextStyle(
                      color: s.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final g in _quickGroups)
                  ActionChip(
                    avatar: _busyGroup == g
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bolt, size: 16),
                    label: Text(
                      _groupCounts[g] == null ? g : '$g · ${_groupCounts[g]}',
                    ),
                    onPressed: _busy ? null : () => _create(quickGroup: g),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            const Text(
              'Buat manual',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _alias,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: kPublic
                    ? 'Alias (kosong = acak)'
                    : 'Alias (kosong = acak dari alias.md)',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _domain,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: kPublic
                    ? 'Domain (kosong = acak)'
                    : 'Domain (opsional)',
                prefixIcon: const Icon(Icons.language),
                suffixIcon: IconButton(
                  tooltip: 'Pilih dari daftar domain',
                  onPressed: _pickDomain,
                  icon: const Icon(Icons.list),
                ),
              ),
            ),
            const SizedBox(height: 10),
            // APK publik: password email butuh ruang → satu baris sendiri.
            if (kPublic) ...[
              _groupField(),
              const SizedBox(height: 10),
              _secondField(),
            ] else
              Row(
                children: [
                  Expanded(child: _groupField()),
                  const SizedBox(width: 10),
                  Expanded(child: _secondField()),
                ],
              ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _busy ? null : () => _create(),
              icon: _busy && _busyGroup == null
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: const Text('Buat alamat'),
            ),
            if (kPublic) ...[
              const SizedBox(height: 10),
              Text(
                'Setiap alamat punya password. Orang lain hanya bisa membaca '
                'inbox-mu bila tahu password-nya.',
                style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
              ),
            ],
            if (!kPublic && _lastCreated != null) ...[
              const SizedBox(height: 12),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text(
                    'Detail respons pembuatan',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  children: [JsonView(_lastCreated)],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================ INBOX ============================
/// Alamat aktif tidak bisa dibuka (password diganti / dikunci / belum terdaftar).
class _AccessBanner extends StatelessWidget {
  final ApiException error;
  final VoidCallback onUnlock;
  const _AccessBanner({required this.error, required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final (label, icon) = switch (error.code) {
      'MAILBOX_PASSWORD_REQUIRED' => ('Masukkan password', Icons.key),
      'MAILBOX_UNCLAIMED' => ('Daftarkan ke akunku', Icons.add_task),
      'MAILBOX_LOCKED' => ('Pilih alamat lain', Icons.swap_horiz),
      _ => ('', Icons.error_outline),
    };
    final canUnlock = label.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: s.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(error.message, style: TextStyle(color: s.onErrorContainer)),
          if (canUnlock) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: onUnlock,
              icon: Icon(icon, size: 18),
              label: Text(label),
            ),
          ],
        ],
      ),
    );
  }
}

class _DomainPicker extends StatefulWidget {
  const _DomainPicker();
  @override
  State<_DomainPicker> createState() => _DomainPickerState();
}

class _DomainPickerState extends State<_DomainPicker> {
  final _q = TextEditingController();
  List _items = const [];
  bool _loading = true;
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final q = _q.text.trim();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await api.domains(q: q, perPage: 100);
      if (mounted && q == _q.text.trim()) {
        setState(() => _items = listOf(r, ['items', 'domains']));
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _q,
              autofocus: true,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: 'Cari domain',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), _load);
              },
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: TextStyle(color: s.error)),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _items.length,
              itemBuilder: (ctx, i) {
                final m = _items[i];
                final d = m is Map ? '${m['domain'] ?? m['name']}' : '$m';
                final g = m is Map ? m['group']?.toString() : null;
                return ListTile(
                  dense: true,
                  title: Text(d),
                  subtitle: g == null ? null : Text(g),
                  onTap: () => Navigator.pop(context, d),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});
  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  List<dynamic> _msgs = [];
  List<dynamic> _recent = [];
  bool _loading = false;
  bool _onlyOtp = false;
  bool _auto = false;
  String? _err;
  String? _loadedRef;
  int _seq = 0; // abaikan respons lama bila ada permintaan yang lebih baru
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    appState.addListener(_onState);
    currentTab.addListener(_onTab);
    _reload();
    _loadRecent();
  }

  @override
  void dispose() {
    appState.removeListener(_onState);
    currentTab.removeListener(_onTab);
    _timer?.cancel();
    super.dispose();
  }

  void _onState() {
    if (appState.activeRef != _loadedRef) {
      _reload();
      _loadRecent();
    } else if (mounted) {
      setState(() {});
    }
  }

  void _onTab() {
    // Muat ulang saat tab Inbox dibuka lagi supaya email baru langsung tampil.
    if (currentTab.value == kTabInbox && !_loading) {
      _reload(silent: _msgs.isNotEmpty);
      _loadRecent();
    }
  }

  void _setAuto(bool on) {
    _timer?.cancel();
    _timer = null;
    setState(() => _auto = on);
    if (on) {
      _timer = Timer.periodic(const Duration(seconds: 12), (_) {
        if (currentTab.value == kTabInbox && !_loading) {
          _reload(silent: true);
        }
      });
      showOk(context, 'Auto-refresh tiap 12 detik aktif');
    }
  }

  Future<void> _loadRecent() async {
    try {
      final r = await api.history(limit: 20);
      if (mounted) setState(() => _recent = listOf(r, ['items', 'recent']));
    } catch (_) {}
  }

  Future<void> _reload({bool silent = false}) async {
    final ref = appState.activeRef;
    final seq = ++_seq;
    if (ref == null) {
      if (mounted) {
        setState(() {
          _msgs = [];
          _err = null;
          _loading = false;
          _loadedRef = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        if (ref != _loadedRef) _msgs = [];
        _loading = !silent;
        _err = null;
      });
    }
    try {
      final r = await api.messages(
        ref,
        hasOtp: _onlyOtp ? true : null,
        limit: 50,
        fresh: true,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _msgs = listOf(r, ['messages', 'items']);
        _loadedRef = ref;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _err = errorText(e);
        _loadedRef = ref;
        _loading = false;
      });
    }
  }

  Future<void> _deleteAll() async {
    final ref = appState.activeRef;
    if (ref == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Hapus semua email?',
      body: 'Semua email di ${appState.activeAddress} akan dihapus.',
    );
    if (!ok) return;
    try {
      final r = await api.deleteAllMessages(ref);
      if (mounted) {
        final n = r is Map ? r['deleted_count'] ?? r['deleted'] : null;
        showOk(context, n == null ? 'Semua email dihapus' : '$n email dihapus');
      }
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<bool> _deleteOne(Map m) async {
    final ref = appState.activeRef;
    final id = m['id']?.toString();
    if (ref == null || id == null) return false;
    final ok = await confirmDialog(
      context,
      title: 'Hapus email ini?',
      body: _str(m['subject'], '(Tanpa subjek)'),
    );
    if (!ok) return false;
    try {
      await api.deleteMessage(ref, id);
      if (mounted) showOk(context, 'Email dihapus');
      return true;
    } catch (e) {
      if (mounted) showError(context, e);
      return false;
    }
  }

  Future<void> _open(String ref, Map m) async {
    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MessageDetailScreen(ref: ref, message: m),
      ),
    );
    if (deleted == true) _reload(silent: true);
  }

  /// Daftar yang selalu bisa ditarik (pull-to-refresh) walau isinya cuma
  /// pesan kosong/galat.
  Widget _scrollableState(Widget child) => LayoutBuilder(
    builder: (ctx, c) => ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: child,
        ),
      ],
    ),
  );

  Widget _body(String ref) {
    if (_loading && _msgs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final Widget content;
    if (_err != null && _msgs.isEmpty) {
      content = _scrollableState(
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            EmptyState(
              icon: Icons.error_outline,
              title: 'Gagal memuat inbox',
              subtitle: _err,
            ),
            FilledButton.tonalIcon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              label: const Text('Coba lagi'),
            ),
          ],
        ),
      );
    } else if (_msgs.isEmpty) {
      content = _scrollableState(
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            EmptyState(
              icon: _onlyOtp
                  ? Icons.filter_alt_off_outlined
                  : Icons.mark_email_unread_outlined,
              title: _onlyOtp ? 'Belum ada email ber-OTP' : 'Inbox kosong',
              subtitle: _onlyOtp
                  ? 'Filter "hanya OTP" aktif. Email lain disembunyikan.'
                  : 'Belum ada email masuk. Tarik ke bawah untuk menyegarkan.',
            ),
            if (_onlyOtp)
              FilledButton.tonalIcon(
                onPressed: () {
                  setState(() => _onlyOtp = false);
                  _reload();
                },
                icon: const Icon(Icons.filter_alt_off),
                label: const Text('Tampilkan semua email'),
              ),
          ],
        ),
      );
    } else {
      final s = Theme.of(context).colorScheme;
      content = ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _msgs.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final m = _msgs[i] as Map;
          // OTP dari server, atau terdeteksi aplikasi bila server melewatkannya.
          final otp = messageOtp(m)?.$1;
          final subject = _str(m['subject'], '(Tanpa subjek)');
          final from = _str(m['from'], '-');
          return Dismissible(
            key: ValueKey(m['id'] ?? '$i-$subject'),
            direction: m['id'] == null
                ? DismissDirection.none
                : DismissDirection.endToStart,
            confirmDismiss: (_) => _deleteOne(m),
            // Hapus menurut id: _msgs bisa sudah diganti auto-refresh saat
            // dialog konfirmasi terbuka, jadi `remove(m)` tidak menemukannya.
            onDismissed: (_) => setState(
              () => _msgs.removeWhere((x) => x is Map && x['id'] == m['id']),
            ),
            background: Container(
              color: s.errorContainer,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Icon(Icons.delete_outline, color: s.onErrorContainer),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 6,
              ),
              leading: CircleAvatar(child: Text(initialOf(m['from']))),
              title: Text(
                subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(from, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (_str(m['preview']).isNotEmpty)
                    Text(
                      _str(m['preview']),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  // Chip OTP di bawah subjek (bukan di kolom kanan) supaya
                  // subjek tidak terpotong di layar sempit.
                  if (otp != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => copyText(
                          context,
                          otp.toString(),
                          'OTP $otp disalin',
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: s.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'OTP $otp',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: s.onPrimaryContainer,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                Icons.copy,
                                size: 14,
                                color: s.onPrimaryContainer,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              trailing: Text(
                msgTimeShort(m),
                style: const TextStyle(fontSize: 12),
              ),
              onTap: () => _open(ref, m),
            ),
          );
        },
      );
    }
    return RefreshIndicator(onRefresh: _reload, child: content);
  }

  @override
  Widget build(BuildContext context) {
    final ref = appState.activeRef;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Inbox'),
            if (appState.activeAddress != null)
              Text(
                appState.activeAddress!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _onlyOtp ? 'Tampilkan semua email' : 'Hanya yang ada OTP',
            onPressed: ref == null
                ? null
                : () {
                    setState(() => _onlyOtp = !_onlyOtp);
                    _reload();
                  },
            icon: Icon(_onlyOtp ? Icons.filter_alt : Icons.filter_alt_outlined),
          ),
          IconButton(
            tooltip: _auto ? 'Matikan auto-refresh' : 'Auto-refresh',
            onPressed: ref == null ? null : () => _setAuto(!_auto),
            icon: Icon(_auto ? Icons.sync : Icons.sync_disabled),
          ),
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: ref == null ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Hapus semua email',
            onPressed: ref == null || _msgs.isEmpty ? null : _deleteAll,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
        bottom: _recent.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(52),
                child: SizedBox(
                  height: 52,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: _recent.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (ctx, i) {
                      final it = _recent[i] is Map ? _recent[i] as Map : {};
                      final addr = (it['address'] ?? '').toString();
                      final r = (it['ref'] ?? addr).toString();
                      return ChoiceChip(
                        label: Text(addr, style: const TextStyle(fontSize: 12)),
                        selected: addr == appState.activeAddress,
                        onSelected: addr.isEmpty
                            ? null
                            : (_) => appState.setActive(r, addr),
                      );
                    },
                  ),
                ),
              ),
      ),
      body: ref == null
          ? EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Belum ada mailbox aktif',
              subtitle: _recent.isEmpty
                  ? 'Buat alamat dulu di tab Beranda.'
                  : 'Pilih alamat di atas atau buat baru di tab Beranda.',
            )
          : Column(
              children: [
                if (_loading && _msgs.isNotEmpty)
                  const LinearProgressIndicator(minHeight: 2),
                if (_err != null && _msgs.isNotEmpty)
                  MaterialBanner(
                    content: Text('Gagal menyegarkan: $_err'),
                    actions: [
                      TextButton(
                        onPressed: _reload,
                        child: const Text('Coba lagi'),
                      ),
                    ],
                  ),
                Expanded(child: _body(ref)),
              ],
            ),
    );
  }
}

// ======================= DETAIL PESAN =======================
class MessageDetailScreen extends StatefulWidget {
  final String ref;
  final Map message;
  const MessageDetailScreen({
    super.key,
    required this.ref,
    required this.message,
  });
  @override
  State<MessageDetailScreen> createState() => _MessageDetailScreenState();
}

class _MessageDetailScreenState extends State<MessageDetailScreen> {
  dynamic _detail;
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.message['id']?.toString();
    if (id == null) {
      setState(() {
        _detail = widget.message;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final d = await api.messageDetail(widget.ref, id);
      if (mounted) {
        setState(() {
          // Gabung: field dari daftar (otp, links, umur) tetap ada walau
          // detail tidak mengirimnya ulang.
          _detail = d is Map ? {...widget.message, ...d} : d;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _err = errorText(e);
        });
      }
    }
  }

  Future<void> _delete() async {
    final id = widget.message['id']?.toString();
    if (id == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Hapus email ini?',
      body: 'Email akan dihapus permanen.',
    );
    if (!ok) return;
    try {
      await api.deleteMessage(widget.ref, id);
      if (mounted) {
        showOk(context, 'Email dihapus');
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Teks body; jatuh ke preview bila kosong (seperti `m.text || m.preview`).
  String _bodyText(Map m) =>
      _str(m['text']).isNotEmpty ? m['text'].toString() : _str(m['preview']);

  List<String> _otps(Map m) {
    final out = <String>[];
    final all = m['otp_all'];
    if (all is List) out.addAll(all.map((e) => e.toString()));
    final one = m['otp']?.toString();
    if (one != null && one.isNotEmpty && !out.contains(one)) out.insert(0, one);
    if (out.isEmpty) {
      // Server tidak mengenali kodenya → coba deteksi dari subjek/isi.
      final c = detectOtp(
        subject: m['subject']?.toString(),
        text: (m['text'] ?? m['preview'])?.toString(),
      );
      if (c != null) out.add(c);
    }
    return out;
  }

  Widget _summary(Map m) {
    final s = Theme.of(context).colorScheme;
    final links = (m['links'] as List?) ?? const [];
    final otps = _otps(m);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SelectableText(
          _str(m['subject'], '(Tanpa subjek)'),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.person_outline, size: 18, color: s.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(child: SelectableText(_str(m['from'], '-'))),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(Icons.schedule, size: 18, color: s.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(child: Text(msgTimeFull(m))),
          ],
        ),
        if (_err != null) ...[
          const SizedBox(height: 12),
          Card(
            color: s.errorContainer,
            child: ListTile(
              title: Text(
                'Isi lengkap gagal dimuat',
                style: TextStyle(color: s.onErrorContainer),
              ),
              subtitle: Text(
                _err!,
                style: TextStyle(color: s.onErrorContainer),
              ),
              trailing: IconButton(
                tooltip: 'Coba lagi',
                icon: Icon(Icons.refresh, color: s.onErrorContainer),
                onPressed: _load,
              ),
            ),
          ),
        ],
        for (final code in otps) ...[
          const SizedBox(height: 12),
          Card(
            color: s.primaryContainer,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => copyText(context, code, 'OTP disalin'),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.pin, color: s.onPrimaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        code,
                        style: TextStyle(
                          fontSize: 24,
                          letterSpacing: 2,
                          color: s.onPrimaryContainer,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Icon(Icons.copy, color: s.onPrimaryContainer),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (otps.isNotEmpty && _str(m['otp']).isEmpty && m['otp_all'] == null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Kode dideteksi aplikasi dari subjek/isi email (server tidak '
              'mengenalinya).',
              style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
            ),
          ),
        if (links.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'Link di email',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          for (final l in links)
            Builder(
              builder: (ctx) {
                final url = (l is Map ? l['url'] : l).toString();
                final text = l is Map ? _str(l['text'], url) : url;
                final kind = l is Map ? _str(l['kind']) : '';
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    kind == 'verify' || kind == 'reset'
                        ? Icons.verified_outlined
                        : Icons.link,
                    size: 20,
                  ),
                  title: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    kind.isEmpty ? url : '$kind • $url',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.copy, size: 18),
                  onTap: () => copyText(context, url, 'Link disalin'),
                );
              },
            ),
        ],
        const SizedBox(height: 16),
        const Text('Cuplikan', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          _str(_bodyText(m), '(tanpa isi)'),
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _textTab(Map m) {
    final text = _str(_bodyText(m), '(Body teks kosong)');
    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
          child: SelectableText(text),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.small(
            heroTag: null,
            tooltip: 'Salin teks',
            onPressed: () => copyText(context, text, 'Teks email disalin'),
            child: const Icon(Icons.copy),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = (_detail as Map?) ?? widget.message;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Detail email'),
          actions: [
            IconButton(
              tooltip: 'Hapus email',
              onPressed: widget.message['id'] == null ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Ringkasan'),
              Tab(text: 'Teks'),
              Tab(text: 'HTML'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                // WebView butuh gestur geser sendiri; jangan direbut TabBarView.
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _summary(m),
                  _textTab(m),
                  _HtmlTab(ref: widget.ref, message: m),
                ],
              ),
      ),
    );
  }
}

class _HtmlTab extends StatefulWidget {
  final String ref;
  final Map message;
  const _HtmlTab({required this.ref, required this.message});
  @override
  State<_HtmlTab> createState() => _HtmlTabState();
}

class _HtmlTabState extends State<_HtmlTab> with AutomaticKeepAliveClientMixin {
  WebViewController? _ctrl;
  bool _raw = false;
  bool _ready = false;

  @override
  bool get wantKeepAlive => true;

  String? get _html {
    final h = widget.message['html']?.toString();
    return h == null || h.trim().isEmpty ? null : h;
  }

  @override
  void initState() {
    super.initState();
    if (_html != null) _ctrl = _build(html: _html);
  }

  /// Bungkus HTML email dengan viewport supaya tidak tampil mungil di HP.
  String _wrap(String html) {
    if (RegExp(r'<meta[^>]+viewport', caseSensitive: false).hasMatch(html)) {
      return html;
    }
    const head =
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<style>body{word-wrap:break-word}img{max-width:100%;height:auto}</style>';
    final headTag = RegExp(r'<head(\s[^>]*)?>', caseSensitive: false);
    if (headTag.hasMatch(html)) {
      return html.replaceFirstMapped(headTag, (mm) => '${mm[0]}$head');
    }
    return '<!doctype html><html><head>$head</head><body>$html</body></html>';
  }

  WebViewController _build({String? html}) {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _ready = true,
          onNavigationRequest: (req) {
            // Klik link di email TIDAK dibuka di dalam aplikasi (hindari
            // pelacak & phishing) — disalin saja. Yang boleh hanya muatan
            // awal: dokumen HTML lokal, atau URL sumber mentah + redirect-nya
            // sebelum halaman pertama selesai.
            final u = req.url;
            if (u.startsWith('about:') || u.startsWith('data:')) {
              return NavigationDecision.navigate;
            }
            if (html == null && !_ready) return NavigationDecision.navigate;
            if (req.isMainFrame && mounted) {
              copyText(context, u, 'Link disalin: $u');
            }
            return NavigationDecision.prevent;
          },
        ),
      );
    final id = widget.message['id']?.toString();
    if (html != null) {
      c.loadHtmlString(_wrap(html));
    } else if (id != null) {
      c.loadRequest(
        Uri.parse(api.rawMessageUrl(widget.ref, id)),
        headers: api.authHeaders,
      );
    }
    return c;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_ctrl != null) return WebViewWidget(controller: _ctrl!);
    final hasId = widget.message['id'] != null;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const EmptyState(
            icon: Icons.code_off,
            title: 'Email ini tidak punya versi HTML',
            subtitle: 'Isi lengkapnya ada di tab Teks.',
          ),
          if (hasId && !_raw)
            OutlinedButton.icon(
              onPressed: () => setState(() {
                _raw = true;
                _ctrl = _build();
              }),
              icon: const Icon(Icons.description_outlined),
              label: const Text('Lihat sumber mentah'),
            ),
        ],
      ),
    );
  }
}
