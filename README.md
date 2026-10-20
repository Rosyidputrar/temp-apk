# TempMail (Aplikasi Android)

Klien Flutter untuk [rest-tempmail](https://github.com/seseegy/rest-tempmail) —
REST API tempmail pribadi di Cloudflare Workers. Semua endpoint API dipakai:
mailbox, inbox, OTP (terbaru/tunggu/stream/riwayat/ekstrak), link verifikasi,
favorit, varian titik/plus + Gmail, alias.md, domain, riwayat, pantauan &
notifikasi, debug, dan admin.

## Keamanan token

Token API **tidak ada di kode**. Ia disuntik saat build:

```bash
flutter build apk --release \
  --dart-define=API_BASE=https://rest-tempmail.rosdiyttaa.workers.dev \
  --dart-define=API_TOKEN=<token>
```

Di GitHub Actions, token dibaca dari **Secrets** repo (`API_TOKEN`).

## Secrets yang dibutuhkan (Settings → Secrets and variables → Actions)

| Nama | Isi |
|---|---|
| `API_TOKEN` | Token API rest-tempmail |
| `KEYSTORE_BASE64` | Keystore release ter-encode base64 |
| `KEYSTORE_PASSWORD` | Password keystore |

## Build lokal

```bash
flutter pub get
flutter analyze && flutter test
flutter build apk --release --split-per-abi \
  --dart-define=API_TOKEN=<token>
```

Tanpa `android/key.properties`, APK release ditandatangani dengan kunci
debug (cukup untuk dicoba sendiri). CI selalu memakai keystore dari Secrets.

Paket: `com.rosdie.tempmail` • Min SDK 24 • Flutter 3.47.7
