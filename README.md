# Alethia Project Mobile

Monorepo for the native Alethia Android app and its API/database backend. The source boundaries remain separate so Android, API, and database changes can be reviewed and checked independently.

## Layout

| Directory | Contents | Open/run from |
| --- | --- | --- |
| [`android/`](android/) | Kotlin, Jetpack Compose, ViewModels, Gradle app and domain modules | Open `android/` in Android Studio |
| [`backend/`](backend/) | Next.js API routes, Supabase migrations, database tests, and local scripts | Run backend commands from `backend/` |
| [`.github/`](.github/) | Root GitHub Actions and merged Dependabot configuration | Repository root |

The backend is an API service; it does not contain the learner-facing Android UI.

## Backend development

From this repository root:

```sh
cd backend
pnpm install --frozen-lockfile
pnpm dev:hosted
```

`dev:hosted` requires the ignored `backend/.env.hosted.local` file. For a local Docker Supabase stack, configure `backend/.env.local`, then use `pnpm db:start`, `pnpm db:reset`, and `pnpm dev:local`. Keep all environment files and secret keys out of Git.

To prepare a backend-only commit from the repository root, stage:

```sh
git add .gitignore .vercelignore SECURITY.md backend \
  .github/dependabot.yml \
  .github/scripts/detect-changes-backend.sh \
  .github/workflows/backend-api.yml \
  .github/workflows/supabase-database.yml
```

This stages backend source, its database/API CI, and shared repository metadata. Stage `android/` and its workflow separately when ready.

## Android development

Open [`android/`](android/) itself in Android Studio. Its Gradle root remains there, so existing Android Studio workflows and `./gradlew` commands stay scoped to the native app:

```sh
cd android
./gradlew :core:test :app:lintDebug :app:assembleDebug
```

See [Android setup](android/README.md) and [backend setup](backend/README.md) for environment-specific details. Local configuration files are intentionally ignored by Git.

## CI

- Android CI checks Kotlin/JVM tests, Android lint, a debug APK, and Android instrumentation tests when `android/` changes.
- Backend API CI runs dependency installation, lint, typecheck, unit tests, and a production build when API files change.
- Supabase database CI resets an isolated local stack from migrations, runs pgTAP and username-login integration tests, and rehearses a local logical dump/restore when database or local-auth files change.
- Backend staging, health/logging, backup, restore, and incident-response preparation is documented in [`backend/docs/DEPLOYMENT.md`](backend/docs/DEPLOYMENT.md) and [`backend/docs/BACKUP_AND_INCIDENTS.md`](backend/docs/BACKUP_AND_INCIDENTS.md).
- Each workflow always reports a required summary check, including for changes outside its scope.

The `origin` remote is `https://github.com/OzoraRR/Alethia-Mobile.git`. Local changes remain local until they are committed and pushed.
