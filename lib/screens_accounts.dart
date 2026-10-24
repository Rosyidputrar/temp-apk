// APK admin: kelola akun APK publik (buat, kuota, perangkat, masa aktif,
// reset password, hapus) dan alamat yang terdaftar beserta pemiliknya.
import 'package:flutter/material.dart';

import 'account.dart';
import 'api.dart';
import 'main.dart';
import 'screens_main.dart' show fmtTime;

String _str(dynamic v) => v == null ? '' : '$v';

/// Ringkasan status akun untuk badge.
(String, bool) _statusOf(Map u) {
  if (u['disabled'] == true) return ('Nonaktif', true);
  if (u['expired'] == true) return ('Kedaluwarsa', true);
  return (expiryText(u['expires_at']), false);
}

/// Kirim kredensial akun ke pengguna: tampilkan + salin.
Future<void> _showCredentials(
  BuildContext context,
  String username,
  String password, {
  String title = 'Akun dibuat',
}) => showDialog<void>(
  context: context,
  builder: (ctx) {
    final s = Theme.of(ctx).colorScheme;
    final text = 'Username: $username\nPassword: $password';
    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: s.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Password akun hanya tampil sekarang (server menyimpan hash-nya). '
            'Bila lupa, reset dari detail akun.',
            style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => copyText(ctx, text, 'Username & password disalin'),
          child: const Text('Salin'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Tutup'),
        ),
      ],
    );
  },
);

// ============================ DAFTAR AKUN ============================
class AccountsAdminScreen extends StatefulWidget {
  const AccountsAdminScreen({super.key});
  @override
  State<AccountsAdminScreen> createState() => _AccountsAdminScreenState();
}

class _AccountsAdminScreenState extends State<AccountsAdminScreen> {
  final _q = TextEditingController();
  List _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await api.adminUsers(q: _q.text.trim());
      if (mounted) setState(() => _items = listOf(r));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final r = await showDialog<Map>(
      context: context,
      builder: (_) => const _UserFormDialog(),
    );
    if (r == null || !mounted) return;
    final u = r['user'] is Map ? r['user'] as Map : const {};
    await _showCredentials(context, _str(u['username']), _str(r['password']));
    _load();
  }

  Future<void> _claimExisting() async {
    final ok = await confirmDialog(
      context,
      title: 'Daftarkan alamat lama?',
      body:
          'Semua alamat di riwayat, favorit, dan alias.md admin dicatat milik admin, '
          'supaya tidak bisa diklaim akun publik. Aman diulang.',
      confirmLabel: 'Daftarkan',
    );
    if (!ok) return;
    try {
      final r = await api.adminClaimExisting();
      if (mounted) {
        showOk(
          context,
          '${r['claimed'] ?? 0} alamat baru didaftarkan (${r['found'] ?? 0} ditemukan)',
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kelola akun'),
        actions: [
          IconButton(
            tooltip: 'Alamat terdaftar',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const RegisteredMailboxesScreen(),
              ),
            ),
            icon: const Icon(Icons.alternate_email),
          ),
          PopupMenuButton<String>(
            tooltip: 'Lainnya',
            onSelected: (v) {
              if (v == 'claim') _claimExisting();
              if (v == 'reload') _load();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'reload', child: Text('Muat ulang')),
              PopupMenuItem(
                value: 'claim',
                child: Text('Daftarkan alamat lama ke admin'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Akun baru'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
              decoration: const InputDecoration(
                hintText: 'Cari username / catatan',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: TextStyle(color: s.error)),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _loading && _items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 80),
                        EmptyState(
                          icon: Icons.manage_accounts_outlined,
                          title: 'Belum ada akun',
                          subtitle: 'Buat akun untuk pengguna APK publik dengan tombol "Akun baru".',
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: _items.length,
                      itemBuilder: (ctx, i) {
                        final u = _items[i] as Map;
                        final (status, bad) = _statusOf(u);
                        final note = _str(u['note']);
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: bad
                                ? s.errorContainer
                                : s.primaryContainer,
                            child: Text(
                              _str(u['username']).isEmpty
                                  ? '?'
                                  : _str(u['username'])[0].toUpperCase(),
                            ),
                          ),
                          title: Text(
                            _str(u['username']),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            [
                              status,
                              'hari ini ${u['used_today'] ?? 0}/${u['daily_quota'] ?? '?'}',
                              '${u['active_devices'] ?? 0}/${u['max_devices'] ?? '?'} HP',
                              '${u['mailboxes'] ?? 0} alamat',
                              if (note.isNotEmpty) note,
                            ].join(' · '),
                            style: TextStyle(color: bad ? s.error : null),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => UserDetailScreen(
                                  username: _str(u['username']),
                                ),
                              ),
                            );
                            _load();
                          },
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================ FORM AKUN ============================
/// Buat akun baru ([initial] null) atau ubah akun yang ada.
/// Hasil: respons server ({user, password?}).
class _UserFormDialog extends StatefulWidget {
  final Map? initial;
  const _UserFormDialog({this.initial});
  @override
  State<_UserFormDialog> createState() => _UserFormDialogState();
}

class _UserFormDialogState extends State<_UserFormDialog> {
  late final _username = TextEditingController(
    text: _str(widget.initial?['username']),
  );
  final _password = TextEditingController();
  late final _quota = TextEditingController(
    text: _str(widget.initial?['daily_quota'] ?? 20),
  );
  late final _devices = TextEditingController(
    text: _str(widget.initial?['max_devices'] ?? 2),
  );
  late final _note = TextEditingController(text: _str(widget.initial?['note']));
  DateTime? _expiry;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final e = widget.initial?['expires_at'];
    if (e != null) _expiry = DateTime.tryParse('$e')?.toLocal();
  }

  @override
  void dispose() {
    for (final c in [_username, _password, _quota, _devices, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _expiry ?? now.add(const Duration(days: 30)),
      firstDate: now,
      lastDate: DateTime(now.year + 10),
      helpText: 'Aktif sampai',
    );
    if (d != null) setState(() => _expiry = d);
  }

  Future<void> _save() async {
    final quota = int.tryParse(_quota.text.trim());
    final devices = int.tryParse(_devices.text.trim());
    if (quota == null || quota < 0) {
      setState(() => _error = 'Kuota harian harus angka ≥ 0.');
      return;
    }
    if (devices == null || devices < 1 || devices > 10) {
      setState(() => _error = 'Batas perangkat 1-10.');
      return;
    }
    if (_password.text.isNotEmpty && _password.text.length < 6) {
      setState(() => _error = 'Password minimal 6 karakter (kosong = acak).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dynamic r;
      if (_editing) {
        final init = widget.initial!;
        final initExp = init['expires_at'] == null
            ? null
            : _ymd(DateTime.parse('${init['expires_at']}').toLocal());
        final exp = _expiry == null ? null : _ymd(_expiry!);
        r = await api.adminPatchUser(_str(init['username']), {
          if (quota != init['daily_quota']) 'daily_quota': quota,
          if (devices != init['max_devices']) 'max_devices': devices,
          if (_note.text.trim() != _str(init['note']))
            'note': _note.text.trim(),
          if (exp != initExp) 'expires_at': exp,
        });
      } else {
        r = await api.adminCreateUser(
          username: _username.text.trim().toLowerCase(),
          password: _password.text,
          dailyQuota: quota,
          maxDevices: devices,
          expiresAt: _expiry == null ? null : _ymd(_expiry!),
          note: _note.text.trim(),
        );
      }
      if (mounted) Navigator.pop(context, r as Map);
    } on ApiException catch (e) {
      // Tidak ada yang berubah = sukses tanpa aksi.
      if (e.code == 'NOTHING_TO_UPDATE' && mounted) {
        Navigator.pop(context);
        return;
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_editing ? 'Ubah akun' : 'Akun baru'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _username,
              enabled: !_editing,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Username',
                helperText: '3-32: huruf kecil, angka, . _ -',
              ),
            ),
            if (!_editing) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _password,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  helperText: 'Kosong = dibuatkan acak',
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _quota,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Kuota/hari'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _devices,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Maks. HP'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _expiry == null
                        ? 'Masa aktif: permanen'
                        : 'Aktif s/d ${_expiry!.day}/${_expiry!.month}/${_expiry!.year}',
                  ),
                ),
                TextButton(onPressed: _pickDate, child: const Text('Pilih')),
                if (_expiry != null)
                  IconButton(
                    tooltip: 'Jadikan permanen',
                    onPressed: () => setState(() => _expiry = null),
                    icon: const Icon(Icons.all_inclusive),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                labelText: 'Catatan (opsional)',
                helperText: 'Mis. nama pemakai / no. WA',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: s.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_editing ? 'Simpan' : 'Buat'),
        ),
      ],
    );
  }
}

// ============================ DETAIL AKUN ============================
class UserDetailScreen extends StatefulWidget {
  final String username;
  const UserDetailScreen({super.key, required this.username});
  @override
  State<UserDetailScreen> createState() => _UserDetailScreenState();
}

class _UserDetailScreenState extends State<UserDetailScreen> {
  Map? _user;
  List _sessions = const [];
  List _mailboxes = const [];
  int _mbTotal = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await api.adminUser(widget.username);
      final m = await api.adminMailboxes(owner: widget.username, limit: 200);
      if (!mounted) return;
      setState(() {
        _user = r['user'] as Map?;
        _sessions = listOf(r['sessions']);
        _mailboxes = listOf(m);
        _mbTotal = (m is Map && m['total'] is num)
            ? (m['total'] as num).toInt()
            : _mailboxes.length;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit() async {
    final r = await showDialog<Map>(
      context: context,
      builder: (_) => _UserFormDialog(initial: _user),
    );
    if (r == null || !mounted) return;
    final n = r['sessions_revoked'];
    showOk(
      context,
      n is num && n > 0 ? 'Disimpan · $n perangkat dikeluarkan' : 'Disimpan',
    );
    _load();
  }

  Future<void> _patch(Map<String, dynamic> body, String ok) async {
    try {
      final r = await api.adminPatchUser(widget.username, body);
      if (!mounted) return;
      if (r is Map && r['password'] != null) {
        await _showCredentials(
          context,
          widget.username,
          '${r['password']}',
          title: 'Password direset',
        );
      } else {
        showOk(context, ok);
      }
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _resetPassword() async {
    final ok = await confirmDialog(
      context,
      title: 'Reset password akun?',
      body:
          'Password baru dibuat acak dan semua perangkat ${widget.username} dikeluarkan.',
      confirmLabel: 'Reset',
    );
    if (ok) await _patch({'password': ''}, 'Password direset');
  }

  Future<void> _toggleDisabled() async {
    final disabled = _user?['disabled'] == true;
    if (!disabled) {
      final ok = await confirmDialog(
        context,
        title: 'Nonaktifkan akun?',
        body:
            '${widget.username} langsung keluar dari semua perangkat dan tidak bisa login '
            'sampai diaktifkan lagi. Alamatnya tetap tersimpan.',
        confirmLabel: 'Nonaktifkan',
      );
      if (!ok) return;
    }
    await _patch({
      'disabled': !disabled,
    }, disabled ? 'Akun diaktifkan' : 'Akun dinonaktifkan');
  }

  Future<void> _revokeAll() async {
    try {
      final r = await api.adminRevokeUserSessions(widget.username);
      if (mounted) {
        showOk(context, '${r['revoked'] ?? 0} perangkat dikeluarkan');
      }
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(
      context,
      title: 'Hapus akun ${widget.username}?',
      body:
          'Akun, favorit, dan riwayatnya dihapus permanen. $_mbTotal alamat miliknya '
          'DIKUNCI permanen: tidak bisa dibuka atau diklaim akun lain '
          '(admin tetap bisa membukanya).',
    );
    if (!ok) return;
    try {
      final r = await api.adminDeleteUser(widget.username);
      if (!mounted) return;
      showOk(
        context,
        'Akun dihapus · ${r['mailboxes_locked'] ?? 0} alamat dikunci',
      );
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final u = _user;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.username),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null) Text(_error!, style: TextStyle(color: s.error)),
            if (u == null && _loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (u != null) ...[
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        _statusOf(u).$2
                            ? Icons.block
                            : Icons.verified_user_outlined,
                        color: _statusOf(u).$2 ? s.error : s.primary,
                      ),
                      title: Text(_statusOf(u).$1),
                      subtitle: Text(
                        [
                          'Dibuat ${fmtTime(u['created_at'])}',
                          if (u['last_login_at'] != null)
                            'login terakhir ${fmtTime(u['last_login_at'])}',
                        ].join(' · '),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.bolt_outlined),
                      title: Text(
                        'Kuota hari ini ${u['used_today'] ?? 0}/${u['daily_quota'] ?? '?'}',
                      ),
                      subtitle: Text(
                        'Maks. ${u['max_devices'] ?? '?'} perangkat',
                      ),
                    ),
                    if (_str(u['note']).isNotEmpty)
                      ListTile(
                        leading: const Icon(Icons.notes),
                        title: Text(_str(u['note'])),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _edit,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Ubah'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _resetPassword,
                    icon: const Icon(Icons.password, size: 18),
                    label: const Text('Reset password'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _toggleDisabled,
                    icon: Icon(
                      u['disabled'] == true
                          ? Icons.check_circle_outline
                          : Icons.block,
                      size: 18,
                    ),
                    label: Text(
                      u['disabled'] == true ? 'Aktifkan' : 'Nonaktifkan',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Perangkat aktif (${_sessions.length})',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_sessions.isNotEmpty)
                    TextButton(
                      onPressed: _revokeAll,
                      child: const Text('Keluarkan semua'),
                    ),
                ],
              ),
              if (_sessions.isEmpty)
                Text(
                  'Tidak ada perangkat yang sedang login.',
                  style: TextStyle(color: s.onSurfaceVariant),
                ),
              for (final x in _sessions.whereType<Map>())
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.phone_android_outlined),
                  title: Text(
                    _str(x['device']).isEmpty ? 'Perangkat' : _str(x['device']),
                  ),
                  subtitle: Text(
                    'Login ${fmtTime(x['created_at'])} · aktif ${fmtTime(x['last_seen_at'])}',
                  ),
                ),
              const SizedBox(height: 20),
              Text(
                'Alamat milik akun ($_mbTotal)',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (_mailboxes.isEmpty)
                Text(
                  'Belum ada alamat.',
                  style: TextStyle(color: s.onSurfaceVariant),
                ),
              for (final m in _mailboxes.whereType<Map>())
                _MailboxTile(m: m, onChanged: _load),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: s.error),
                onPressed: _delete,
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Hapus akun'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================ ALAMAT TERDAFTAR ============================
class RegisteredMailboxesScreen extends StatefulWidget {
  const RegisteredMailboxesScreen({super.key});
  @override
  State<RegisteredMailboxesScreen> createState() =>
      _RegisteredMailboxesScreenState();
}

class _RegisteredMailboxesScreenState extends State<RegisteredMailboxesScreen> {
  final _q = TextEditingController();
  List _items = const [];
  int _total = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await api.adminMailboxes(q: _q.text.trim(), limit: 200);
      if (!mounted) return;
      setState(() {
        _items = listOf(r);
        _total = (r is Map && r['total'] is num)
            ? (r['total'] as num).toInt()
            : _items.length;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Alamat terdaftar')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
              decoration: const InputDecoration(
                hintText: 'Cari alamat',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: TextStyle(color: s.error)),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '$_total alamat',
                style: TextStyle(color: s.onSurfaceVariant),
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _loading && _items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _items.length,
                      itemBuilder: (ctx, i) => _MailboxTile(
                        m: _items[i] as Map,
                        onChanged: _load,
                        showOwner: true,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MailboxTile extends StatelessWidget {
  final Map m;
  final VoidCallback onChanged;
  final bool showOwner;
  const _MailboxTile({
    required this.m,
    required this.onChanged,
    this.showOwner = false,
  });

  Future<void> _move(BuildContext context, String address) async {
    final c = TextEditingController(text: _str(m['owner']));
    final owner = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pindahkan pemilik'),
        content: TextField(
          controller: c,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Username pemilik baru',
            helperText: 'Tulis "admin" untuk milik admin',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Pindahkan'),
          ),
        ],
      ),
    );
    if (owner == null || owner.isEmpty) return;
    try {
      await api.adminPatchMailbox(address, owner: owner);
      if (context.mounted) showOk(context, '$address kini milik $owner');
      onChanged();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _lock(BuildContext context, String address, bool lock) async {
    try {
      await api.adminPatchMailbox(address, locked: lock);
      if (context.mounted) {
        showOk(context, lock ? '$address dikunci' : '$address dibuka kuncinya');
      }
      onChanged();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final address = _str(m['address']);
    final locked = m['locked'] == true;
    final shared = m['shared_with'];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        locked ? Icons.lock_outline : Icons.alternate_email,
        color: locked ? s.error : null,
      ),
      title: Text(address),
      subtitle: Text(
        [
          if (showOwner) 'milik ${_str(m['owner'])}',
          if (locked) 'dikunci',
          if (shared is num && shared > 0) 'dibuka $shared akun lain',
          fmtTime(m['created_at']),
        ].join(' · '),
      ),
      onTap: () => showMailboxPasswordDialog(context, address),
      trailing: PopupMenuButton<String>(
        tooltip: 'Aksi',
        onSelected: (v) async {
          switch (v) {
            case 'use':
              await appState.setActive(address, address);
              if (context.mounted) {
                Navigator.of(context).popUntil((r) => r.isFirst);
              }
              currentTab.value = kTabHome;
            case 'pw':
              showMailboxPasswordDialog(context, address);
            case 'move':
              _move(context, address);
            case 'lock':
              _lock(context, address, !locked);
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'use', child: Text('Jadikan aktif')),
          const PopupMenuItem(value: 'pw', child: Text('Password email')),
          const PopupMenuItem(value: 'move', child: Text('Pindahkan pemilik')),
          PopupMenuItem(
            value: 'lock',
            child: Text(locked ? 'Buka kunci' : 'Kunci'),
          ),
        ],
      ),
    );
  }
}
