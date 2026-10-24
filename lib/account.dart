// Akun APK publik: login dengan akun buatan admin, sesi per perangkat,
// password email (buka alamat milik akun lain), dan layar Akun / Alamat saya.
//
// APK admin (tanpa PUBLIC_BUILD) tidak memakai apa pun di sini kecuali
// dialog password email (admin bisa melihat/mengganti password alamat mana pun).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'main.dart';
import 'screens_main.dart' show fmtTime;

// ============================ STATE ============================
class AuthState extends ChangeNotifier {
  String? token;
  Map<String, dynamic>? user;

  /// Alasan keluar terakhir (mis. "login di perangkat lain"), tampil di Login.
  String? lostReason;
  bool loaded = false;

  bool get signedIn => token != null;
  String? get username => user?['username']?.toString();

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/tempmail_session.json');
  }

  /// Baca sesi tersimpan. Dipakai juga di isolate latar widget.
  Future<void> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        token = m['token'] as String?;
        user = (m['user'] as Map?)?.cast<String, dynamic>();
      }
    } catch (_) {}
    TempmailApi.sessionToken = token;
    if (kPublic) TempmailApi.onSessionLost ??= handleSessionLost;
    loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      if (token == null) {
        if (await f.exists()) await f.delete();
      } else {
        await f.writeAsString(jsonEncode({'token': token, 'user': user}));
      }
    } catch (_) {}
  }

  Future<void> signIn(String username, String password) async {
    final r = await api.login(
      username.trim().toLowerCase(),
      password,
      device: await _deviceName(),
    );
    token = r['token'] as String;
    user = (r['user'] as Map?)?.cast<String, dynamic>();
    lostReason = null;
    TempmailApi.sessionToken = token;
    await _save();
    // Data akun sebelumnya (alamat aktif, favorit) bukan milik akun ini.
    await appState.clearActive();
    setFavoritesFrom(const []);
    notifyListeners();
  }

  /// Keluar. [remote] = beri tahu server (logout biasa); false bila server
  /// sendiri yang sudah menolak sesi.
  Future<void> signOut({String? reason, bool remote = true}) async {
    if (token == null) return;
    if (remote) {
      try {
        await api.logout();
      } catch (_) {}
    }
    token = null;
    user = null;
    lostReason = reason;
    TempmailApi.sessionToken = null;
    // Layar yang sedang terbuka (mis. Menu → Akun) ikut ditutup.
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    currentTab.value = kTabHome;
    // Layar Login langsung tampil; penyimpanan menyusul.
    notifyListeners();
    setFavoritesFrom(const []);
    await _save();
    await appState.clearActive();
  }

  /// Perbarui profil (kuota terpakai, masa aktif) dari server.
  Future<Map?> refresh() async {
    if (token == null) return null;
    final r = await api.authMe();
    if (r is Map && r['user'] is Map) {
      user = (r['user'] as Map).cast<String, dynamic>();
      await _save();
      notifyListeners();
    }
    return r is Map ? r : null;
  }

  /// Kuota dari respons pembuatan alamat ({used, limit, remaining}).
  void applyQuota(dynamic q) {
    if (q is! Map || user == null) return;
    user = {...user!, 'used_today': q['used'], 'daily_quota': q['limit']};
    notifyListeners();
    _save();
  }

  /// Tes: anggap sudah login tanpa memanggil server.
  @visibleForTesting
  void debugSignIn(String t, Map<String, dynamic> u) {
    token = t;
    user = u;
    loaded = true;
    TempmailApi.sessionToken = t;
    notifyListeners();
  }

  void handleSessionLost(ApiException e) {
    signOut(reason: e.message, remote: false);
  }
}

final authState = AuthState();

Future<String> _deviceName() async {
  try {
    final info = await const MethodChannel('tempmail/app')
        .invokeMapMethod<String, dynamic>('info');
    final m = '${info?['model'] ?? ''}'.trim();
    if (m.isNotEmpty) return m;
  } catch (_) {}
  return Platform.operatingSystem;
}

/// Kuota hari ini untuk ditampilkan: "3/20".
String quotaText(Map? u) {
  if (u == null) return '';
  return '${u['used_today'] ?? 0}/${u['daily_quota'] ?? '?'}';
}

String expiryText(dynamic iso) {
  if (iso == null || '$iso'.isEmpty) return 'Permanen';
  final d = DateTime.tryParse('$iso')?.toLocal();
  if (d == null) return '$iso';
  String two(int n) => n.toString().padLeft(2, '0');
  return 'Aktif s/d ${two(d.day)}/${two(d.month)}/${d.year}';
}

// ============================ GERBANG ============================
/// APK publik: tampilkan Login sampai ada sesi. APK admin: langsung [child].
class AuthGate extends StatelessWidget {
  final Widget child;
  const AuthGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!kPublic) return child;
    return ListenableBuilder(
      listenable: authState,
      builder: (context, _) {
        if (!authState.loaded) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return authState.signedIn ? child : const LoginScreen();
      },
    );
  }
}

// ============================ LOGIN ============================
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final u = _user.text.trim();
    if (u.isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Isi username dan password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await authState.signIn(u, _pass.text);
      // AuthGate berganti ke aplikasi; info perangkat lain yang dikeluarkan.
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final reason = authState.lostReason;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.mark_email_read_outlined,
                      size: 64,
                      color: s.primary,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'TempMail',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Masuk dengan akun yang dibuatkan admin.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: s.onSurfaceVariant),
                    ),
                    const SizedBox(height: 24),
                    if (reason != null && _error == null) ...[
                      _Banner(
                        icon: Icons.info_outline,
                        text: reason,
                        color: s.secondaryContainer,
                        onColor: s.onSecondaryContainer,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_error != null) ...[
                      _Banner(
                        icon: Icons.error_outline,
                        text: _error!,
                        color: s.errorContainer,
                        onColor: s.onErrorContainer,
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _user,
                      enabled: !_busy,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pass,
                      enabled: !_busy,
                      obscureText: !_show,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _show ? 'Sembunyikan' : 'Tampilkan',
                          onPressed: () => setState(() => _show = !_show),
                          icon: Icon(
                            _show ? Icons.visibility_off : Icons.visibility,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _busy ? null : _submit,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: const Text('Masuk'),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Satu akun bisa dipakai di beberapa HP sekaligus sesuai '
                      'batas dari admin. Login di HP baru saat batas penuh akan '
                      'mengeluarkan HP yang paling lama login.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  final Color onColor;
  const _Banner({
    required this.icon,
    required this.text,
    required this.color,
    required this.onColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: onColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: onColor)),
          ),
        ],
      ),
    );
  }
}

// ============================ DIALOG PASSWORD EMAIL ============================
/// Buka alamat milik akun lain dengan password-nya. true = berhasil.
Future<bool> unlockMailboxDialog(
  BuildContext context,
  String address, {
  String? note,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _UnlockDialog(address: address, note: note),
  );
  if (ok == true) appState.touch();
  return ok ?? false;
}

class _UnlockDialog extends StatefulWidget {
  final String address;
  final String? note;
  const _UnlockDialog({required this.address, this.note});
  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  final _pw = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;

  Future<void> _go() async {
    if (_pw.text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.unlockMailbox(widget.address, _pw.text);
      if (mounted) Navigator.pop(context, true);
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
      title: const Text('Buka alamat'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            widget.address,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            widget.note ??
                'Alamat ini milik akun lain. Masukkan password email-nya. '
                    'Akses berlaku sampai pemiliknya mengganti password.',
            style: TextStyle(color: s.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pw,
            autofocus: true,
            obscureText: !_show,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => _go(),
            decoration: InputDecoration(
              labelText: 'Password email',
              errorText: _error,
              errorMaxLines: 3,
              suffixIcon: IconButton(
                tooltip: _show ? 'Sembunyikan' : 'Tampilkan',
                onPressed: () => setState(() => _show = !_show),
                icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _busy ? null : _go,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Buka'),
        ),
      ],
    );
  }
}

/// Tampilkan password email (pemilik / admin), dengan tombol salin & ganti.
/// [password] sudah diketahui (mis. baru dibuat) → tidak perlu memanggil server.
Future<void> showMailboxPasswordDialog(
  BuildContext context,
  String address, {
  String? password,
  String? title,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _PasswordDialog(address: address, initial: password, title: title),
);

class _PasswordDialog extends StatefulWidget {
  final String address;
  final String? initial;
  final String? title;
  const _PasswordDialog({required this.address, this.initial, this.title});
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  String? _pw;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _pw = widget.initial;
    if (_pw == null) _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final r = await api.mailboxPassword(widget.address);
      if (mounted) setState(() => _pw = r['password']?.toString());
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change() async {
    final next = await showDialog<String>(
      context: context,
      builder: (_) => const _NewPasswordDialog(),
    );
    if (next == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await api.setMailboxPassword(widget.address, password: next);
      if (!mounted) return;
      setState(() => _pw = r['password']?.toString());
      final n = r['grants_revoked'];
      showOk(
        context,
        n is num && n > 0
            ? 'Password diganti. $n akun lain harus memasukkan password baru.'
            : 'Password diganti.',
      );
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final pw = _pw;
    return AlertDialog(
      title: Text(widget.title ?? 'Password email'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(widget.address),
          const SizedBox(height: 12),
          if (_busy && pw == null)
            const Center(child: CircularProgressIndicator())
          else if (pw != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: s.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      pw,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Salin password',
                    onPressed: () =>
                        copyText(context, pw, 'Password email disalin'),
                    icon: const Icon(Icons.copy),
                  ),
                ],
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: s.error)),
          ],
          const SizedBox(height: 10),
          Text(
            'Bagikan password ini hanya ke orang yang boleh membaca inbox. '
            'Mengganti password mencabut akses semua orang lain.',
            style: TextStyle(color: s.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _change,
          child: const Text('Ganti password'),
        ),
        if (pw != null)
          TextButton(
            onPressed: () => copyText(
              context,
              '${widget.address}\nPassword: $pw',
              'Alamat & password disalin',
            ),
            child: const Text('Salin keduanya'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Tutup'),
        ),
      ],
    );
  }
}

/// Minta password baru; '' = dibuatkan acak oleh server.
class _NewPasswordDialog extends StatefulWidget {
  const _NewPasswordDialog();
  @override
  State<_NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends State<_NewPasswordDialog> {
  final _c = TextEditingController();
  String? _error;

  void _ok() {
    final v = _c.text;
    if (v.isNotEmpty && (v.length < 4 || v.length > 64)) {
      setState(() => _error = 'Password email 4-64 karakter.');
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ganti password email'),
      content: TextField(
        controller: _c,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (_) => _ok(),
        decoration: InputDecoration(
          labelText: 'Password baru',
          helperText: 'Kosongkan untuk dibuatkan acak',
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(onPressed: _ok, child: const Text('Ganti')),
      ],
    );
  }
}

/// Galat akses alamat dari server → tawarkan aksi yang tepat.
/// Mengembalikan true bila pengguna berhasil membuka alamat.
Future<bool> resolveAccessError(BuildContext context, Object e) async {
  if (e is! ApiException) return false;
  final d = e.details is Map ? e.details as Map : const {};
  final address = d['address']?.toString();
  if (address == null) return false;
  if (e.code == 'MAILBOX_PASSWORD_REQUIRED' ||
      (e.code == 'ADDRESS_TAKEN' && d['needs_password'] == true)) {
    return unlockMailboxDialog(
      context,
      address,
      note: d['password_changed'] == true
          ? 'Pemilik alamat ini sudah mengganti password. Masukkan password '
                'yang baru untuk membukanya lagi.'
          : null,
    );
  }
  return false;
}

// ============================ AKUN ============================
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  List _sessions = const [];
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
      final r = await authState.refresh();
      if (mounted) setState(() => _sessions = listOf(r?['sessions']));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(Map s) async {
    final ok = await confirmDialog(
      context,
      title: 'Keluarkan perangkat?',
      body:
          '${s['device'] ?? 'Perangkat'} harus login lagi untuk memakai akun ini.',
      confirmLabel: 'Keluarkan',
    );
    if (!ok) return;
    try {
      await api.revokeSession('${s['id']}');
      if (mounted) showOk(context, 'Perangkat dikeluarkan');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _revokeOthers() async {
    final ok = await confirmDialog(
      context,
      title: 'Keluarkan semua perangkat lain?',
      body: 'Hanya HP ini yang tetap masuk.',
      confirmLabel: 'Keluarkan',
    );
    if (!ok) return;
    try {
      final r = await api.revokeOtherSessions();
      if (mounted) {
        showOk(context, '${r['revoked'] ?? 0} perangkat dikeluarkan');
      }
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _changePassword() async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => const _ChangeAccountPasswordDialog(),
    );
    if (done == true) {
      if (mounted) {
        showOk(context, 'Password akun diganti. Perangkat lain dikeluarkan.');
      }
      _load();
    }
  }

  Future<void> _logout() async {
    final ok = await confirmDialog(
      context,
      title: 'Keluar dari akun?',
      body: 'Kamu perlu login lagi untuk memakai aplikasi.',
      confirmLabel: 'Keluar',
    );
    if (!ok) return;
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    currentTab.value = kTabHome;
    await authState.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: authState,
      builder: (context, _) {
        final u = authState.user ?? const {};
        final expired = u['expired'] == true;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Akun'),
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
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: TextStyle(color: s.error)),
                  ),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            (authState.username ?? '?')
                                .substring(0, 1)
                                .toUpperCase(),
                          ),
                        ),
                        title: Text(
                          authState.username ?? '-',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          expired
                              ? 'Masa aktif habis'
                              : expiryText(u['expires_at']),
                          style: TextStyle(color: expired ? s.error : null),
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.bolt_outlined),
                        title: Text(
                          'Jatah alamat baru hari ini: ${quotaText(u)}',
                        ),
                        subtitle: const Text('Direset tiap pukul 00.00 WIB'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.alternate_email),
                        title: Text('${u['mailboxes'] ?? 0} alamat milikmu'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const MyMailboxesScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Perangkat aktif (${_sessions.length}/${u['max_devices'] ?? '?'})',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (_sessions.length > 1)
                      TextButton(
                        onPressed: _revokeOthers,
                        child: const Text('Keluarkan lainnya'),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                if (_loading && _sessions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                for (final x in _sessions.whereType<Map>())
                  Card(
                    child: ListTile(
                      leading: Icon(
                        x['current'] == true
                            ? Icons.smartphone
                            : Icons.phone_android_outlined,
                        color: x['current'] == true ? s.primary : null,
                      ),
                      title: Text(
                        '${(x['device'] ?? '').toString().isEmpty ? 'Perangkat' : x['device']}'
                        '${x['current'] == true ? ' (HP ini)' : ''}',
                      ),
                      subtitle: Text(
                        'Login ${fmtTime(x['created_at'])} · aktif ${fmtTime(x['last_seen_at'])}',
                      ),
                      trailing: x['current'] == true
                          ? null
                          : IconButton(
                              tooltip: 'Keluarkan',
                              onPressed: () => _revoke(x),
                              icon: const Icon(Icons.logout),
                            ),
                    ),
                  ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _changePassword,
                  icon: const Icon(Icons.password),
                  label: const Text('Ganti password akun'),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(foregroundColor: s.error),
                  onPressed: _logout,
                  icon: const Icon(Icons.logout),
                  label: const Text('Keluar'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ChangeAccountPasswordDialog extends StatefulWidget {
  const _ChangeAccountPasswordDialog();
  @override
  State<_ChangeAccountPasswordDialog> createState() =>
      _ChangeAccountPasswordDialogState();
}

class _ChangeAccountPasswordDialogState
    extends State<_ChangeAccountPasswordDialog> {
  final _cur = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    if (_next.text.length < 6) {
      setState(() => _error = 'Password baru minimal 6 karakter.');
      return;
    }
    if (_next.text != _again.text) {
      setState(() => _error = 'Ulangi password baru belum sama.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.changePassword(_cur.text, _next.text);
      if (mounted) Navigator.pop(context, true);
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
    InputDecoration dec(String l) => InputDecoration(labelText: l);
    return AlertDialog(
      title: const Text('Ganti password akun'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _cur,
              obscureText: true,
              decoration: dec('Password saat ini'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _next,
              obscureText: true,
              decoration: dec('Password baru (min. 6)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _again,
              obscureText: true,
              onSubmitted: (_) => _go(),
              decoration: dec('Ulangi password baru'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _busy ? null : _go,
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}

// ============================ ALAMAT SAYA ============================
class MyMailboxesScreen extends StatefulWidget {
  const MyMailboxesScreen({super.key});
  @override
  State<MyMailboxesScreen> createState() => _MyMailboxesScreenState();
}

class _MyMailboxesScreenState extends State<MyMailboxesScreen> {
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
      final r = await api.myMailboxes(q: _q.text.trim(), limit: 200);
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

  Future<void> _use(String address) async {
    await appState.setActive(address, address);
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    currentTab.value = kTabHome;
  }

  Future<void> _drop(String address) async {
    final ok = await confirmDialog(
      context,
      title: 'Lepas akses?',
      body:
          '$address hilang dari daftarmu. Untuk membukanya lagi perlu password email-nya.',
      confirmLabel: 'Lepas',
    );
    if (!ok) return;
    try {
      await api.dropAccess(address);
      if (appState.activeAddress == address) await appState.clearActive();
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _openOther() async {
    final c = TextEditingController();
    final address = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Buka alamat akun lain'),
        content: TextField(
          controller: c,
          autofocus: true,
          autocorrect: false,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Alamat email',
            hintText: 'nama@domain.com',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Lanjut'),
          ),
        ],
      ),
    );
    if (address == null || !address.contains('@') || !mounted) return;
    final ok = await unlockMailboxDialog(context, address.toLowerCase());
    if (ok) await _use(address.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alamat saya'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openOther,
        icon: const Icon(Icons.key),
        label: const Text('Buka alamat lain'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'Cari alamat',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: _q.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Hapus',
                        onPressed: () {
                          _q.clear();
                          _load();
                        },
                        icon: const Icon(Icons.close),
                      ),
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
                          icon: Icons.alternate_email,
                          title: 'Belum ada alamat',
                          subtitle: 'Alamat yang kamu buat, atau yang kamu buka dengan password, tampil di sini.',
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: _items.length + 1,
                      itemBuilder: (ctx, i) {
                        if (i == 0) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                            child: Text(
                              '$_total alamat',
                              style: TextStyle(color: s.onSurfaceVariant),
                            ),
                          );
                        }
                        final m = _items[i - 1] as Map;
                        final addr = '${m['address']}';
                        final owner = m['access'] == 'owner';
                        final active = addr == appState.activeAddress;
                        return ListTile(
                          leading: Icon(
                            owner ? Icons.person : Icons.people_outline,
                            color: active ? s.primary : null,
                          ),
                          title: Text(
                            addr,
                            style: TextStyle(
                              fontWeight: active ? FontWeight.w700 : null,
                            ),
                          ),
                          subtitle: Text(
                            '${owner ? 'Milik saya' : 'Dibuka dengan password'}'
                            ' · ${fmtTime(m['created_at'])}'
                            '${active ? ' · aktif' : ''}',
                          ),
                          onTap: () => _use(addr),
                          trailing: PopupMenuButton<String>(
                            tooltip: 'Aksi',
                            onSelected: (v) {
                              switch (v) {
                                case 'copy':
                                  copyText(context, addr, 'Alamat disalin');
                                case 'pw':
                                  showMailboxPasswordDialog(context, addr);
                                case 'drop':
                                  _drop(addr);
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'copy',
                                child: Text('Salin alamat'),
                              ),
                              if (owner)
                                const PopupMenuItem(
                                  value: 'pw',
                                  child: Text('Password email'),
                                ),
                              if (!owner)
                                const PopupMenuItem(
                                  value: 'drop',
                                  child: Text('Lepas akses'),
                                ),
                            ],
                          ),
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
