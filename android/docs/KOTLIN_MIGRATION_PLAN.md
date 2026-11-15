# Alethia Kotlin/Gradle migration plan

Prepared 5 November 2026 from the current repository and the completed local security repairs. The phases below describe the full Android migration; implementation progress is recorded in the update immediately below.

**Implementation update:** the native foundation in [native project](../README.md) now includes theme, bilingual navigation, a complete offline Courier SMS practice, domain/device tests, and the first connected account slice. Compose login/sign-up uses `AuthViewModel`, `AuthRepository`, Supabase Kotlin Auth, a backend username-login endpoint, and an Android Keystore-encrypted session manager. Local Supabase/API configuration is in ignored developer files. The hosted Supabase project and a manual Vercel Preview API are configured; Vercel does not yet deploy from GitHub automatically. The selected Compose libraries require compile SDK 37, with target SDK 36 and minimum SDK 26. Server-backed dashboard data and the learning sync journey remain next.

## Recommended approach

The native Android learner app in Kotlin with Jetpack Compose and Gradle Kotlin DSL lives in `android/`. Reuse Supabase Auth, PostgreSQL, Storage, migrations, and the corrected RPC contracts from `backend/`. Keep the API handlers for username login and account deletion in the backend for the first Android release.

The migration replaces the learner interface and browser-specific persistence. Existing server-side scoring, ownership checks, moderation rules, quest awards, and account identity remain authoritative. Existing users sign in to the same accounts and receive their existing server progress.

Deliver one complete journey first: sign in, view the dashboard, finish Courier SMS, synchronize the result, and observe Social Engineering unlock. Use that journey to validate the architecture before porting every screen.

## Scope and decisions

| Topic | Proposed decision |
| --- | --- |
| Platform | Android first. This plan does not include an iOS implementation. |
| Native UI | Jetpack Compose, Material 3 components adapted to Alethia's colors, typography, and training layouts. |
| Structure | One Android application module plus a Kotlin/JVM domain module. Organize features into packages before considering more Gradle modules. |
| Backend | Reuse the corrected Supabase schema and RPCs. Preserve the existing server endpoints for privileged operations. |
| Account migration | Same Supabase project and user IDs when moving to production. No password copying or account recreation. |
| Guest experience | Courier practice works locally. A permanent account is required for account features and server-confirmed progression. |
| Progress authority | Local results are practice history; server results control unlocks, points, roles, and quests. |
| Languages | Indonesian by default, English available. Both languages ship with the app. |
| Offline behavior | Packaged lessons, recoverable simulation state, cached account data, and a durable completion queue. Community writes require connectivity in the first release. |
| Notifications | Preserve in-app notifications initially. Push notifications are a separate feature requiring backend delivery work. |
| Admin tools | Continue using the existing web operator console. |
| Design | Preserve Alethia's identity while adapting touch targets, scrolling, Back behavior, keyboard handling, and system insets to Android. |

Minimum supported Android version is provisionally Android 8.0/API 26. This matches the documented baseline of the Supabase Kotlin client without requiring additional desugaring configuration; support for older devices should be a deliberate audience decision. [Supabase Kotlin installation](https://supabase.com/docs/reference/kotlin/installing).

## What is reused and what is rebuilt

| Existing source | Android treatment |
| --- | --- |
| `supabase/migrations/` and `supabase/tests/` | Reuse. Validate the repaired migration against isolated services before connecting the Android client. |
| `app/api/auth/username-login/route.ts` | Reuse as an HTTPS backend endpoint. Import its returned session into the native Auth client. |
| `app/api/auth/delete-account/route.ts` and `lib/auth/delete-account.ts` | Reuse as an HTTPS backend endpoint, called with the learner's access token. |
| `app/api/admin/`, `features/admin/`, and `lib/admin/` | Keep hosted for the web console. |
| `features/*/simulation-machine.ts` | Translate transitions into pure Kotlin reducers with immutable state and typed actions. |
| `features/modules/scoring.ts`, `features/modules/access-rules.ts`, and `features/progress/levels.ts` | Port display calculations and their test examples; server values remain authoritative. |
| `features/progress/completion-queue.ts` and `supabase-persistence.ts` | Preserve the corrected behavior using Room transactions and WorkManager. |
| `messages/id.json` and `messages/en.json` | Reuse the content. Convert interface strings to Android resources and structured lesson content to packaged localized data. |
| `app/`, React components, Tailwind, and `globals.css` | Rebuild with Compose. Translate design tokens rather than copying CSS or JSX. |
| `public/media/` | Reuse suitable WebP images. Evaluate SVG conversion and replace or adapt web animations where needed. |
| `public/fonts/*.woff2` | Obtain the corresponding Android-compatible font files and preserve license notices; WOFF2 files are web assets. |
| `localStorage`, browser events, cookies, and DOM APIs | Replace with native storage, lifecycle handling, navigation, and Auth session management. |
| Node and database tests | Keep backend and SQL regression checks in `backend/`. Port relevant learner-flow cases into Kotlin and Compose tests. |

## Architecture

Use a single-activity app with screen-level ViewModels. Compose renders immutable `UiState`, and actions flow through ViewModels into repositories. Repositories coordinate Supabase, local storage, and the hosted application API. Keep simulation rules independent of Android so they can be tested on the JVM. This follows [Android's architecture recommendations](https://developer.android.com/topic/architecture/recommendations).

```text
Compose screens
      |
Screen ViewModels + StateFlow
      |
Repositories ---------------------- Kotlin domain reducers and models
      |
      +-- Supabase Auth / Data API / RPCs / Storage
      +-- Hosted username-login and account-deletion endpoints
      +-- Room: attempts, pending completions, account-scoped caches
      +-- DataStore: locale and non-sensitive preferences
      +-- Session storage backed by Android Keystore encryption

WorkManager -> pending-completion repository -> verified completion RPC
```

Android app layout:

```text
android/
  settings.gradle.kts
  build.gradle.kts
  gradle/libs.versions.toml
  gradle/wrapper/
  gradlew
  gradlew.bat
  core/
    src/main/kotlin/.../domain/
      simulation/
      progress/
      models/
    src/test/kotlin/
  app/
    build.gradle.kts
    src/main/
      AndroidManifest.xml
      kotlin/.../
        app/                 # Application, dependency container, navigation
        data/auth/
        data/supabase/
        data/local/
        data/repositories/
        data/sync/
        ui/theme/
        feature/auth/
        feature/dashboard/
        feature/training/
        feature/simulation/
        feature/reports/
        feature/profile/
        feature/insights/
      res/values/
      res/values-en/
      assets/lessons/
    src/test/
    src/androidTest/
```

Start with a small application-owned dependency container. Introduce a DI framework only if construction complexity warrants it. Use repository interfaces to substitute deterministic fakes in tests.

## Build and tooling

The following is a proposed starting matrix, subject to the Phase 1 build gate. It is not a claim that an Android build has already passed.

| Setting | Proposed baseline |
| --- | --- |
| Build scripts | Kotlin DSL and a checked-in Gradle wrapper with distribution checksum. |
| Android Gradle Plugin | Pin a stable 9.4.x patch; 9.4.1 is already cached locally. |
| Gradle | 9.6.0, matching the documented AGP 9.4 requirement and a local cached distribution. |
| Java | Pin JDK 17 for CI and Java/Kotlin bytecode compatibility. Evaluate the existing local JDK 25 runtime during the build check. |
| Kotlin | Candidate 2.4.10, with matching Compose compiler and serialization plugin versions. Explicitly align AGP's built-in Kotlin dependency when selecting a higher Kotlin version. |
| Compose libraries | Pin a stable Compose BOM. The current setup guide uses 2026.09.00; confirm the final dependency set during Phase 1. |
| Android SDK | Begin with compile SDK 36, target SDK 36, min SDK 26. Raise compile SDK if a chosen stable library requires it. Recheck target requirements before release. |
| Native network client | Supabase Kotlin BOM, Auth, PostgREST, Storage, and a compatible Ktor engine. Add Realtime when implementing notifications. |
| Persistence and retry | Room, DataStore, WorkManager. Pin compatible stable versions together. |
| Navigation | Typed destinations using the current stable Jetpack navigation approach validated in the foundation build. |
| Build environments | Debug/staging/release configuration with separate backend URLs and public keys. |
| Outputs | Debug APK for development; signed AAB for distribution. |

[AGP 9.4 compatibility](https://developer.android.com/build/releases/agp-9-4-0-release-notes) lists Gradle 9.6.0, build tools 36.0.0, minimum JDK 17, and support through API 37. AGP 9 provides [built-in Kotlin support and a documented higher-KGP override](https://developer.android.com/build/releases/agp-9-0-0-release-notes); do not blindly apply an older Android Kotlin plugin template. The [Compose setup guide](https://developer.android.com/develop/ui/compose/setup-compose-dependencies-and-compiler) ties its compiler plugin to the selected Kotlin version.

The checked [Google Play requirement](https://developer.android.com/google/play/requirements/target-sdk) requires new phone apps and updates to target API 36 or higher. This should be checked again when preparing the actual release.

Local inventory: Android Studio is present under `/opt/android-studio`; SDK platforms 36 and 37.0 and build tools 35.0.0/36.0.0 are installed under `/home/ranath/Android/Sdk`. Gradle 8.13, 9.5.0, and 9.6.0 distributions are cached. A Pixel 4a emulator configuration exists. Java 11 and 25 are present; Java 17 was not found in the inspected JDK directory. `ANDROID_HOME` and `JAVA_HOME` were unset, and Android command-line tools were not found in the usual SDK directory. Configure project-specific paths/tooling as needed during Phase 1. [Gradle documents Java 25 runtime support from 9.1 onward](https://docs.gradle.org/current/userguide/compatibility.html), but the complete Android/plugin combination still needs its own build check.

## Screen migration map

| Web route or feature | Native destination | Main behavior to preserve |
| --- | --- | --- |
| `/` | Welcome | Product explanation, language selection, start practice or sign in. |
| `/login` | Sign in / registration | Username or email login, registration validation, confirmation-required states, return destination. |
| `/dashboard` | Dashboard tab | Authoritative progress, daily activity, quests, points, module shortcuts. |
| `/training` | Training tab | Published catalog, locked/available/in-progress/completed states, resume and review. |
| `/simulation/courier-sms` | Courier simulation | Inspection, comparison, assessment, verification, decision, reveal, result and retry. |
| `/simulation/social-engineering` | Reconstruction simulation | Artifact selection, extraction, pretext, mitigation, unscored completion. |
| `/simulation/executable-file` | Document simulation | File-field inspection, official-channel verification, decision, explanation and result. |
| `/reports` | Reports tab | Stable pagination, sort/scope filters, create/edit/delete owned reports. |
| `/reports/[id]` | Report detail | Evidence, anonymized authors, signals, votes, reasons, notes, exact vote totals. |
| `/profile/[username]` | Public profile | Public read of username, module progress, mastery, and selected badges; report and investigation activity is omitted. |
| `/profile` | Profile tab | Identity, level, role, social links, account actions, local-data controls. |
| `/profile/edit` | Profile editor | Username, password, avatar, selected badges, local social links. |
| `/insights` | Insights tab | Achievements, practice activity, points level and mastery presentation. |
| Notification bell | In-app notification surface | Unread items, mark read, route to the relevant module/report/achievement. |
| `/admin` | Existing web console | Operator login, moderation, quests and audit behavior stay hosted. |

Use the same five main destinations: Dashboard, Training, Reports, Insights, Profile. Simulations and details sit under their parent destination. Preserve a requested authenticated destination across sign-in using typed internal routes. Validate external links and identifiers before navigating.

## Backend contracts

Create serializable transport DTOs separate from domain/UI models. Direct table rows use snake_case, while dashboard JSON includes camelCase fields. Preserve null scores for Social Engineering, nullable report owners, timestamp precision for report cursors, and stable module/achievement identifiers. Capture sanitized staging responses as contract fixtures before implementing DTO decoding.

| Capability | Existing backend contract |
| --- | --- |
| Email sign-in and registration | Supabase Auth; registration metadata includes `username`. |
| Username sign-in | `POST /api/auth/username-login` with `username` and `password`; returns `access_token` and `refresh_token`. Use an absolute configured HTTPS application API URL. |
| Session | Native Auth client session import/refresh and verified user lookup. Browser cookies are not the Android session store. |
| Dashboard | `record_daily_activity(requested_timezone)` followed by `get_dashboard_state()`. Send an IANA timezone identifier. |
| Catalog/access | Published `modules` rows and `get_verified_module_access()`. |
| Attempt creation | `begin_verified_practice_attempt(requested_module_id)`. |
| Completion | `complete_verified_practice_attempt(requested_attempt_id, requested_decisions)`. Repeating a completed attempt returns the original result after the repair migration. |
| Review | `get_module_result(requested_module_id)`. |
| Coarse events | Owned `practice_events` inserts with allowed event types; no evidence text or personal inputs in metadata. |
| Quests | `claim_daily_quest(requested_quest_id, requested_quest_date)`. |
| Notifications | Owned `notifications` reads and `mark_notification_read(requested_notification_id)`. |
| Reports | RLS-protected `practice_reports` reads/writes; cursor pagination equivalent to the repaired web client. List queries omit screenshots and full evidence. |
| Signals | Owned `report_signals` writes; database enforces investigator eligibility. |
| Votes | `cast_report_verdict(requested_report_id, requested_verdict, requested_reason)`; paginated `report_verdicts` reads and exact server totals. |
| Notes | Owned `report_investigation_notes` inserts; the database derives author role and username. |
| Public profile | `get_public_profile(requested_username)`; supported while signed out. |
| Profile editing | `change_username`, `set_profile_badge`, owned profile reads, and supported Supabase Auth password operations. |
| Avatars | Owner-path uploads to `avatars`; preserve the current 2 MiB PNG/JPEG/WebP bounds and server-side restrictions. |
| Export | `export_my_data()`; write the resulting JSON through Android's document creation flow. |
| Account deletion | `POST /api/auth/delete-account` with bearer access token and `{"confirm":"HAPUS AKUN SAYA"}`. The hosted server prepares deletion and removes avatar bytes. |

Only the Supabase project URL, public/publishable key, and application API base URL belong in mobile build configuration. Server secret/service-role keys remain on the backend. Use [Supabase's Kotlin setup documentation](https://supabase.com/docs/guides/getting-started/quickstarts/kotlin) when selecting and initializing the client modules.

The hosted migration history matches the repository through `20261114000000_username_login_rate_limit.sql`. This migration and its matching API are deployed to the user-designated staging project and current Vercel Preview. Synthetic signup, username login, wrong-password rejection, account deletion, and username-login throttling have passed through Preview. The Android CI workflow and remaining local worktree changes still need the planned GitHub push/PR and remote CI run.

## Simulation parity

Port the existing state machines as explicit states/actions, with transition checks in domain code. Compose screens should not duplicate eligibility or scoring rules in button handlers.

| Module | Required behavior |
| --- | --- |
| Courier SMS | Four checks worth 25% each: sender judged unverified, link judged suspicious, official channel verified, and a safe final choice. Server-confirmed 100% unlocks the next module. |
| Social Engineering | Select 2–5 distinct artifacts, complete extraction/pretext stages, select a mitigation, and finish reconstruction. Completion has no numeric score. It unlocks the document module once prior requirements are satisfied. |
| Malicious document | Inspect at least two fields, verify the official channel, and select a final response. Three equally weighted checks determine the score; full success completes the module. |

Preserve the exact wire IDs for decisions and artifacts. For example, Courier uses `assess:sender_unverified`, `assess:link_suspicious`, `verify_official_channel`, and `choose:report_delete`; Social Engineering uses `artifact:visual`, `mitigation:limit`, and `complete:reconstruction`. Display translations can change without changing these IDs.

Create shared language-neutral fixture cases from the existing reducer/scoring tests. Run the same input/expected-output examples against Kotlin domain tests and the server rubric. Keep sample links/messages inert and avoid invoking Android dialers, browsers, downloads, SMS handlers, or executable files from simulation actions.

## Persistence and recovery

| Data | Proposed native storage/lifecycle |
| --- | --- |
| Session credentials | Session adapter with Keystore-backed encryption, no logging, and exclusion from device backups. Check the chosen Auth client's persistence integration in Phase 2. |
| Language/preferences | DataStore. |
| Active simulation | Room record with account/guest owner, module, stage, selections, attempt ID, and revision. |
| Pending completion | Room transaction storing owner ID, module ID, attempt ID when known, ordered decisions, retry state, and local operation ID. |
| Account dashboard/report metadata | Account-scoped cache with refresh state; cached values do not authorize writes. |
| Packaged lessons/artwork | Android assets/resources, available offline. |
| Selected evidence image | Private temporary app file or persisted document access until an online report submission succeeds; clear on cancel/logout as appropriate. |

Use unique WorkManager jobs with a network constraint and backoff. Before each submission, confirm that the active account matches the queued owner. Recover a timed-out completion by resubmitting the same attempt ID. Keep the operation until the server acknowledges it, then refresh authoritative access, points, quests, and notifications.

A lost attempt-creation response can leave an unfinished server attempt. Recovery may create a new attempt if no ID was saved; completion rewards must still remain unique server-side. Test this case separately from a lost completion response.

Preserve the repaired web behavior of clearing pending writes on logout/local wipe. State this to the learner if pending work exists when they sign out. Do not attach guest local completions to a different account as proof of server completion.

Browser-local social links, biography/history, guest attempts, and unsynchronized work will not automatically appear in Android. Server-backed accounts, reports, badges, and verified progress do carry over. A future explicit export/import path for local-only data can be considered separately.

## Implementation phases and acceptance gates

| Phase | Deliverable | Gate before continuing |
| --- | --- | --- |
| 0. Backend contract baseline | Confirm repaired migration/API deployment in staging; capture sanitized Auth, dashboard, module, report, and deletion fixtures; record the intended production API domain. | Existing authorization tests pass; repeated completion returns the same result; avatar deletion is exercised against actual isolated Storage; DTO fixture shapes are recorded. |
| 1. Native foundation | Create the native project root, wrapper/version catalog, `:app`/`:core`, theme, localization skeleton, navigation, and isolated build configuration. | Clean checkout builds a debug APK and runs JVM tests/lint; app launches in the available emulator; no backend credentials are required for offline previews. |
| 2. First complete journey | Registration/login/session restore, dashboard, catalog access, Courier simulation, completion queue, and next-module unlock. | A staging account completes Courier, observes the authoritative unlock on both clients, survives rotation/process death, and recovers a lost completion response without duplicate rewards. |
| 3. Remaining learning features | Social Engineering, document simulation, module review, achievements, points/levels, quests, and in-app notifications. | All module transition/rubric fixtures agree with server behavior; Social Engineering remains unscored; stale caches cannot unlock modules. |
| 4. Community and account parity | Paginated reports, evidence, votes, notes, public profiles, avatar/profile editing, export/deletion, and local-data controls. | Student/investigator boundaries hold through direct API tests; anonymized reports remain visible; account switching reveals no prior account data; deletion handles partial Storage failure and retry. |
| 5. Release hardening | Accessibility, both languages, large fonts, small screens/tablets, system Back behavior, release build configuration, CI, and distribution artifacts. | Release-mode build passes; min/current API device checks pass; public-key-only APK inspection passes; signed AAB and repeatable release instructions exist. |

Phase 2 is the first useful Android milestone. A shell with placeholder dashboards or local-only sign-in does not satisfy it.

## Verification and rollout

Preserve the backend/API and SQL regression suites in `backend/` throughout the migration. Add Kotlin JVM tests for reducers, score calculations, serialization, queue ownership, retry behavior, and account boundaries. Add Compose/instrumentation tests for complete learning journeys, process recreation, locale changes, evidence selection, and account deletion states. Test network failures against controlled fixtures and actual staging services, never production test accounts.

Once the proposed project exists, the CI baseline will run wrapper validation and tasks equivalent to:

```sh
cd android
./gradlew :core:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest
./gradlew :app:bundleRelease
```

Instrumentation requires an emulator/device; signed release output requires signing configuration. These commands are future acceptance checks, not commands currently runnable in this repository.

Keep the API and database backend available during native development and initial Android testing. Use a staging backend until the Android flows pass the gates above, then distribute a signed internal-testing build. Keep username-login and account-deletion endpoints deployed while native account flows depend on them; the operator console and any learner-facing web client remain separate projects.

## Decisions to finalize before release

The planning defaults above are enough to begin foundation work. Before publishing, confirm the permanent application ID, developer-owned API/App Links domain, release signing ownership, supported-device audience, and distribution channel. Configure email-confirmation/password-recovery callbacks for the intended native flow if those Auth features are enabled. These values were not inferred from the repository name or embedded into this plan as production configuration.

Full learner feature parity is the release scope in this plan. Push notifications, an Android operator console, iOS, remote lesson authoring, and automatic browser-local-data import are separate follow-up work.
