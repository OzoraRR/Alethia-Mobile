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
| Account deletion | `app/api/auth/delete-account/route.ts` requires a bearer token and explicit confirmation. `lib/auth/delete-account.ts` verifies a permanent authenticated identity, calls user-scoped preparation/deletion RPCs, validates avatar paths belong to that user, and uses the server key only for Storage deletion. Storage work is batched and failures leave deletion retryable. | The hosted endpoint successfully deleted a synthetic staging account after reset. Avatar object deletion remains unexercised because the bucket was empty. |
| Database access | `supabase/migrations/` defines RLS, grants, constraints, triggers, and RPCs. The 18 pgTAP files cover module invariants, anonymous/authenticated access, administrative writes, reports, account deletion, progression, and security hardening. | Local pgTAP passed on 12 November 2026. The hosted `Alethia Mobile` project was reset from the same 48 migrations; its migration history is in sync. |
| Public data | The migrations intentionally grant `anon` access to `get_public_profile(text)` and mark the `avatars` Storage bucket public. | Confirm the public profile fields and public image URLs are an approved product decision; public bucket bytes are readable by anyone with an object URL. |
| Local configuration | Android local properties and backend `.env` files are ignored by Git. `backend/.env.example` is the safe template. | The initial backend push excluded `.env.local`, `.env.hosted.local`, Android properties, and Supabase link metadata. |
| CI | Backend CI checks lint/typecheck/unit/build. Database CI resets an isolated local Supabase stack, runs pgTAP and local Auth integration, and rehearses a local restore. | Backend and database workflows passed on GitHub after the initial push. Android source/workflow are still local; branch protection and deployment secrets are not configured. |

## Test evidence in this checkout

The backend Node suite has 8 unit/contract tests: 4 account-deletion tests and 4 username-login tests. The username flow test runs the handler against a local HTTP test double for the Supabase RPC and Auth endpoints. A separate `pnpm test:local-auth` test signs up a synthetic user against the real local Supabase Auth service, resolves its email through the migrated database RPC, verifies the returned access token, rejects a wrong password, and deletes the temporary Auth user. It refuses non-local URLs and uses no hosted credentials.

On 12 November 2026, `pnpm db:reset` recreated the local database and applied all 48 migrations. `pnpm db:test` passed all 18 pgTAP files (302 assertions), and the live local Auth test passed with its temporary user removed. The `Alethia Mobile` hosted database was then reset from those 48 migrations; migration history matched. A synthetic hosted signup, username login, wrong-password rejection, and account-deletion smoke test passed, leaving zero Auth users and profiles. TypeScript typecheck, ESLint, and the Next.js production build pass locally and in backend GitHub CI.

The staging/operations preparation also passed local API unit tests, typecheck, lint, and production build. The built `/api/health` route returned HTTP 200 with `X-Request-ID`. A temporary local dump/restore rehearsal preserved the summary `48 migrations / 25 public tables / 57 public policies / 0 Auth users`; the temporary database and dump were removed. This rehearsal intentionally omits provider-managed objects and privileges, so it is not a hosted project restore test.

## Remaining security and operational work

1. Make the passing backend/database GitHub checks required in branch protection. Push Android source and its workflow when the frontend phase is ready.
2. Add request throttling for username lookup and verify Supabase Auth rate limits, abuse controls, and password policy on the hosted project.
3. Review Supabase Security Advisor results, hosted RLS/grants, email confirmation, redirect allow-list, anonymous sign-in policy, leaked-password protection, SSL, and owner MFA. Migration history and signup behavior were checked, but these other hosted settings have not been reviewed in this run.
4. **Partially prepared:** Vercel configuration, Singapore function region, health endpoint, request IDs, and sanitized logging are checked in. The existing `Alethia Mobile` Supabase project was reset and hosted Auth/login/deletion smoke-tested; Supabase CLI labels it `production`, so provision a separate production project before release. Vercel deployment remains pending. See [DEPLOYMENT.md](docs/DEPLOYMENT.md).
5. **Partially prepared:** proposed retention/recovery targets, restore procedure, incident steps, and a local-only dump/restore rehearsal are documented; the rehearsal is included in database CI. Confirm hosted backup entitlement, Storage object backups, and complete a provider restore in a separate non-production project before production. A monitored security contact remains unconfigured. See [BACKUP_AND_INCIDENTS.md](docs/BACKUP_AND_INCIDENTS.md) and root [SECURITY.md](../SECURITY.md).

Do not run local reset or migration-test commands with `--linked` or against the hosted project. For the current local test setup, new sign-ups return a session immediately; revisit this setting before production.
