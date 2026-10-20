// Layar Favorit + Menu dan sub-layar: Varian, Gmail, Alias, Domain,
// Riwayat, Pantauan & Notifikasi, Debug, Admin, Tentang.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'main.dart';

// ============================ FAVORIT ============================
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});
  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<dynamic> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.favorites();
      final list = r is List ? r : (r['favorites'] as List? ?? r['items'] as List? ?? []);
      if (mounted) {
        setState(() {
          _items = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  String _addr(dynamic f) =>
      f is Map ? (f['address'] ?? f['ref'] ?? '').toString() : f.toString();

  Future<void> _export() async {
    try {
      final r = await api.exportFavorites();
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ekspor favorit'),
          content: SingleChildScrollView(child: JsonView(r)),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(
                    text: const JsonEncoder.withIndent('  ').convert(r)));
                Navigator.pop(ctx);
                showOk(context, 'JSON ekspor disalin');
              },
              child: const Text('Salin JSON'),
            ),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Tutup')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _import() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Impor favorit'),
        content: TextField(
          controller: ctl,
          maxLines: 8,
          decoration: const InputDecoration(
              labelText: 'Tempel JSON {"items":[...]} atau array'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Impor')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final parsed = jsonDecode(ctl.text);
      final items = parsed is List
          ? parsed
          : (parsed['items'] as List? ?? []);
      final r = await api.importFavorites(items.cast<dynamic>());
      if (mounted) {
        showOk(context, 'Impor selesai: $r');
        _load();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Favorit'),
        actions: [
          IconButton(
              tooltip: 'Ekspor', onPressed: _export, icon: const Icon(Icons.upload_outlined)),
          IconButton(
              tooltip: 'Impor', onPressed: _import, icon: const Icon(Icons.download_outlined)),
          IconButton(
            tooltip: 'Bersihkan semua',
            onPressed: () async {
              final ok = await confirmDialog(context,
                  title: 'Bersihkan semua favorit?',
                  body: 'Seluruh favorit permanen akan dihapus.');
              if (!ok) return;
              await api.clearFavorites();
              _load();
            },
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const EmptyState(
                  icon: Icons.star_outline,
                  title: 'Belum ada favorit',
                  subtitle:
                      'Simpan alamat penting dari tab Beranda (tombol Favorit).')
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final f = _items[i];
                      final addr = _addr(f);
                      final label = f is Map ? f['label']?.toString() : null;
                      final pinned = f is Map && f['pinned'] == true;
                      return ListTile(
                        leading: Icon(pinned ? Icons.push_pin : Icons.star,
                            color: pinned
                                ? Theme.of(context).colorScheme.primary
                                : null),
                        title: Text(label?.isNotEmpty == true ? label! : addr,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: label?.isNotEmpty == true ? Text(addr) : null,
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            try {
                              if (v == 'use') {
                                await appState.setActive(addr, addr);
                                showOk(context, 'Aktif: $addr');
                              } else if (v == 'pin') {
                                await api.patchFavorite(addr, pinned: !pinned);
                                _load();
                              } else if (v == 'note') {
                                final c = TextEditingController(
                                    text: f is Map
                                        ? (f['note'] ?? '').toString()
                                        : '');
                                final save = await showDialog<bool>(
                                  context: context,
                                  builder: (dctx) => AlertDialog(
                                    title: const Text('Catatan favorit'),
                                    content: TextField(controller: c),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(dctx, false),
                                          child: const Text('Batal')),
                                      FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(dctx, true),
                                          child: const Text('Simpan')),
                                    ],
                                  ),
                                );
                                if (save == true) {
                                  await api.patchFavorite(addr, note: c.text);
                                  _load();
                                }
                              } else if (v == 'del') {
                                await api.removeFavorite(addr);
                                _load();
                              }
                            } catch (e) {
                              if (mounted) showError(context, e);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                                value: 'use', child: Text('Jadikan aktif')),
                            PopupMenuItem(
                                value: 'pin', child: Text('Pin / lepas pin')),
                            PopupMenuItem(
                                value: 'note', child: Text('Ubah catatan')),
                            PopupMenuItem(
                                value: 'del', child: Text('Hapus favorit')),
                          ],
                        ),
                        onTap: () async {
                          await appState.setActive(addr, addr);
                          showOk(context, 'Aktif: $addr');
                        },
                      );
                    },
                  ),
                ),
    );
  }
}

// ============================ MENU ============================
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String, String, Widget)>[
      (Icons.call_split, 'Varian alamat', 'Titik & plus dari alamat aktif', const VariantsScreen()),
      (Icons.mail_outline, 'Varian Gmail saya', 'Dari alamat @gmail.com mana pun', const GmailVariantsScreen()),
      (Icons.list_alt, 'Alias (alias.md)', 'Lihat, edit, validasi daftar alias', const AliasScreen()),
      (Icons.language, 'Domain', 'Cari, acak, grup, dan uji domain', const DomainsScreen()),
      (Icons.history, 'Riwayat', 'Alamat baru dipakai + feed aktivitas', const HistoryScreen()),
      (Icons.visibility_outlined, 'Pantauan & notifikasi', 'Watch OTP/link + tes notifikasi', const WatchScreen()),
      (Icons.bug_report_outlined, 'Debug', 'Diagnosis upstream per alamat', const DebugScreen()),
      (Icons.admin_panel_settings_outlined, 'Admin', 'Log, config, domain & pola OTP kustom', const AdminScreen()),
      (Icons.info_outline, 'Tentang & status', 'Info server /me + health', const AboutScreen()),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Menu')),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final (icon, title, sub, page) = items[i];
          return ListTile(
            leading: Icon(icon),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(sub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => page)),
          );
        },
      ),
    );
  }
}

// ============================ VARIAN ============================
class VariantsScreen extends StatefulWidget {
  const VariantsScreen({super.key});
  @override
  State<VariantsScreen> createState() => _VariantsScreenState();
}

class _VariantsScreenState extends State<VariantsScreen> {
  String _mode = 'both';
  final _tag = TextEditingController();
  dynamic _result;

  Future<void> _load() async {
    final ref = appState.activeRef;
    if (ref == null) {
      showError(context, 'Belum ada mailbox aktif');
      return;
    }
    try {
      final r = await api.variants(ref,
          mode: _mode, count: 30, tag: _tag.text.trim());
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _createFromVariant() async {
    final ref = appState.activeRef;
    if (ref == null) return;
    try {
      final r = await api.variantCreate(ref,
          mode: _mode, tag: _tag.text.trim().isEmpty ? null : _tag.text.trim());
      final addr = (r['address'] ?? '').toString();
      if (addr.isNotEmpty) {
        await appState.setActive((r['ref'] ?? addr).toString(), addr);
      }
      if (mounted) showOk(context, 'Mailbox varian dibuat: $addr');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final variants = _result is Map
        ? (_result['variants'] as List? ?? _result['items'] as List? ?? [])
        : (_result as List? ?? []);
    return Scaffold(
      appBar: AppBar(title: const Text('Varian alamat')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Dari: ${appState.activeAddress ?? '-'}'),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'dot', label: Text('Titik')),
              ButtonSegment(value: 'plus', label: Text('Plus')),
              ButtonSegment(value: 'both', label: Text('Keduanya')),
            ],
            selected: {_mode},
            onSelectionChanged: (v) => setState(() => _mode = v.first),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tag,
            decoration:
                const InputDecoration(labelText: 'Tag plus (opsional)'),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: FilledButton(
                    onPressed: _load, child: const Text('Tampilkan varian'))),
            const SizedBox(width: 10),
            Expanded(
                child: FilledButton.tonal(
                    onPressed: _createFromVariant,
                    child: const Text('Buat mailbox dari varian'))),
          ]),
          const SizedBox(height: 14),
          for (final v in variants)
            ListTile(
              dense: true,
              leading: const Icon(Icons.alternate_email, size: 20),
              title: Text(v.toString()),
              trailing: IconButton(
                icon: const Icon(Icons.copy, size: 20),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: v.toString()));
                  showOk(context, 'Disalin');
                },
              ),
            ),
          if (_result != null && variants.isEmpty) JsonView(_result),
        ],
      ),
    );
  }
}

// ============================ GMAIL ============================
class GmailVariantsScreen extends StatefulWidget {
  const GmailVariantsScreen({super.key});
  @override
  State<GmailVariantsScreen> createState() => _GmailVariantsScreenState();
}

class _GmailVariantsScreenState extends State<GmailVariantsScreen> {
  final _email = TextEditingController();
  String _mode = 'both';
  dynamic _result;

  Future<void> _load() async {
    if (!_email.text.contains('@')) {
      showError(context, 'Isi alamat Gmail dulu');
      return;
    }
    try {
      final r = await api.gmailVariants(
          email: _email.text.trim(), mode: _mode, limit: 50);
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final variants = _result is Map
        ? (_result['variants'] as List? ?? _result['items'] as List? ?? [])
        : (_result as List? ?? []);
    return Scaffold(
      appBar: AppBar(title: const Text('Varian Gmail saya')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
                labelText: 'Alamat @gmail.com',
                prefixIcon: Icon(Icons.mail_outline)),
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'dot', label: Text('Titik')),
              ButtonSegment(value: 'plus', label: Text('Plus')),
              ButtonSegment(value: 'both', label: Text('Keduanya')),
            ],
            selected: {_mode},
            onSelectionChanged: (v) => setState(() => _mode = v.first),
          ),
          const SizedBox(height: 12),
          FilledButton(
              onPressed: _load, child: const Text('Hasilkan varian')),
          const SizedBox(height: 14),
          for (final v in variants)
            ListTile(
              dense: true,
              title: Text(v.toString()),
              trailing: IconButton(
                icon: const Icon(Icons.copy, size: 20),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: v.toString()));
                  showOk(context, 'Disalin');
                },
              ),
            ),
          if (_result != null && variants.isEmpty) JsonView(_result),
        ],
      ),
    );
  }
}

// ============================ ALIAS ============================
class AliasScreen extends StatefulWidget {
  const AliasScreen({super.key});
  @override
  State<AliasScreen> createState() => _AliasScreenState();
}

class _AliasScreenState extends State<AliasScreen> {
  final _ctl = TextEditingController();
  dynamic _parsed;
  bool _loading = true;
  String? _summary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.aliasGet();
      if (mounted) {
        setState(() {
          _parsed = r;
          if (r is Map && r['raw'] is String) _ctl.text = r['raw'];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  Future<void> _validate() async {
    try {
      final r = await api.aliasValidate(_ctl.text);
      if (mounted) {
        setState(() => _summary = const JsonEncoder.withIndent('  ')
            .convert(r is Map ? (r['summary'] ?? r) : r));
        showOk(context, 'Validasi selesai');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _save() async {
    try {
      final r = await api.aliasPutRaw(_ctl.text);
      if (mounted) {
        showOk(context, 'alias.md disimpan');
        setState(() {
          _parsed = r.data;
          _summary = r.meta.isEmpty ? null : r.meta.toString();
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _wipe() async {
    final ok = await confirmDialog(context,
        title: 'Hapus alias.md?', body: 'Seluruh daftar alias akan dihapus.');
    if (!ok) return;
    try {
      await api.aliasDelete();
      _ctl.clear();
      if (mounted) showOk(context, 'alias.md dihapus');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final aliases = _parsed is Map
        ? (_parsed['aliases'] as List? ?? [])
        : [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alias (alias.md)'),
        actions: [
          IconButton(
              tooltip: 'Hapus alias.md',
              onPressed: _wipe,
              icon: const Icon(Icons.delete_outline)),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (aliases.isNotEmpty) ...[
                  const Text('Alias terdaftar',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  for (final a in aliases)
                    ListTile(
                      dense: true,
                      title: Text(a is Map
                          ? (a['name'] ?? '').toString()
                          : a.toString()),
                      subtitle: Text(a is Map
                          ? (a['address'] ?? a['domain'] ?? '').toString()
                          : ''),
                      trailing: IconButton(
                        icon: const Icon(Icons.play_circle_outline),
                        onPressed: () async {
                          final addr = a is Map
                              ? (a['address'] ?? '').toString()
                              : '';
                          if (addr.isNotEmpty) {
                            await appState.setActive(
                                (a['name'] ?? addr).toString(), addr);
                            if (mounted) {
                              showOk(context, 'Aktif: $addr');
                            }
                          }
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
                const Text('Isi alias.md',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                TextField(
                  controller: _ctl,
                  maxLines: 14,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(
                      alignLabelWithHint: true,
                      labelText: 'Markdown alias'),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                      child: OutlinedButton(
                          onPressed: _validate,
                          child: const Text('Validasi'))),
                  const SizedBox(width: 10),
                  Expanded(
                      child: FilledButton(
                          onPressed: _save, child: const Text('Simpan'))),
                ]),
                if (_summary != null) ...[
                  const SizedBox(height: 12),
                  JsonView(_summary),
                ],
              ],
            ),
    );
  }
}

// ============================ DOMAIN ============================
class DomainsScreen extends StatefulWidget {
  const DomainsScreen({super.key});
  @override
  State<DomainsScreen> createState() => _DomainsScreenState();
}

class _DomainsScreenState extends State<DomainsScreen> {
  final _q = TextEditingController();
  final _check = TextEditingController();
  dynamic _result;
  dynamic _groups;
  dynamic _random;
  dynamic _checkResult;

  Future<void> _search() async {
    try {
      final r = await api.domains(q: _q.text.trim());
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Domain')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _q,
                decoration: const InputDecoration(
                    labelText: 'Cari domain', prefixIcon: Icon(Icons.search)),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(onPressed: _search, child: const Text('Cari')),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            OutlinedButton(
              onPressed: () async {
                final r = await api.domainGroups();
                if (mounted) setState(() => _groups = r);
              },
              child: const Text('Grup domain'),
            ),
            OutlinedButton(
              onPressed: () async {
                final r = await api.domainRandom();
                if (mounted) setState(() => _random = r);
              },
              child: const Text('Domain acak'),
            ),
          ]),
          if (_random != null) ...[
            const SizedBox(height: 10),
            JsonView(_random),
          ],
          if (_groups != null) ...[
            const SizedBox(height: 10),
            const Text('Grup', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            JsonView(_groups),
          ],
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _check,
                decoration: const InputDecoration(
                    labelText: 'Uji domain (cth: mail.com)'),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: () async {
                try {
                  final r = await api.domainCheck(_check.text.trim());
                  if (mounted) setState(() => _checkResult = r);
                } catch (e) {
                  if (mounted) showError(context, e);
                }
              },
              child: const Text('Uji'),
            ),
          ]),
          if (_checkResult != null) ...[
            const SizedBox(height: 10),
            JsonView(_checkResult),
          ],
          if (_result != null) ...[
            const SizedBox(height: 16),
            const Text('Hasil pencarian',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            JsonView(_result),
          ],
        ],
      ),
    );
  }
}

// ============================ RIWAYAT ============================
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  dynamic _recent;
  dynamic _events;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.history(limit: 50);
      if (mounted) setState(() => _recent = r);
    } catch (_) {}
    try {
      final e = await api.historyEvents(limit: 50);
      if (mounted) setState(() => _events = e);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final recent = _recent is Map
        ? (_recent['items'] as List? ?? _recent['recent'] as List? ?? [])
        : (_recent as List? ?? []);
    final events = _events is Map
        ? (_events['events'] as List? ?? _events['items'] as List? ?? [])
        : (_events as List? ?? []);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Riwayat'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          IconButton(
            tooltip: 'Bersihkan semua riwayat',
            onPressed: () async {
              final ok = await confirmDialog(context,
                  title: 'Bersihkan semua riwayat?',
                  body: 'Riwayat alamat + feed aktivitas dihapus.');
              if (!ok) return;
              await api.clearHistory(scope: 'all');
              _load();
            },
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
        bottom: const TabBar(tabs: [
          Tab(text: 'Baru dipakai'),
          Tab(text: 'Feed aktivitas'),
        ]),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          recent.isEmpty
              ? const EmptyState(
                  icon: Icons.history, title: 'Belum ada riwayat')
              : ListView.separated(
                  itemCount: recent.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final it = recent[i] as Map;
                    final addr = (it['address'] ?? '').toString();
                    return ListTile(
                      title: Text(addr,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          'Dipakai ${it['uses'] ?? '-'}x • OTP terakhir: ${it['last_otp'] ?? '-'}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () async {
                          await api.deleteRecent(addr);
                          _load();
                        },
                      ),
                      onTap: () async {
                        await appState.setActive(
                            (it['alias'] ?? addr).toString(), addr);
                        showOk(context, 'Aktif: $addr');
                      },
                    );
                  },
                ),
          events.isEmpty
              ? const EmptyState(
                  icon: Icons.feed_outlined, title: 'Belum ada aktivitas')
              : ListView.builder(
                  itemCount: events.length,
                  itemBuilder: (ctx, i) => Padding(
                    padding: const EdgeInsets.all(12),
                    child: JsonView(events[i]),
                  ),
                ),
        ],
      ),
    );
  }
}

// ====================== PANTAUAN & NOTIFIKASI ======================
class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key});
  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  dynamic _list;
  final _ref = TextEditingController();
  String _mode = 'otp';

  @override
  void initState() {
    super.initState();
    _ref.text = appState.activeRef ?? '';
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.watchList();
      if (mounted) setState(() => _list = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _create() async {
    if (_ref.text.trim().isEmpty) return;
    try {
      await api.watchCreate(ref: _ref.text.trim(), mode: _mode);
      if (mounted) showOk(context, 'Pantauan dibuat');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _list is Map
        ? (_list['watches'] as List? ?? _list['items'] as List? ?? [])
        : (_list as List? ?? []);
    return Scaffold(
      appBar: AppBar(title: const Text('Pantauan & notifikasi')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _ref,
            decoration: const InputDecoration(
                labelText: 'Ref yang dipantau (alias / alamat)'),
          ),
          const SizedBox(height: 10),
          Row(children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'otp', label: Text('OTP')),
                ButtonSegment(value: 'link', label: Text('Link')),
              ],
              selected: {_mode},
              onSelectionChanged: (v) => setState(() => _mode = v.first),
            ),
            const SizedBox(width: 10),
            Expanded(
                child: FilledButton(
                    onPressed: _create, child: const Text('Buat pantauan'))),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final r = await api.watchRun();
                  if (mounted) {
                    showOk(context, 'Pantauan dijalankan');
                    setState(() => _list = _list);
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Hasil run pantauan'),
                        content: SingleChildScrollView(child: JsonView(r)),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Tutup')),
                        ],
                      ),
                    );
                  }
                  _load();
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('Jalankan sekarang'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  try {
                    final r = await api.notifyTest();
                    if (mounted) showOk(context, 'Tes notifikasi: $r');
                  } catch (e) {
                    if (mounted) showError(context, e);
                  }
                },
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Text('Tes notifikasi'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          const Text('Pantauan aktif',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (_list == null)
            const Center(child: CircularProgressIndicator())
          else if (items.isEmpty)
            const Text('Belum ada pantauan.')
          else
            for (final w in items)
              Card(
                child: ListTile(
                  title: Text(w is Map
                      ? (w['ref'] ?? w['address'] ?? '').toString()
                      : w.toString()),
                  subtitle: Text(w is Map
                      ? 'mode: ${w['mode']} • id: ${w['id']}'
                      : ''),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (w is Map && w['id'] != null) {
                        await api.watchDelete(w['id'].toString());
                        _load();
                      }
                    },
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

// ============================ DEBUG ============================
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});
  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  final _ref = TextEditingController();
  dynamic _result;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ref.text = appState.activeRef ?? '';
  }

  Future<void> _run() async {
    if (_ref.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await api.debugRef(_ref.text.trim(), inbox: true);
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Debug upstream')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _ref,
            decoration: const InputDecoration(labelText: 'Ref / alamat'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _run,
            child: Text(_busy ? 'Memeriksa…' : 'Jalankan diagnosis'),
          ),
          if (_result != null) ...[
            const SizedBox(height: 14),
            JsonView(_result),
          ],
        ],
      ),
    );
  }
}

// ============================ ADMIN ============================
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  dynamic _view;
  String _title = '';

  Future<void> _show(String title, Future<dynamic> Function() fn) async {
    try {
      final r = await fn();
      if (mounted) {
        setState(() {
          _title = title;
          _view = r;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _editJson(
    String title,
    Future<dynamic> Function() load,
    Future<dynamic> Function(dynamic) save,
  ) async {
    dynamic cur;
    try {
      cur = await load();
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    final ctl = TextEditingController(
        text: const JsonEncoder.withIndent('  ').convert(cur));
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctl,
            maxLines: 16,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Simpan')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final parsed = jsonDecode(ctl.text);
      final r = await save(parsed);
      if (mounted) {
        showOk(context, 'Tersimpan');
        setState(() {
          _title = title;
          _view = r;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: () => _show('Log server', () => api.adminLogs()),
                child: const Text('Lihat log')),
            OutlinedButton(
                onPressed: () async {
                  final ok = await confirmDialog(context,
                      title: 'Bersihkan log?',
                      body: 'Log ring-buffer server dikosongkan.',
                      confirmLabel: 'Bersihkan');
                  if (!ok) return;
                  await api.adminClearLogs();
                  if (mounted) showOk(context, 'Log dibersihkan');
                },
                child: const Text('Bersih log')),
            OutlinedButton(
                onPressed: () => _show('Config', () => api.adminConfig()),
                child: const Text('Config')),
            OutlinedButton(
                onPressed: () async {
                  final r = await api.adminReload();
                  if (mounted) {
                    setState(() {
                      _title = 'Reload';
                      _view = r;
                    });
                  }
                },
                child: const Text('Reload')),
          ]),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.language),
            title: const Text('Domain kustom (grup)'),
            subtitle: const Text('GET / PUT / DELETE /admin/domains'),
            trailing: Wrap(spacing: 4, children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _editJson(
                  'Domain kustom {"groups": {...}}',
                  () => api.adminDomains(),
                  (v) async {
                    final groups = v is Map && v['groups'] is Map
                        ? (v['groups'] as Map).cast<String, dynamic>()
                        : (v as Map).cast<String, dynamic>();
                    return api.adminPutDomains(groups);
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await confirmDialog(context,
                      title: 'Reset domain kustom?',
                      body: 'Domain kustom dikembalikan ke bawaan.');
                  if (!ok) return;
                  await api.adminDeleteDomains();
                  if (mounted) showOk(context, 'Domain kustom direset');
                },
              ),
            ]),
          ),
          ListTile(
            leading: const Icon(Icons.pin_outlined),
            title: const Text('Pola OTP kustom'),
            subtitle: const Text('GET / PUT / DELETE /admin/otp-patterns'),
            trailing: Wrap(spacing: 4, children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _editJson(
                  'Pola OTP (array pola)',
                  () => api.adminOtpPatterns(),
                  (v) => api.adminPutOtpPatterns(v),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await confirmDialog(context,
                      title: 'Reset pola OTP kustom?',
                      body: 'Pola OTP dikembalikan ke bawaan.');
                  if (!ok) return;
                  await api.adminDeleteOtpPatterns();
                  if (mounted) showOk(context, 'Pola OTP direset');
                },
              ),
            ]),
          ),
          if (_view != null) ...[
            const SizedBox(height: 14),
            Text(_title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            JsonView(_view),
          ],
        ],
      ),
    );
  }
}

// ============================ TENTANG ============================
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});
  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  dynamic _me;
  dynamic _health;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final h = await api.health();
      if (mounted) setState(() => _health = h);
    } catch (_) {}
    try {
      final m = await api.me();
      if (mounted) setState(() => _me = m);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tentang & status'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Server',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          SelectableText(kApiBase),
          const SizedBox(height: 12),
          const Text('Health', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (_health != null) JsonView(_health),
          const SizedBox(height: 12),
          const Text('Info server (/v1/me)',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (_me != null) JsonView(_me),
        ],
      ),
    );
  }
}
