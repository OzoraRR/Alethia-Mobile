# Audit lingkungan Alethia Mobile — 16 November 2026

## Hasil

| Area | Bukti pemeriksaan | Status |
| --- | --- | --- |
| Git | `main` lokal sama dengan `origin/main`, commit `e543ac9`; fetch berhasil | Aktif |
| GitHub | API mengenali akun OzoraRR, izin admin/push tersedia; ruleset kosong sesuai keputusan pemilik | Aktif |
| CI GitHub | Android build/lint/JVM dan instrumentation berhasil pada `e543ac9`; summary API/database berhasil tetapi job utamanya dilewati karena scope perubahan | Tidak ada kegagalan CI terakhir |
| Supabase CLI | CLI proyek versi 3.1.0 berhasil membaca projects list dan migrasi remote | Sesi masih valid |
| Supabase hosted | Alethia Mobile, ref `zbeaiphxmmwutzmqydlk`, ACTIVE_HEALTHY, 50 migrasi sama dengan repo, SSL database aktif | Staging aktif |
| Docker Supabase | Database, Auth, REST, Storage, Studio dan layanan terkait berjalan; 50 migrasi lokal | Aktif |
| Vercel CLI | Versi 65.15.0 mengenali ozorarr dan dapat membaca project/env/deployments | Sesi masih valid |
| Vercel Preview | Deployment `pskr8kzw0`: health 200, username sintetis yang tidak ada menghasilkan generic 401 | API staging merespons |
| Vercel Production | Awalnya `nuvydovip` login 503; pemilik menambahkan environment dan redeploy `crj4cto9s`. Akun sementara melalui domain tetap lulus registrasi/login/data/delete | Kendala terselesaikan |
| Toolchain | Node 24.22.2, pnpm 12.17.0; Android build dengan JDK proyek berhasil | Sesuai |
| Konfigurasi Git | Tidak ada `.env` aktual, konfigurasi lokal Android atau signing material yang ter-track | Pemeriksaan nama berkas bersih; pencarian nilai secret backend saat ini pada file ter-track juga tidak menemukan kebocoran |

Tidak dibutuhkan login ulang untuk provider yang diperiksa. `gh`, `vercel`, dan `supabase` tidak terpasang global; GitHub diakses melalui Git/REST dengan credential helper, Supabase melalui `pnpm exec`, Vercel melalui CLI versi terpin `pnpm dlx`. Ini bukan kegagalan autentikasi.

## Kendala dan penanganan

1. API mobile port 3002 mati pada awal audit. API `pnpm dev:hosted` telah dijalankan kembali; health 200 dan unknown-username 401 membuktikan jalur Auth/limiter dapat dijangkau. Proses dev perlu dijalankan lagi setelah restart bila masih diperlukan untuk mengembangkan API lokal.
2. Konfigurasi Android hosted sebelumnya menunjuk API emulator `10.0.2.2:3002`. Profil default dan hosted sempat diarahkan ke Preview; setelah konfigurasi Production oleh pemilik, keduanya sekarang memakai domain tetap `https://alethia-mobile-backend.vercel.app`, agar menjalankan aplikasi tidak membutuhkan server API di laptop pemilik. `alethia.local.properties` tetap menggunakan stack Docker lokal. Berkas profil ini diabaikan Git; rekan pengembang mengikuti [HANDOFF.md](HANDOFF.md).
3. Dua file tes database (`005` dan `008`) mengasumsikan koleksi laporan kosong. Pada stack developer dengan 5 laporan existing, 10 assertion gagal. Fixture sekarang diisolasi dengan truncate di dalam transaksi tes yang di-rollback. Setelah perbaikan, 313/313 assertion lolos dan jumlah laporan existing tetap 5. Tidak ada reset database, migrasi hosted, atau penghapusan permanen laporan dilakukan.
4. Ada container `alethia-alethia-1` pada port 3001 yang berasal dari compose `/lab/projects/Alethia/compose.yaml`. Itu bukan API proyek mobile ini. Dibiarkan berjalan karena berasal dari proyek lain; jangan gunakan sebagai bukti bahwa API mobile port 3002 aktif.
5. Kendala Production telah terselesaikan oleh pemilik: tiga environment Supabase ditambahkan dan deployment ulang berhasil. Pengujian lanjutan memakai domain Production dan database Alethia Mobile yang sama. Tidak membuat database baru atau mengubah kebijakan cabang release.
6. Dokumen lama masih menyebut Android belum di GitHub, ruleset wajib aktif, dan deployment otomatis belum terbukti. Temuan audit ini beserta pembaruan README/deployment menggantikan status historis tersebut untuk serah terima.

## Validasi lokal saat audit

- Backend: ESLint, TypeScript, 12 unit/contract tests, production build berhasil; satu tes local Auth sengaja dilewati oleh default unit command dan kemudian dijalankan terpisah, berhasil.
- Database: seluruh 19 file / 313 assertion pgTAP berhasil setelah perbaikan fixture; seluruh 50 migrasi lokal dan hosted cocok.
- Android: 8 JVM tests, lint dan debug APK berhasil. Lint menghasilkan 67 warning yang masih perlu ditinjau; tidak ada error.
- Emulator tidak aktif saat audit; instrumentation tidak diulang hari ini. GitHub Android instrumentation terakhir berhasil; pengujian full stack lokal pada 15 November tercatat di dokumen integrasi.
- Pemeriksaan awal hosted hanya memakai health/unknown username. Atas permintaan berikutnya, dilakukan pengujian akun sementara hosted seperti dirinci di bawah; data pengguna lain tidak diubah.

## Sebelum serah terima

Commit dan push perubahan audit/fixture ini setelah ditinjau pemilik. Berikan rekan akses repo/provider sesuai perannya serta konfigurasi public staging atau instruksi Docker lokal. Setup workstation baru tidak membutuhkan token CLI milik pemilik. Android dibuka melalui `android/`, backend dijalankan dari `backend/`.

## Pengujian akun sementara hosted setelah konfigurasi Production

Atas permintaan pemilik, diuji Supabase `zbeaiphxmmwutzmqydlk` dengan API `https://alethia-mobile-backend.vercel.app`. Kedua profil Android hosted/default sudah memakai URL tersebut dan APK berhasil dibangun ulang.

Semua langkah berikut lolos: signup langsung memperoleh sesi; login username melalui Production (termasuk normalisasi huruf besar), token mengarah ke identitas yang sama dan respons no-store; password salah ditolak 401; dashboard dan aktivitas harian; klaim quest yang diulang tidak menggandakan poin; skor latihan server 100 dan retry completion tidak menggandakan reward; kirim/baca laporan milik sendiri; achievement dan notifikasi; simpan bahasa, refresh token, logout dan login ulang dengan data tetap tersimpan.

Pembersihan: laporan sintetis dihapus lebih dahulu agar tidak tersisa sebagai laporan anonim, lalu akun dihapus melalui `/api/auth/delete-account` Production (HTTP 200). Verifikasi admin menunjukkan Auth user 404 serta tidak ada profil, laporan, attempt, notifikasi, quest atau achievement milik akun uji. Login username setelah penghapusan ditolak 401. Akun dan kredensial uji tidak dicatat di repo.

Pengujian hosted dilakukan melalui endpoint yang digunakan aplikasi, bukan interaksi layar Android. Emulator tidak aktif pada sesi ini; validasi UI perangkat tetap mengikuti hasil instrumentation sebelumnya.
