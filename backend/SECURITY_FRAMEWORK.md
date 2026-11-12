# Alethia Mobile backend security framework

**Review date:** 12 November 2026
**Scope:** the Kotlin Android client, the Next.js API service in `backend/`, and the checked-in Supabase migrations/tests.

This is a repository-based security baseline, not a penetration test or certification. The earlier browser/Netlify review is preserved as [historical material](docs/SECURITY_FRAMEWORK_WEB_LEGACY.md); it describes a different application snapshot and must not be used as evidence about this mobile backend.

## Trust boundaries

```text
Android app
  ├─ email sign-up/sign-in ───────────────> Supabase Auth
  ├─ username sign-in ──> backend API ────> private username/email RPC
  │                                      └─> Supabase Auth password exchange
  ├─ account deletion ──> backend API ────> caller-scoped account RPCs
  │                                      └─> server-key avatar cleanup
  └─ normal account data ────────────────> Supabase Data API / RPCs
                                             PostgreSQL RLS, grants, triggers
```

The Android app may contain only a Supabase publishable key and the API URL. The Supabase server secret stays in the backend environment. Standard user data operations are authorized by the caller's Supabase JWT and database policies; privileged endpoints use the server key only for narrowly scoped work.

## Controls present in the repository

| Area | Current implementation | Boundary / follow-up |
| --- | --- | --- |
| Email authentication | Android calls Supabase Auth directly. A database trigger copies the submitted email and username into `public.profiles`; passwords remain in Supabase Auth. | Hosted email confirmation is currently disabled for testing at the user's request. Decide the production policy and recovery flow before release. |
| Username sign-in | `app/api/auth/username-login/route.ts` validates bounded input, resolves email through the service-role-only RPC, then asks Supabase Auth to verify the password. Responses for an unknown username and an incorrect password are generic; successful responses are `no-store`. | There is no app-level rate limiter before the private username lookup. Supabase Auth rate limits the password exchange, but unknown-name requests do not reach Auth. Add or verify an upstream limit before public deployment. |
| Account deletion | `app/api/auth/delete-account/route.ts` requires a bearer token and explicit confirmation. `lib/auth/delete-account.ts` verifies a permanent authenticated identity, calls user-scoped preparation/deletion RPCs, validates avatar paths belong to that user, and uses the server key only for Storage deletion. Storage work is batched and failures leave deletion retryable. | Hosted Storage behavior and the full flow still need a controlled staging integration test. |
| Database access | `supabase/migrations/` defines RLS, grants, constraints, triggers, and RPCs. The 18 pgTAP files cover module invariants, anonymous/authenticated access, administrative writes, reports, account deletion, progression, and security hardening. | The local reset and complete pgTAP suite passed on 12 November 2026. This does not verify the hosted project's current state. |
| Public data | The migrations intentionally grant `anon` access to `get_public_profile(text)` and mark the `avatars` Storage bucket public. | Confirm the public profile fields and public image URLs are an approved product decision; public bucket bytes are readable by anyone with an object URL. |
| Local configuration | Android local properties and backend `.env` files are ignored by Git. `backend/.env.example` is the safe template. | Keep checking the staged file list before the first GitHub push; never commit `.env.local`, `.env.hosted.local`, `alethia.properties`, or server keys. |
| CI | Root workflows separately run Android checks, backend lint/typecheck/unit/build, and a fresh local Supabase reset with pgTAP plus a real local Auth integration test. | These workflows have not run on GitHub because the monorepo has no remote or commits yet. Branch protection and deployment secrets are not configured. |

## Test evidence in this checkout

The backend Node suite has 8 unit/contract tests: 4 account-deletion tests and 4 username-login tests. The username flow test runs the handler against a local HTTP test double for the Supabase RPC and Auth endpoints. A separate `pnpm test:local-auth` test signs up a synthetic user against the real local Supabase Auth service, resolves its email through the migrated database RPC, verifies the returned access token, rejects a wrong password, and deletes the temporary Auth user. It refuses non-local URLs and uses no hosted credentials.

On 12 November 2026, `pnpm db:reset` recreated the local database and applied all 48 migrations. `pnpm db:test` passed all 18 pgTAP files (302 assertions), and the live local Auth test passed with its temporary user removed. These commands targeted the local stack only; no hosted reset or hosted test was run. TypeScript typecheck, ESLint, and the Next.js production build also pass locally.

The staging/operations preparation also passed local API unit tests, typecheck, lint, and production build. The built `/api/health` route returned HTTP 200 with `X-Request-ID`. A temporary local dump/restore rehearsal preserved the summary `48 migrations / 25 public tables / 57 public policies / 0 Auth users`; the temporary database and dump were removed. This rehearsal intentionally omits provider-managed objects and privileges, so it is not a hosted project restore test.

## Remaining security and operational work

1. Run the existing migration reset and pgTAP workflow in GitHub Actions after the monorepo is pushed, then make its required check part of branch protection.
2. Add request throttling for username lookup and verify Supabase Auth rate limits, abuse controls, and password policy on the hosted project.
3. Review Supabase Security Advisor results, hosted RLS/grants, current migration head, email confirmation, redirect allow-list, anonymous sign-in policy, leaked-password protection, SSL, and owner MFA. Record the date and redacted result; hosted settings have not been rechecked in this local run.
4. **Partially prepared:** Vercel staging configuration, Singapore function region, a liveness endpoint, request IDs, and sanitized structured failure logging are checked in. Deployment and login/deletion tests still require a GitHub remote, provider sign-in, and a dedicated staging Supabase project. See [DEPLOYMENT.md](docs/DEPLOYMENT.md).
5. **Partially prepared:** proposed retention/recovery targets, restore procedure, incident steps, and a local-only dump/restore rehearsal are documented; the rehearsal is included in database CI. Confirm hosted backup entitlement, Storage object backups, and complete a provider restore in a separate non-production project before production. A monitored security contact remains unconfigured. See [BACKUP_AND_INCIDENTS.md](docs/BACKUP_AND_INCIDENTS.md) and root [SECURITY.md](../SECURITY.md).

Do not run local reset or migration-test commands with `--linked` or against the hosted project. For the current local test setup, new sign-ups return a session immediately; revisit this setting before production.
