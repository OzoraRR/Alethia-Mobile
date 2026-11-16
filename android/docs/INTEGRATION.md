# Android/backend integration

Updated 16 November 2026. See [native module implementation](MODULES.md).

## Implemented flow

The existing Compose screens use the same Supabase client as authentication. `AuthRepository` handles credentials and imports a complete user session after username login. `LearnerRepository` sends the caller JWT to Supabase REST/RPCs; no server secret is packaged in Android. `PracticeViewModel` exposes loading/error/data state, clears account data on logout/account changes, and handles account refreshes. `LearningViewModel` owns native lesson state, durable per-account recovery and completion retries. The SDK handles session persistence and refresh; REST requests retry once after refreshing an expired JWT.

| Feature | Backend boundary |
| --- | --- |
| Signup/email login | Supabase Kotlin Auth SDK |
| Username login | `/api/auth/username-login`, then retrieve the authenticated user before importing the session |
| Daily activity/streak | `record_daily_activity` with the device timezone; invoked on data refresh |
| Dashboard, module access, EXP, quests, achievements | `get_dashboard_state` |
| Quest reward | `claim_daily_quest` using assignment ID/date; no client points update |
| All three native modules | `open_learning_session`, `get_learning_sessions`, `save_learning_session`, then `complete_verified_practice_attempt`; no client-authored score |
| Reports | Community/personal feeds, cursor paging, sorting, owner-only create/edit/delete, and investigator signals/notes/verdicts through Supabase RLS/RPCs; summary counts remain exact |
| Notifications | Own notifications and `mark_notification_read` |
| Profile language | Own `profiles.preferred_locale` under RLS, mirrored to DataStore |
| Logout | Supabase Auth sign-out, then clear displayed account/practice state |

Daily quests are assigned automatically by the existing backend; they have no separate server-side acceptance operation. The signed-in UI treats assigned quests as accepted and offers claim only after reaching the server target. Credits are not part of the backend model, so connected quest cards show the existing EXP reward only. Server quest titles, descriptions and progress replace preview objectives. Preview data remains limited to guest/debug preview usage.

Failed writes keep the practice on its current step. Completing a server attempt is idempotent, so a lost completion response can be retried with the saved attempt ID. After completion, visible module completion is based on server access state, including the perfect-score requirement. Reports/notifications currently show the latest 100 personal rows; the report summary counts all personal rows. Recovery sessions use additive migration `20261116000000_learning_session_recovery.sql`, applied locally and to hosted.

## Run the matching environment

Open `android/` in Android Studio.

- Normal Run reads ignored `alethia.properties`, configured for hosted Supabase and, after the 16 November environment audit, the verified Vercel Production HTTPS API. This mode does not require a local API process. For API development against hosted Supabase, `pnpm dev:hosted` is still available; explicitly use `http://10.0.2.2:3002` in Android only when testing that local process. Docker being active does not change the Android profile automatically.
- For local Docker, run `pnpm db:start` and `pnpm dev:local` from `backend/`, then build with `./gradlew :app:assembleDebug -PalethiaConfig=alethia.local.properties` from `android/`.
- The local and hosted API processes both use port 3002; stop one before starting the other. Do not point the app at hosted Auth and a local-database username-login API.
- For a physical phone, the emulator host address is unsuitable; configure a reachable HTTPS API URL and the corresponding Supabase profile.

## Validation

By default, connected Android instrumentation creates synthetic accounts only against local Supabase. It exercises daily activity, exact report counts, idempotent claims, scoring at 75 and 100, idempotent completion, report submission, achievements, notification reads, persisted locale and data after username re-login. The Compose connected journey checks that username login renders real account data and logout returns to the landing page. Cleanup uses the existing account-deletion API. Guest journeys cover practice and recreation separately.

Two signed-in regression tests can opt in to Alethia Mobile hosted using `-PalethiaConfig=alethia.hosted.properties` and `-Pandroid.testInstrumentationRunnerArguments.alethiaHostedAudit=true`. They create synthetic accounts and clean them up through the existing Vercel account-deletion endpoint. CI uses the blank `alethia.properties.example` profile and does not opt in to hosted account creation.

```sh
# backend/: local Supabase must already be running
pnpm dev:local

# android/: running emulator required
./gradlew :core:test :app:lintDebug :app:connectedDebugAndroidTest -PalethiaConfig=alethia.local.properties
```

Validation on 15 November: Android 17 / 16 KB emulator, all 6 instrumentation tests passed against Docker local Supabase, JVM tests passed, and lint completed with zero errors. Synthetic test accounts were deleted.

Validation on 16 November: the Android CI-equivalent JVM tests, lint, debug APK build and Android 17 instrumentation task completed successfully. With the blank CI profile, 6 offline UI tests ran and 4 account-backed cases were not exercised. Hosted recovery and the signed-in three-module journey passed. The hosted journey also exercised report create/edit/delete, URL defanging, investigator signal/note/verdict writes and cleanup; temporary accounts and reports were deleted.

## Frontend features still to build

- Report screenshots are currently stored as inline data URLs with a 500 KiB image limit; Supabase Storage is the next step if larger attachments or higher volume are needed.
- Full profile editing, avatar controls, export/deletion UI and password recovery.
- Notification/achievement presentation refinement and pagination beyond the first 100 list rows.

The existing server APIs for some of these features are available, but their Android user flows do not exist yet. Hosted module RPC contracts have been checked with a temporary account; release configuration remains follow-up work.
