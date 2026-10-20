// Layar OTP: terbaru, tunggu, tunggu banyak alamat, stream SSE,
// riwayat, uji ekstrak, dan link verifikasi.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'main.dart';

class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key});
  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  dynamic _latest;
  dynamic _waitResult;
  bool _waiting = false;
  final _timeoutCtl = TextEditingController(text: '50');
  final _refsCtl = TextEditingController();
  dynamic _waitAnyResult;
  bool _waitingAny = false;
  String _waitAnyMode = 'otp';

  StreamSubscription? _sub;
  final List<String> _streamLog = [];
  bool _streaming = false;

  dynamic _history;
  final _extractCtl = TextEditingController();
  dynamic _extractResult;
  dynamic _verifyLatest;
  dynamic _verifyWait;
  bool _verifyWaiting = false;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String? get _ref => appState.activeRef;

  Future<void> _loadLatest() async {
    final ref = _ref;
    if (ref == null) return;
    try {
      final r = await api.otpLatest(ref);
      if (mounted) setState(() => _latest = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _loadHistory() async {
    final ref = _ref;
    if (ref == null) return;
    try {
      final r = await api.otpHistory(ref);
      if (mounted) setState(() => _history = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _wait() async {
    final ref = _ref;
    if (ref == null) return;
    setState(() {
      _waiting = true;
      _waitResult = null;
    });
    try {
      final t = int.tryParse(_timeoutCtl.text) ?? 50;
      final r = await api.otpWait(ref, timeout: t.clamp(5, 280));
      if (mounted) setState(() => _waitResult = r);
    } catch (e) {
      if (mounted) {
        setState(() => _waitResult = {
              'status': 'timeout/gagal',
              'pesan': e is ApiException ? e.message : e.toString(),
            });
      }
    } finally {
      if (mounted) setState(() => _waiting = false);
    }
  }

  Future<void> _waitAny() async {
    final refs = _refsCtl.text
        .split(RegExp(r'[\n,]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (refs.isEmpty) {
      showError(context, 'Isi dulu daftar alamatnya');
      return;
    }
    setState(() {
      _waitingAny = true;
      _waitAnyResult = null;
    });
    try {
      final t = int.tryParse(_timeoutCtl.text) ?? 50;
      final r = await api.otpWaitAny(
          refs: refs, timeout: t.clamp(5, 280), mode: _waitAnyMode);
      if (mounted) setState(() => _waitAnyResult = r);
    } catch (e) {
      if (mounted) {
        setState(() => _waitAnyResult = {
              'status': 'timeout/gagal',
              'pesan': e is ApiException ? e.message : e.toString(),
            });
      }
    } finally {
      if (mounted) setState(() => _waitingAny = false);
    }
  }

  void _toggleStream() {
    if (_streaming) {
      _sub?.cancel();
      setState(() => _streaming = false);
      return;
    }
    final ref = _ref;
    if (ref == null) return;
    setState(() {
      _streaming = true;
      _streamLog.clear();
    });
    _sub = api.otpStream(ref).listen(
      (ev) {
        if (!mounted) return;
        setState(() {
          _streamLog.insert(0,
              '${ev['event']}: ${ev['otp'] ?? ev['code'] ?? ev['data'] ?? ev['raw'] ?? ''}');
          if (_streamLog.length > 50) _streamLog.removeLast();
        });
        if (ev['event'] == 'timeout') {
          _sub?.cancel();
          setState(() => _streaming = false);
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            _streamLog.insert(0, 'error: $e');
            _streaming = false;
          });
        }
      },
      onDone: () {
        if (mounted) setState(() => _streaming = false);
      },
    );
  }

  Future<void> _extract() async {
    if (_extractCtl.text.trim().isEmpty) return;
    try {
      final r = await api.otpExtract(_extractCtl.text);
      if (mounted) setState(() => _extractResult = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _verify(bool wait) async {
    final ref = _ref;
    if (ref == null) return;
    if (wait) setState(() => _verifyWaiting = true);
    try {
      final r = wait ? await api.verifyWait(ref) : await api.verifyLatest(ref);
      if (mounted) {
        setState(() {
          if (wait) {
            _verifyWait = r;
          } else {
            _verifyLatest = r;
          }
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _verifyWaiting = false);
    }
  }

  Widget _otpCard(String title, dynamic r, {String key = 'otp'}) {
    final s = Theme.of(context).colorScheme;
    final code = r is Map ? r[key]?.toString() : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (r == null)
            Text('Belum dimuat.', style: TextStyle(color: s.onSurfaceVariant))
          else if (code != null && code.isNotEmpty)
            Row(children: [
              Expanded(
                child: Text(code,
                    style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2)),
              ),
              IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  showOk(context, 'Disalin');
                },
              ),
            ])
          else
            JsonView(r),
          if (r is Map && r['message'] is Map)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  '${r['message']['subject'] ?? ''} — ${r['message']['from'] ?? ''}',
                  style: TextStyle(color: s.onSurfaceVariant)),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ref = _ref;
    return Scaffold(
      appBar: AppBar(title: const Text('OTP & Verifikasi')),
      body: ref == null
          ? const EmptyState(
              icon: Icons.pin_outlined,
              title: 'Belum ada mailbox aktif',
              subtitle: 'Buat alamat dulu di tab Beranda.')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Mailbox: ${appState.activeAddress}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _loadLatest,
                      icon: const Icon(Icons.refresh),
                      label: const Text('OTP terbaru'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 92,
                    child: TextField(
                      controller: _timeoutCtl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Timeout (dtk)', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _waiting ? null : _wait,
                      icon: _waiting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.hourglass_top),
                      label: const Text('Tunggu OTP'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                _otpCard('OTP terbaru', _latest),
                if (_waitResult != null) ...[
                  const SizedBox(height: 10),
                  _otpCard('Hasil tunggu OTP', _waitResult),
                ],
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Stream real-time (SSE)',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _toggleStream,
                            icon: Icon(_streaming ? Icons.stop : Icons.play_arrow),
                            label: Text(_streaming ? 'Berhenti' : 'Mulai stream'),
                          ),
                          if (_streamLog.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            for (final l in _streamLog.take(12))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(l,
                                    style: const TextStyle(
                                        fontFamily: 'monospace', fontSize: 12)),
                              ),
                          ],
                        ]),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Tunggu di banyak alamat',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _refsCtl,
                            maxLines: 3,
                            decoration: const InputDecoration(
                                labelText: 'Daftar ref (pisah baris/koma, maks 10)'),
                          ),
                          const SizedBox(height: 8),
                          Row(children: [
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(value: 'otp', label: Text('OTP')),
                                ButtonSegment(
                                    value: 'link', label: Text('Link')),
                              ],
                              selected: {_waitAnyMode},
                              onSelectionChanged: (v) =>
                                  setState(() => _waitAnyMode = v.first),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.tonal(
                                onPressed: _waitingAny ? null : _waitAny,
                                child: Text(_waitingAny
                                    ? 'Menunggu…'
                                    : 'Tunggu yang pertama datang'),
                              ),
                            ),
                          ]),
                          if (_waitAnyResult != null) ...[
                            const SizedBox(height: 10),
                            JsonView(_waitAnyResult),
                          ],
                        ]),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Link verifikasi / reset',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _verify(false),
                                child: const Text('Link terbaru'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton(
                                onPressed:
                                    _verifyWaiting ? null : () => _verify(true),
                                child: Text(_verifyWaiting
                                    ? 'Menunggu…'
                                    : 'Tunggu link'),
                              ),
                            ),
                          ]),
                          if (_verifyLatest != null) ...[
                            const SizedBox(height: 10),
                            _otpCard('Link terbaru', _verifyLatest, key: 'link'),
                          ],
                          if (_verifyWait != null) ...[
                            const SizedBox(height: 10),
                            _otpCard('Hasil tunggu link', _verifyWait, key: 'link'),
                          ],
                        ]),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            const Expanded(
                              child: Text('Riwayat OTP',
                                  style: TextStyle(fontWeight: FontWeight.w700)),
                            ),
                            TextButton(
                                onPressed: _loadHistory,
                                child: const Text('Muat')),
                            TextButton(
                              onPressed: () async {
                                final ok = await confirmDialog(context,
                                    title: 'Bersihkan riwayat OTP?',
                                    body: 'Riwayat OTP alamat ini dihapus.');
                                if (!ok) return;
                                await api.clearOtpHistory(ref);
                                setState(() => _history = null);
                              },
                              child: const Text('Bersihkan'),
                            ),
                          ]),
                          if (_history != null) JsonView(_history),
                        ]),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Uji ekstrak OTP dari teks',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _extractCtl,
                            maxLines: 3,
                            decoration: const InputDecoration(
                                labelText: 'Tempel isi email di sini'),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.tonal(
                              onPressed: _extract,
                              child: const Text('Ekstrak')),
                          if (_extractResult != null) ...[
                            const SizedBox(height: 10),
                            JsonView(_extractResult),
                          ],
                        ]),
                  ),
                ),
              ],
            ),
    );
  }
}
