# Alethia Mobile: setup untuk rekan pengembang

Diperbarui 16 November 2026. Hasil audit ada di [ENVIRONMENT_AUDIT_2026-11-16.md](ENVIRONMENT_AUDIT_2026-11-16.md).

## Struktur proyek

Clone `https://github.com/OzoraRR/Alethia-Mobile.git`. Buka subfolder `android/` di Android Studio. Folder `backend/` adalah API Next.js dan skema Supabase; bukan UI web. Seluruh source Android sudah masuk `main` pada commit `e543ac9`.

Untuk frontend: Git, Android Studio, Android SDK Platform 37 / Build Tools 36.0.0, dan JDK 25 untuk konfigurasi Gradle proyek ini. Android Studio menghasilkan `android/local.properties` untuk lokasi SDK komputer masing-masing. Node.js 24.x, pnpm 12.17.0 dan Docker hanya diperlukan bila mengembangkan backend lokal.

## Pilihan A: frontend memakai staging hosted

Mode ini tidak membutuhkan Docker, login Supabase CLI, Vercel CLI, atau server API lokal untuk menjalankan aplikasinya.

1. Clone repo dan buka folder `android/` di Android Studio.
2. Tunggu Gradle Sync, instal SDK yang diminta, lalu pilih emulator atau ponsel.
3. Klik **Run app**. Tidak perlu mengisi file environment atau menyalin key.

Gradle otomatis memakai `android/config/hosted.properties` yang berisi URL dan publishable key publik. Ini mengarah ke `https://alethia-mobile-backend.vercel.app`. Jika pengembang sudah memiliki `android/alethia.properties`, profil lokal itu tetap diprioritaskan. `-PalethiaConfig=...` memilih profil eksplisit dan gagal dengan pesan jelas bila file tidak ada. Environment variable masih memiliki prioritas tertinggi; gunakan ketiga nilai dari target yang sama.

URL API di atas adalah domain tetap Vercel Production, dikonfigurasi dan diuji dengan akun sementara pada 16 November. Backend ini masih memakai Supabase Alethia Mobile yang sama dengan staging. Email confirmation masih dimatikan sesuai keputusan pengembangan; label Production Vercel tidak berarti seluruh produk sudah siap dirilis.

## Pilihan B: mengembangkan full stack dengan Docker lokal

Dari `backend/`:

```sh
pnpm install --frozen-lockfile
pnpm db:start
pnpm exec supabase status
```

Pada komputer baru, Supabase menyiapkan stack beserta migrasi. Untuk stack yang sudah ada, periksa riwayat migrasinya sebelum mengubah skema. `pnpm db:reset` menghapus data lokal dan bukan perintah start harian.

Salin `backend/.env.example` menjadi `backend/.env.local`, lalu isi dari status stack lokal:

- `NEXT_PUBLIC_SUPABASE_URL`: API URL lokal, biasanya `http://127.0.0.1:54321`.
- `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`: publishable key lokal.
- `SUPABASE_SECRET_KEY`: secret key lokal, hanya di backend.

Salin `android/alethia.properties.example` menjadi `android/alethia.local.properties`:

- `ALETHIA_SUPABASE_URL=http://10.0.2.2:54321`.
- `ALETHIA_SUPABASE_PUBLISHABLE_KEY`: public key dari stack lokal yang sama.
- `ALETHIA_API_BASE_URL=http://10.0.2.2:3002`.

Jalankan API dari `backend/`:

```sh
pnpm dev:local
```

Build dari `android/`:

```sh
./gradlew :app:assembleDebug -PalethiaConfig=alethia.local.properties
```

Agar tombol Run Android Studio memakai mode lokal, salin isi profil lokal ke `android/alethia.properties`. Simpan profil hosted secara terpisah agar mudah berpindah. Ponsel fisik memerlukan alamat host yang dapat diakses dan kebijakan jaringan debug yang sesuai; `10.0.2.2` khusus emulator.

## Pemeriksaan sebelum mengirim perubahan

Dari `backend/`: `pnpm lint`, `pnpm typecheck`, `pnpm test`, `pnpm build`, `pnpm db:test`, dan `bash scripts/test-local-auth.sh`. Perintah database tersebut memakai Docker lokal; tidak perlu login hosted.

Dari `android/`: `./gradlew :core:test :app:lintDebug :app:assembleDebug`. Pengujian perangkat yang terhubung memerlukan emulator dan, untuk tes integrasi lokal, API lokal: `./gradlew :app:connectedDebugAndroidTest -PalethiaConfig=alethia.local.properties`.

## Akses tim dan konfigurasi

Gunakan akun GitHub, Supabase, dan Vercel milik masing-masing pengembang. Pemilik proyek memberikan akses kolaborator sesuai pekerjaan yang perlu dilakukan. Akses clone repo publik tidak otomatis memberi izin push atau akses dashboard provider. Login CLI pemilik proyek di workstation ini tidak dibawa oleh clone GitHub.

Berkas `.env*`, profil `alethia*.properties` lokal, `local.properties`, token CLI dan signing key diabaikan Git. Pengecualiannya adalah `android/config/hosted.properties`, yang sengaja disertakan karena hanya berisi konfigurasi publik untuk aplikasi. Server secret tidak dimasukkan ke Android atau Git. CI dapat membangun tanpa kredensial hosted; tes integrasi Android hosted dilewati oleh guard hostname.

## Lingkup pekerjaan yang masih terbuka

Lihat [integrasi Android](../android/docs/INTEGRATION.md). Dua simulasi selain Courier masih placeholder. Profil lengkap, report editing/deletion/pagination, avatar, dan pemulihan password belum selesai. Production Vercel sudah terkonfigurasi dan dipakai profil Android hosted/default. Database Supabase masih menjadi target pengembangan bersama, sehingga kesiapan rilis tetap perlu ditinjau.
