# Alethia Mobile — Android

The native Android app includes Compose landing/login/register, ID/EN preferences, an account-backed dashboard, and Courier SMS training. Signed-in dashboard names, streaks, EXP, daily quests, achievements, notifications and report counts come from Supabase. Verified training attempts and quest rewards are computed by server RPCs. Guest training remains offline. Reports support a basic SMS phishing submission and personal list; profile supports language and logout. Social engineering and malicious-document training remain frontend placeholders. See [integration details](docs/INTEGRATION.md).


## Start now

On the current workstation, `local.properties` has already been configured with the installed SDK path. Android Studio and an Android SDK/emulator are already installed. The app can use either hosted Supabase or the local Docker stack.

From this directory:

```sh
./gradlew :core:test :app:lintDebug :app:assembleDebug
```

The debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`. Install/run the `app` configuration from Android Studio, or use `adb install -r app/build/outputs/apk/debug/app-debug.apk` with an emulator/device connected.

The checked-in Gradle wrapper supplies Gradle; a separate system Gradle installation is not required. This workstation builds using its installed JDK 25. For a different machine or CI, use JDK 17 or a supported newer JDK and configure Android Studio's Gradle JDK accordingly. No global Java settings were changed.

For another workstation, install Android SDK Platform 37 and Build Tools 36.0.0, accept the SDK licenses, and let Android Studio write `local.properties` (or set `ANDROID_HOME`). API 37 is needed to compile the selected Compose dependencies. The app still targets API 36 and supports Android 8.0/API 26 and later.

## CI and release status

The Android GitHub Actions workflow in this checkout runs JVM tests, Android lint, Android 17 instrumentation tests, and a debug APK build when Android source or Gradle configuration changes. It uploads the APK as a short-lived build artifact. The workflow and Android source have not yet been pushed to GitHub, so these checks have not run there. The active `Protect Main` ruleset already requires `Required Android checks`; verify that status in GitHub after the planned push/PR. Release signing and store deployment are not configured yet.

See [the architecture baseline](docs/ARCHITECTURE.md) for where to make UI, domain, and future data-layer changes.

## Local account integration

Android Studio's default `alethia.properties` now points to the hosted Supabase project. The previous local settings are preserved in the ignored `alethia.local.properties` file. To configure another Android emulator for the local stack:

```properties
ALETHIA_SUPABASE_URL=http://10.0.2.2:54321
ALETHIA_SUPABASE_PUBLISHABLE_KEY=<local publishable key>
ALETHIA_API_BASE_URL=http://10.0.2.2:3002
```

Start Supabase from `../backend` with `pnpm db:start`. Set the ignored `.env.local` using the local API URL and keys reported by `pnpm exec supabase status`, then run `pnpm dev:local`. To build against local Supabase, select `alethia.local.properties` with `-PalethiaConfig=alethia.local.properties`. The emulator reaches the host through `10.0.2.2:3002`.

All local properties files are ignored by Git. Only a public/publishable or legacy anon key belongs in Android; the backend secret key stays in the backend environment file. Gradle rejects recognizable Supabase secret/service-role keys in the Android public-key field. The debug network policy allows cleartext only to the emulator host; release builds keep cleartext disabled. For a physical device, configure a reachable host address and an explicit debug network-security entry.

## Hosted Supabase profile

The hosted project `Alethia Mobile` is in Singapore and uses ref `zbeaiphxmmwutzmqydlk`. All 50 repository migrations are applied, including the migration that narrows public profile fields. The ignored `alethia.properties` and `alethia.hosted.properties` files contain only the hosted URL and publishable key. Android Studio's normal **Run app** action now uses the hosted project. Build a debug APK explicitly against that profile with:

```sh
./gradlew :app:assembleDebug -PalethiaConfig=alethia.hosted.properties
```

Run the backend from `../backend` with `pnpm dev:hosted`; that loads `.env.hosted.local` and serves port `3002`, which the Android emulator reaches at `10.0.2.2:3002`. The local Docker Supabase configuration remains available through `alethia.local.properties` and `pnpm dev:local`. Hosted email sign-up now creates a session immediately, with no confirmation email step.

Local and hosted Supabase email confirmation are disabled for the current test setup. Supabase Auth stores the email and password credential, while the signup trigger copies the submitted username and email into `public.profiles`. Passwords are never copied into the profile table or stored as plaintext.

## Configuration needed before publishing

- Choose the permanent application ID. `dev.alethia.mobile` is a provisional development ID; debug builds add `.debug`.
- Configure the release signing key and its ownership using Android Studio or CI secrets. No release signing key is generated or committed here.
- Choose the production email-verification policy and configure the corresponding redirect/App Links before release.

None of those release decisions block local development or a debug build.

## Tests

```sh
./gradlew :core:test
./gradlew :app:connectedDebugAndroidTest
```

The device tests require a running emulator/device. Guest tests cover scores of 100/75, activity recreation and language persistence. Connected tests additionally exercise the actual username-login UI and the learner repository against local Docker Supabase. Connected tests skip hosted/empty profiles and delete only their own synthetic accounts. Run the API with `pnpm dev:local` before using `-PalethiaConfig=alethia.local.properties`.

Verified locally on 5 November 2026: debug APK assembled, all 8 JVM tests and 4 Android 17 emulator tests passed, and Android lint reported zero errors (8 advisory warnings). On 12 November 2026, the connected-auth debug APK assembled successfully, the backend typecheck passed, and the app was installed and opened on the emulator at the sign-in screen. No account credentials were entered. The app was also checked on the 16 KB emulator without a compatibility dialog; APK ZIP alignment and both 64-bit ABIs' native library load/RELRO layouts were checked. Older supported Android versions and release signing still need release validation.

Offline results are clearly marked as local practice. They do not award account points or unlock server-controlled modules. Saved activity state handles recreation; durable cross-restart learning history and the Room/WorkManager synchronization queue belong to the next integration phase.

## Tool versions

| Tool | Version |
| --- | --- |
| Android Gradle Plugin | 9.4.1 |
| Gradle | 9.6.0, wrapper checksum pinned |
| Kotlin / Compose compiler | 2.4.10 |
| Compose BOM | 2026.09.00 |
| DataStore | 1.3.0 |
| Graphics Path | 1.1.0 |
| Compile / target / minimum SDK | 37 / 36 / 26 |
| JVM bytecode target | 17 |

The theme reuses Alethia's existing color tokens and Courier artwork. The simulator's decision IDs and level thresholds match the existing backend contracts. See the full [migration plan](docs/KOTLIN_MIGRATION_PLAN.md).

DataStore 1.3.0 replaces the initial 1.2.0 dependency after testing exposed an Android 17 16 KB page-size compatibility warning. Graphics Path is explicitly upgraded to 1.1.0 rather than using Compose's older transitive dependency. See the official [DataStore release notes](https://developer.android.com/jetpack/androidx/releases/datastore), [Graphics release notes](https://developer.android.com/jetpack/androidx/releases/graphics), and [16 KB compatibility guidance](https://developer.android.com/guide/practices/page-sizes).
