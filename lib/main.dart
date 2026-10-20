// TempMail — klien mobile untuk rest-tempmail (API pribadi Mas Rosyid).
// Token & base URL disuntik saat build via --dart-define (GitHub Secrets di CI).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'screens_main.dart';
import 'screens_otp.dart';
import 'screens_more.dart';

final api = TempmailApi();

class AppState extends ChangeNotifier {
  String? activeRef;
  String? activeAddress;

  // Simpan state di file JSON kecil (pengganti shared_preferences yang
  // versi native-nya bentrok di perangkat: NoSuchMethodError getAll).
  Future<File> _stateFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/tempmail_state.json');
  }

  Future<void> load() async {
    try {
      final f = await _stateFile();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        activeRef = m['ref'] as String?;
        activeAddress = m['address'] as String?;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final f = await _stateFile();
      if (activeRef == null) {
        if (await f.exists()) await f.delete();
      } else {
        await f.writeAsString(jsonEncode(
            {'ref': activeRef, 'address': activeAddress}));
      }
    } catch (_) {}
  }

  Future<void> setActive(String ref, String address) async {
    activeRef = ref;
    activeAddress = address;
    notifyListeners();
    await _save();
  }

  Future<void> clearActive() async {
    activeRef = null;
    activeAddress = null;
    notifyListeners();
    await _save();
  }
}

final appState = AppState();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // JANGAN await apa pun sebelum runApp: frame pertama harus digambar dulu.
  // (Await SharedPreferences di sini pernah bikin layar hitam permanen.)
  // ignore: unawaited_futures
  appState.load().timeout(const Duration(seconds: 5),
      onTimeout: () {}).catchError((_) {});
  ErrorWidget.builder = (details) {
    return const Material(
      color: Colors.white,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Colors.red, size: 40),
              SizedBox(height: 12),
              Text(
                'Ada kendala kecil. Coba kembali lalu buka lagi ya.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black87, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  };
  runApp(const TempMailApp());
}

class TempMailApp extends StatelessWidget {
  const TempMailApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2563EB),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2563EB),
      brightness: Brightness.dark,
    );
    ThemeData theme(ColorScheme s) => ThemeData(
          useMaterial3: true,
          colorScheme: s,
          scaffoldBackgroundColor: s.surface,
          appBarTheme: AppBarTheme(
            backgroundColor: s.surface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            titleTextStyle: TextStyle(
              color: s.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          cardTheme: CardThemeData(
            elevation: 0,
            color: s.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: s.outlineVariant),
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 44),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: s.surfaceContainerLowest,
          ),
          navigationBarTheme: NavigationBarThemeData(
            height: 64,
            labelTextStyle: WidgetStatePropertyAll(
                TextStyle(fontSize: 12, color: s.onSurface)),
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
    return MaterialApp(
      title: 'TempMail',
      debugShowCheckedModeBanner: false,
      theme: theme(scheme),
      darkTheme: theme(darkScheme),
      themeMode: ThemeMode.system,
      home: const Shell(),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      const HomeScreen(),
      const InboxScreen(),
      const OtpScreen(),
      const FavoritesScreen(),
      const MoreScreen(),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Beranda'),
          NavigationDestination(
              icon: Icon(Icons.inbox_outlined),
              selectedIcon: Icon(Icons.inbox),
              label: 'Inbox'),
          NavigationDestination(
              icon: Icon(Icons.pin_outlined),
              selectedIcon: Icon(Icons.pin),
              label: 'OTP'),
          NavigationDestination(
              icon: Icon(Icons.star_outline),
              selectedIcon: Icon(Icons.star),
              label: 'Favorit'),
          NavigationDestination(
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view),
              label: 'Menu'),
        ],
      ),
    );
  }
}

// ---------- util bersama ----------
void showError(BuildContext context, Object e) {
  final msg = e is ApiException ? e.message : e.toString();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: Theme.of(context).colorScheme.error,
  ));
}

void showOk(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  String confirmLabel = 'Hapus',
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal')),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Penampil JSON rapi untuk hasil debug/admin/mentah.
class JsonView extends StatelessWidget {
  final dynamic value;
  const JsonView(this.value, {super.key});

  String _pretty(dynamic v) {
    try {
      return const JsonEncoder.withIndent('  ').convert(v);
    } catch (_) {
      return v.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectableText(
        _pretty(value),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  const EmptyState(
      {super.key, required this.icon, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: s.outline),
            const SizedBox(height: 12),
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!,
                  style: TextStyle(color: s.onSurfaceVariant),
                  textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}
