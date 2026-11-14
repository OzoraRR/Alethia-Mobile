# Alethia Backend

This is the backend side of the Alethia Project Mobile monorepo. It contains API handlers needed for username login and account deletion, plus the Supabase schema migrations and database tests. The native learner app is in `../android`; this directory has no learner-facing web UI.

Alethia Mobile uses Supabase Auth directly from its Kotlin client for email registration/sign-in and calls `POST /api/auth/username-login` for username sign-in. The API returns the verified session tokens and expiry fields; the native Auth client imports and stores that session using Android Keystore-backed encryption. Account deletion remains a backend endpoint for a later native profile flow. The Android dashboard still displays sample data.

The hosted Supabase project **Alethia Mobile** is configured in Singapore (`ap-southeast-1`, ref `zbeaiphxmmwutzmqydlk`). All 50 repository migrations are applied, including `20261114100000_limit_public_profile_to_basics.sql`. Local development remains available as a separate profile. The hosted project is being used as staging by project-owner direction; the Supabase CLI labels its environment `production`, so do not use it for real production data.

Hosted email confirmation is disabled for the current testing setup (`auth.email.enable_confirmations = false`), so a new email/password signup returns an authenticated session immediately. Supabase Auth stores the credential; the `on_auth_user_created` trigger copies the submitted email and username into `public.profiles`. Re-enable confirmation and configure email delivery before production use.

## API service

1. Copy `.env.example` to `.env.local` and set the local Supabase URL, public key, and server secret key.
2. Install the exact locked dependencies with `pnpm install --frozen-lockfile`.
3. Start the API service with `pnpm dev:local` (port 3002, local Supabase) or `pnpm dev:hosted` (port 3002, hosted Supabase). They use `.env.local` and `.env.hosted.local` respectively. `pnpm dev` remains available on port 3001.
4. Configure `ALETHIA_API_BASE_URL` in Alethia Mobile to the backend's emulator-reachable host and port. `10.0.2.2` reaches the host from an Android emulator. The current workstation uses port `3002` because a separate container already occupies `3001`; another machine can use the default `3001` if it is free. A physical device needs the host machine's reachable LAN address and matching Android debug network-security configuration.

Available routes:

- `POST /api/auth/username-login` (returns `access_token`, `refresh_token`, `expires_in`, and `token_type`)
- `POST /api/auth/delete-account`

Keep `SUPABASE_SECRET_KEY` on this server only. Never copy it into Android build configuration or an APK.

## Supabase database

The `supabase/` directory contains the complete migration chain and pgTAP database tests. Apply migrations to a local stack with the Supabase CLI, or run the repository's isolated PostgreSQL verification script with its required PostgreSQL and pgTAP packages installed:

```sh
pnpm db:start
pnpm db:reset
pnpm db:test
```

The API routes require the Supabase project to include the migrations. The linked hosted project currently matches all 50 repository migrations. Review future updates with `pnpm exec supabase db push --remote --dry-run` before applying them. The hosted database password is stored in the ignored `.env.local`; never commit or share that file.

The Android hosted profile is stored in the ignored `../android/alethia.hosted.properties` file and contains only the public key. From this directory, build the app with `(cd ../android && ./gradlew :app:assembleDebug -PalethiaConfig=alethia.hosted.properties)`. Run the backend with `pnpm dev:hosted` so emulator requests to `10.0.2.2:3002` also use the hosted database. The backend secret key remains in `.env.hosted.local` and is never packaged into Android.

## Local checks

```sh
pnpm lint
pnpm typecheck
pnpm test
pnpm build
```

`pnpm test` includes account-deletion unit tests and a username-login HTTP contract test against local Supabase RPC/Auth test doubles. With the local stack running, `bash scripts/test-local-auth.sh` creates a temporary user, verifies username login against real local Supabase Auth, and deletes that user afterward. It refuses to run against a non-local URL and does not contact the hosted project. See the [current security framework](SECURITY_FRAMEWORK.md) for the coverage boundary and outstanding work.

`pnpm verify:migrations` uses the local PostgreSQL setup described in `scripts/verify-migrations.sh`; it does not contact the linked Supabase project.

## CI and architecture

API and database CI run independently based on changed paths. API CI uses the checked-in pnpm lockfile and runs lint, typecheck, unit tests, and a production build. Database CI starts an isolated local Supabase stack, resets it from migrations, runs pgTAP, and exercises username sign-up/login against local Supabase Auth. See [the backend architecture baseline](docs/ARCHITECTURE.md).

A manual Vercel Preview deployment is live with the username-login rate limiter. The Vercel project is already linked to `OzoraRR/Alethia-Mobile`; its root is `backend/` and Node.js is 24.x. Push-triggered deployments have not yet been verified. The Production branch is intentionally unset until a separate Production Supabase project and Production variables are ready; `release` is the intended branch for that future environment. The active GitHub ruleset `Protect Main` targets the default `main` branch and requires a pull request, one approval, and the `Required API checks` and `Required database checks` status checks. Android CI is available in this checkout but is not required by the current ruleset.
