// Layar Beranda (mailbox aktif + buat alamat), Inbox, dan detail pesan.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'api.dart';
import 'main.dart';

String fmtTime(dynamic iso) {
  if (iso == null) return '-';
  final d = DateTime.tryParse(iso.toString());
  if (d == null) return iso.toString();
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)} ${two(l.hour)}:${two(l.minute)}';
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
  dynamic _lastCreated;
  dynamic _info;

  @override
  void initState() {
    super.initState();
    appState.addListener(_onState);
    _loadInfo();
  }

  @override
  void dispose() {
    appState.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (mounted) {
      setState(() {});
      _loadInfo();
    }
  }

  Future<void> _loadInfo() async {
    final ref = appState.activeRef;
    if (ref == null) return;
    try {
      final info = await api.mailboxInfo(ref);
      if (mounted) setState(() => _info = info);
    } catch (_) {}
  }

  Future<void> _create({String? quickGroup}) async {
    setState(() => _busy = true);
    try {
      dynamic r;
      if (quickGroup != null) {
        r = await api.quickCreate(quickGroup);
      } else {
        r = await api.createMailbox(
          alias: _alias.text.trim(),
          domain: _domain.text.trim(),
          group: _group.text.trim(),
          saveAs: _saveAs.text.trim(),
          check: true,
        );
      }
      final ref = (r['ref'] ?? r['address']).toString();
      final address = r['address'].toString();
      await appState.setActive(ref, address);
      if (mounted) {
        setState(() => _lastCreated = r);
        showOk(context, 'Alamat aktif: $address');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(String kind) async {
    final ref = appState.activeRef;
    if (ref == null) return;
    try {
      if (kind == 'read') {
        await api.markRead(ref);
        showOk(context, 'Semua ditandai dibaca');
      } else if (kind == 'cache') {
        await api.clearCache(ref);
        showOk(context, 'Cache mailbox dibersihkan');
      } else if (kind == 'fav') {
        await api.addFavorite(appState.activeAddress ?? ref);
        showOk(context, 'Ditambahkan ke favorit');
      } else if (kind == 'wipe') {
        final ok = await confirmDialog(context,
            title: 'Hapus inbox?',
            body:
                'Semua email + riwayat OTP untuk ${appState.activeAddress} akan dihapus permanen.');
        if (!ok) return;
        await api.deleteMailbox(ref);
        await appState.clearActive();
        showOk(context, 'Inbox dihapus');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final addr = appState.activeAddress;
    return Scaffold(
      appBar: AppBar(title: const Text('TempMail')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.alternate_email, color: s.primary),
                    const SizedBox(width: 8),
                    const Text('Mailbox aktif',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 10),
                  if (addr == null)
                    Text('Belum ada alamat aktif. Buat dulu di bawah ya.',
                        style: TextStyle(color: s.onSurfaceVariant))
                  else ...[
                    SelectableText(addr,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w600)),
                    if (_info is Map)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Pesan: ${_info['total'] ?? _info['count'] ?? '-'}'
                          '  •  ref: ${appState.activeRef}',
                          style: TextStyle(color: s.onSurfaceVariant),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: addr));
                          showOk(context, 'Alamat disalin');
                        },
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Salin'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _action('fav'),
                        icon: const Icon(Icons.star_outline, size: 18),
                        label: const Text('Favorit'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _action('read'),
                        icon: const Icon(Icons.done_all, size: 18),
                        label: const Text('Tandai dibaca'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _action('cache'),
                        icon: const Icon(Icons.cleaning_services_outlined,
                            size: 18),
                        label: const Text('Bersih cache'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _action('wipe'),
                        icon: Icon(Icons.delete_forever_outlined,
                            size: 18, color: s.error),
                        label: Text('Hapus inbox',
                            style: TextStyle(color: s.error)),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Buat cepat',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final g in ['premium', 'basic', 'standard', 'semua'])
              ActionChip(
                avatar: const Icon(Icons.bolt, size: 16),
                label: Text(g),
                onPressed: _busy ? null : () => _create(quickGroup: g),
              ),
          ]),
          const SizedBox(height: 16),
          const Text('Buat manual',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          TextField(
            controller: _alias,
            decoration: const InputDecoration(
                labelText: 'Alias (kosong = acak dari alias.md)',
                prefixIcon: Icon(Icons.person_outline)),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _domain,
            decoration: const InputDecoration(
                labelText: 'Domain (opsional)',
                prefixIcon: Icon(Icons.language)),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _group,
                decoration: const InputDecoration(
                    labelText: 'Grup domain (opsional)',
                    prefixIcon: Icon(Icons.folder_outlined)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _saveAs,
                decoration: const InputDecoration(
                    labelText: 'Simpan sbg alias',
                    prefixIcon: Icon(Icons.bookmark_outline)),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _busy ? null : () => _create(),
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add),
            label: const Text('Buat alamat'),
          ),
          if (_lastCreated != null) ...[
            const SizedBox(height: 16),
            const Text('Hasil pembuatan',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            JsonView(_lastCreated),
          ],
        ],
      ),
    );
  }
}

// ============================ INBOX ============================
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});
  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  List<dynamic> _msgs = [];
  bool _loading = false;
  bool _onlyOtp = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    appState.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    appState.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final ref = appState.activeRef;
    if (ref == null) {
      if (mounted) setState(() => _msgs = []);
      return;
    }
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final r = await api.messages(ref,
          hasOtp: _onlyOtp ? true : null, limit: 50, text: false);
      if (mounted) {
        setState(() {
          _msgs = (r['messages'] as List?) ?? [];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _err = e is ApiException ? e.message : e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _deleteAll() async {
    final ref = appState.activeRef;
    if (ref == null) return;
    final ok = await confirmDialog(context,
        title: 'Hapus semua email?',
        body: 'Semua email di ${appState.activeAddress} akan dihapus.');
    if (!ok) return;
    try {
      await api.deleteAllMessages(ref);
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = appState.activeRef;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inbox'),
        actions: [
          IconButton(
            tooltip: 'Hanya yang ada OTP',
            onPressed: () {
              setState(() => _onlyOtp = !_onlyOtp);
              _reload();
            },
            icon: Icon(_onlyOtp ? Icons.filter_alt : Icons.filter_alt_outlined),
          ),
          IconButton(
              tooltip: 'Muat ulang',
              onPressed: _reload,
              icon: const Icon(Icons.refresh)),
          IconButton(
              tooltip: 'Hapus semua email',
              onPressed: ref == null ? null : _deleteAll,
              icon: const Icon(Icons.delete_sweep_outlined)),
        ],
      ),
      body: ref == null
          ? const EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Belum ada mailbox aktif',
              subtitle: 'Buat alamat dulu di tab Beranda.')
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _err != null
                  ? EmptyState(
                      icon: Icons.error_outline,
                      title: 'Gagal memuat inbox',
                      subtitle: _err)
                  : _msgs.isEmpty
                      ? const EmptyState(
                          icon: Icons.mark_email_unread_outlined,
                          title: 'Inbox kosong',
                          subtitle:
                              'Belum ada email masuk. Tarik ke bawah untuk menyegarkan.')
                      : RefreshIndicator(
                          onRefresh: _reload,
                          child: ListView.separated(
                            itemCount: _msgs.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (ctx, i) {
                              final m = _msgs[i] as Map;
                              final otp = m['otp'];
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 6),
                                leading: CircleAvatar(
                                  child: Text(
                                    (m['from'] ?? '?')
                                        .toString()
                                        .characters
                                        .first
                                        .toUpperCase(),
                                  ),
                                ),
                                title: Text(m['subject'] ?? '(No Subject)',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                subtitle: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(m['from'] ?? '-',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                    Text(m['preview'] ?? '',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis),
                                  ],
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.end,
                                  children: [
                                    Text(fmtTime(m['received_at']),
                                        style: const TextStyle(fontSize: 12)),
                                    if (otp != null)
                                      Chip(
                                        label: Text('OTP $otp',
                                            style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700)),
                                        visualDensity: VisualDensity.compact,
                                        side: BorderSide.none,
                                        backgroundColor: Theme.of(context)
                                            .colorScheme
                                            .primaryContainer,
                                      ),
                                  ],
                                ),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => MessageDetailScreen(
                                        ref: ref, message: m),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
    );
  }
}

// ======================= DETAIL PESAN =======================
class MessageDetailScreen extends StatefulWidget {
  final String ref;
  final Map message;
  const MessageDetailScreen(
      {super.key, required this.ref, required this.message});
  @override
  State<MessageDetailScreen> createState() => _MessageDetailScreenState();
}

class _MessageDetailScreenState extends State<MessageDetailScreen> {
  dynamic _detail;
  bool _loading = true;

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
    try {
      final d = await api.messageDetail(widget.ref, id);
      if (mounted) {
        setState(() {
          _detail = d;
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

  Future<void> _delete() async {
    final id = widget.message['id']?.toString();
    if (id == null) return;
    final ok = await confirmDialog(context,
        title: 'Hapus email ini?', body: 'Email akan dihapus permanen.');
    if (!ok) return;
    try {
      await api.deleteMessage(widget.ref, id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = (_detail as Map?) ?? widget.message;
    final links = (m['links'] as List?) ?? [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detail email'),
        actions: [
          IconButton(
              tooltip: 'Hapus email',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(m['subject'] ?? '(No Subject)',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('Dari: ${m['from'] ?? '-'}'),
                Text('Waktu: ${m['time'] ?? fmtTime(m['received_at'])}'),
                if (m['otp'] != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(children: [
                        const Icon(Icons.pin),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text('OTP: ${m['otp']}',
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w800)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: m['otp'].toString()));
                            showOk(context, 'OTP disalin');
                          },
                        ),
                      ]),
                    ),
                  ),
                ],
                if (links.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text('Link di email',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  for (final l in links)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.link, size: 20),
                      title: Text(
                          (l is Map ? (l['text'] ?? l['url']) : l).toString(),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          (l is Map ? l['url'] : '').toString(),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        final u =
                            (l is Map ? l['url'] : l).toString();
                        Clipboard.setData(ClipboardData(text: u));
                        showOk(context, 'Link disalin');
                      },
                    ),
                ],
                const SizedBox(height: 14),
                DefaultTabController(
                  length: 2,
                  child: Column(
                    children: [
                      const TabBar(tabs: [
                        Tab(text: 'Teks'),
                        Tab(text: 'HTML'),
                      ]),
                      SizedBox(
                        height: 420,
                        child: TabBarView(children: [
                          SingleChildScrollView(
                            padding: const EdgeInsets.only(top: 12),
                            child: SelectableText(
                                (m['text'] ?? m['preview'] ?? '')
                                    .toString()),
                          ),
                          _HtmlTab(ref: widget.ref, message: m),
                        ]),
                      ),
                    ],
                  ),
                ),
              ],
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

class _HtmlTabState extends State<_HtmlTab> {
  WebViewController? _ctrl;

  @override
  void initState() {
    super.initState();
    final html = widget.message['html']?.toString();
    final id = widget.message['id']?.toString();
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(Colors.white);
    if (html != null && html.isNotEmpty) {
      c.loadHtmlString(html);
    } else if (id != null) {
      c.loadRequest(
        Uri.parse(api.rawMessageUrl(widget.ref, id)),
        headers: api.authHeaders,
      );
    } else {
      c.loadHtmlString('<p><i>Tidak ada HTML.</i></p>');
    }
    _ctrl = c;
  }

  @override
  Widget build(BuildContext context) {
    if (_ctrl == null) return const Center(child: Text('Tidak ada HTML'));
    return WebViewWidget(controller: _ctrl!);
  }
}
