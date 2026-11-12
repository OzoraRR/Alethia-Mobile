# Legacy web application security review

> **Historical scope warning (12 November 2026):** this review describes the former browser application and its Netlify deployment as of 3 October 2026. The current project uses a Kotlin Android client and a separate API/database backend; files and controls named below such as `middleware.ts`, `features/`, `e2e/`, and the Netlify deployment are not present in the current backend. Treat the review and its hosted-project observations as historical. The current framework is [SECURITY_FRAMEWORK.md](../SECURITY_FRAMEWORK.md).

**Local repair update, 2 November 2026:** the new forward migration `20261102000000_review_security_and_recovery.sql` repairs admin login limiting, protects direct investigator-verdict writes, enforces signal eligibility and note roles, freezes avatar uploads during deletion, includes verdicts in exports, and supports idempotent completion recovery. The application now removes avatar objects through a verified server endpoint before deleting an account, scopes local cleanup to account boundaries, paginates community reports without inline evidence images, and retries pending completion writes. Runtime dependencies were patched and CI now audits them. These changes were validated locally; the production deployment and hosted migration state described below have not been re-inspected. The original repair summary is not present in this checkout.

**Review date:** 3 October 2026

**Review target:** GitHub `main` at `ddb2d29` (merge of [PR #24](https://github.com/OzoraRR/alethia/pull/24)).

**Scope:** application source, migrations, and selected read-only checks against the linked Supabase database. The remote migration list matched this repository through `20261002210000`; selected RPC grants, permanent-account policies, and avatar bucket settings were also checked. Netlify's production deploy and environment variables, plus Supabase dashboard settings such as Auth, SSL, and backups, were not independently inspected.

This framework records controls that can be tied to repository evidence, the remaining risks, and the production checks still owned by the project operators. It is not a penetration-test report, legal opinion, certification, or claim of conformance to a security standard. The OWASP Application Security Verification Standard (ASVS) is used as a review checklist, not as a certification claim.

## System and trust boundaries

```text
Learner browser
  ├─ Next.js pages, client-side simulations, and public Supabase publishable key
  ├─ Supabase Auth session for account operations
  └─ local browser storage for UI recovery and non-production demo fallback
       │ HTTPS / authenticated Supabase requests
       ▼
Supabase Data API and RPCs ── PostgreSQL, RLS, triggers, and migration-defined grants
       ▲
       │ privileged admin RPCs, authorized by a separate hashed admin-session token
Netlify Next.js runtime / middleware / API routes
```

The browser publishable key is expected to be visible to users. It is not an authorization secret: RLS, grants, and server-side checks must enforce data access. The admin cookie is separate from Supabase Auth and is checked against a hashed token in the database. Middleware improves page routing but is not the database security boundary.

## Data and safe-use rules

| Data | Where it is used | Handling and limitation |
| --- | --- | --- |
| Account email, username, public display profile | Supabase Auth and `profiles` | Private account data is protected by database policies and triggers. The `get_public_profile` RPC is intentionally callable by `anon` and `authenticated`; it publishes username, module count/mastery, selected badges, and report/investigation summaries (including report titles, dates, signal score, review status, and verdict). It does not return email, points, streaks, or locale. |
| Module attempts, decisions, completion, progress, points, quests, and notifications | Supabase PostgreSQL; local browser state may support recovery | Module completion, scoring, and unlock decisions are validated by server RPCs. Local state is not authority for server unlocks. |
| Community report text, defanged URL, and optional screenshot | `practice_reports` in PostgreSQL | Reports may contain personal or sensitive content if users ignore the warning. Screenshots are accepted as image data URLs with a 500 KB client limit and a 700,000-byte database constraint; this is not a durable media-storage design for scale. |
| Profile avatar | Public Supabase Storage bucket `avatars` | Avatar image bytes are intentionally public. Upload, replacement, and deletion are owner-path scoped and limited to permanent authenticated accounts; the migration sets a 2 MiB limit and PNG/JPEG/WebP MIME allow-list. Public visibility is not an access-control feature. |
| Admin password and session | Admin tables/RPCs and an HttpOnly cookie | Password hashes are stored by database functions; session tokens are hashed in the database. The browser cookie is HttpOnly, SameSite Strict, and eight hours. It is Secure in production, or when `ADMIN_COOKIE_SECURE=true` outside production. |

All training artifacts and messages must remain fictional and inert. Never use real recipients, live malicious links, credential/OTP collection, money-transfer instructions, executable attachments, or downloads. Learners should not submit credentials, OTPs, private correspondence, unredacted identifiers, or third-party personal data in reports.

The account export RPC resolves the caller from `auth.uid()` and has no user-ID input. Account deletion removes the account and associated account records while anonymizing surviving community reports and clearing their evidence, URL, and screenshot fields. Logical deletion does not itself prove immediate removal from provider backups; backup retention and restore behavior need to be confirmed with the hosted service settings.

## Implemented controls and repository evidence

| Area | Evidence in the repository | Status / boundary |
| --- | --- | --- |
| Browser/API access | `middleware.ts`, `lib/auth/guard.ts`, and API route handlers | Protected account pages require a non-anonymous Supabase user when Supabase is configured. The database remains authoritative. |
| Production identity fallback | `lib/auth/accounts.ts`, `tests/accounts.test.ts` | The browser-local account fallback is limited to non-production. A missing Supabase configuration in production returns an unavailable error rather than creating a local-only account. Production environment values still need owner verification. |
| Row-level ownership and least privilege | `supabase/migrations/*.sql`; `supabase/tests/002_rls_anon_role.sql`, `003_rls_authenticated_role.sql`, and related tests | Migrations define RLS, grants, triggers, and narrowly scoped RPCs; pgTAP exercises anonymous and authenticated paths. A local test pass is not evidence that hosted settings are correct. |
| Server-validated learning progress | `20260928000000_server_scored_module_progress.sql`, subsequent migrations, and `supabase/tests/011_server_scored_module_progress.sql` | Attempt ownership, decisions, scoring, and completion are checked in PostgreSQL; client score/local storage is not the unlock authority. |
| Privileged functions | `20261002170000` through `20261002210000` security migrations and `supabase/tests/016_security_hardening.sql` | Function grants were checked against the linked database on 3 October. Admin RPCs and username-to-email lookup are not executable by `anon` or `authenticated`; the account/progress RPCs exposed to `authenticated` call a permanent-account guard. `get_public_profile` is the intentional public exception described above. |
| Admin session | `app/api/admin/login/route.ts`, `lib/admin/server.ts`, admin RPC migrations/tests | Separate token cookie, hashed token lookup, request bounds, generic user-facing login failures, database-side rate limiting, and server-only Supabase secret-key calls. Logs and operator access must still be reviewed in the hosting dashboard. |
| User input and report attachments | `features/reports/report-form.tsx`, `features/reports/reports.ts`, report constraints in migrations | Input lengths/types and image sizes are bounded; URLs are defanged for display. These checks do not make arbitrary submitted text trustworthy. |
| Avatar access | `20260920000000_profile_avatars.sql`, `20261002180000_harden_rpc_grants_and_permanent_accounts.sql`, `20261002200000_scope_avatar_policies_to_permanent_users.sql`, `features/profile/avatar-persistence.ts` | The linked bucket is public by design, so anyone with an object URL can fetch image bytes. The checked Storage metadata policies scope operations to the owner's folder, and restrictive policies require a permanent account; uploads are limited to 2 MiB and PNG/JPEG/WebP. |
| Account data rights | `20260926130000_account_export_and_deletion.sql`, `supabase/tests/009_account_export_and_deletion.sql` | Export is scoped to the authenticated caller. Deletion/anonymization semantics are tested locally; external backups and logs have separate retention. |
| Browser response headers | `next.config.ts`, `e2e/routes.spec.ts` | Sets `nosniff`, frame denial, a strict referrer policy, disables unused camera/microphone/geolocation permissions, and sends host-only HSTS. E2E verifies headers on a public response. A Content Security Policy is deliberately not claimed; it needs a nonce/source design compatible with Next.js and Supabase, followed by browser testing. |
| Dependency/build and route checks | `.github/workflows/ci.yml`, `tests/`, `e2e/` | CI is configured for migration/pgTAP, typecheck/lint/unit, production build, and Chromium E2E across desktop/mobile/tablet. All four checks passed for reviewed `main` commit `ddb2d29` ([GitHub Actions run](https://github.com/OzoraRR/alethia/actions/runs/37045248475)). |
| Local Supabase defaults | `supabase/config.toml` | Local password minimum is aligned to 8; local email confirmations are disabled for development; seed loading is disabled because no deterministic `supabase/seed.sql` exists. These settings do not change the hosted project. |

## Minimum production-owner checks

Complete these in the provider dashboards before treating the deployment as operationally verified. Share only redacted status or screenshots; do not send keys, passwords, database URLs containing credentials, recovery codes, or user records.

### Netlify

- Confirm the production deploy points to the intended repository, branch, and commit; preview contexts are not using production database write configuration unless intentionally approved.
- Confirm the production variable **names** exist: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY` (or temporary legacy `SUPABASE_SERVICE_ROLE_KEY`), `NEXT_PUBLIC_SITE_URL`, and `ADMIN_COOKIE_SECURE`. Confirm `ADMIN_COOKIE_SECURE=true`; never reveal key values. Keep the secret key server-only and out of build args/browser bundles.
- Confirm HTTPS is active and inspect a production response for the headers listed above. If headers are rewritten by the platform, fix the platform configuration and retain a repeatable browser/HTTP check.
- Review build and function logs for accidental personal data or secret values. Confirm no `service_role`/secret key is present in browser-facing variables or build output.
- Confirm deploy previews are access-controlled or use an isolated Supabase staging project. Preview code is not automatically trusted just because it comes from the same repository.

### Supabase

- Run the project's Security Advisor and resolve or explicitly document each high/critical finding. On 3 October it still reported the intentionally public profile RPC, authenticated `SECURITY DEFINER` RPCs, anonymous-sign-in policy warnings, and leaked-password protection disabled. Verify RLS on every exposed table, view, and RPC; confirm grants as well as policies.
- The linked migration list was checked on 3 October and matched through `20261002210000`. Repeat this read-only check before future schema changes, and compare deployed schema to the intended migration head. Do not run local tests against the linked/hosted database.
- In Authentication settings, verify the canonical HTTPS Site URL and exact redirect allow-list; remove local/dev redirects from production if no longer required. Verify email confirmation, minimum password length (at least 8), OTP expiry/length, password-change protection, sign-up policy, rate limits, and CAPTCHA/abuse controls against the real audience and mail configuration.
- Confirm database SSL enforcement. Review database network restrictions before enabling them, because an incorrect allow-list can break hosted functions; test approved access paths after any change.
- Confirm MFA/2FA for Supabase organization/project owners and GitHub maintainers with deployment access. Keep the owner list current and have a second recovery owner.
- Confirm available backup retention for the current plan, choose an acceptable recovery point/objective, and document/test a restore procedure in a non-production project. Do not claim a tested recovery objective until a restore has actually been rehearsed.
- The linked `avatars` bucket and its owner/permanent-account metadata policies were checked on 3 October. Public image bytes remain fetchable by anyone with the URL. Review report data and provider backup/log retention; establish a privacy/contact and deletion-request process.
- Leaked-password protection was reported disabled by Security Advisor on 3 October. Enable it if the project plan supports it; otherwise document the plan limitation and compensating controls. Confirm password minimum length, email confirmation, MFA for owners, and Auth rate limits.

## Known residual risks and prioritized follow-up

| Priority | Residual risk | Required follow-up |
| --- | --- | --- |
| High — owner action | Netlify production deploy/environment variables and Supabase dashboard settings (Auth confirmation, MFA, SSL, backups/restore) remain unverified. The CLI checks cover the migration head and selected grants/policies, not every exposed object or provider setting. | Complete the provider checks above and retain redacted evidence with date/owner. |
| High — operational | No repository security contact or incident-response runbook is documented. | Configure GitHub private vulnerability reporting or a maintainer security contact; assign an incident owner and define triage, containment, credential rotation, user notification, and recovery steps. |
| Medium — privacy decision | `get_public_profile` remains executable by `anon` and returns report and investigation summaries. This is intentional in the current schema, but it is a public-data exception to permanent-account-only access. | Confirm that report titles, dates, scores, statuses, verdicts, and investigation titles should be public. If not, remove the anonymous grant and add the permanent-account guard, then update affected public-profile flows. |
| Medium — authentication | Anonymous Auth sign-ins remain enabled. Restrictive `is_anonymous = false` checks protect the covered account tables and user RPCs, but the Security Advisor still reports underlying policies that target `authenticated`. | Keep the restrictive gates and tests in place; disable anonymous sign-ins only if the product no longer needs them. Recheck the advisor after any policy change. |
| Medium — unresolved database lint | Linked lint of `public,storage` reports two errors in Storage's `list_objects_with_delimiter` and `search`, both using dynamic SQL. Public-schema lint has no errors; the Storage messages may be analyzer limitations, but runtime behavior has not been verified by this lint. | Smoke-test Storage list/search operations or confirm the findings with Supabase before treating full linked lint as clean. Do not suppress the errors without verification. |
| Medium — plan limitation | Supabase Security Advisor reports leaked-password protection disabled. | Enable it if available on the plan; otherwise record the limitation and compensating controls. |
| Medium | No tailored Content Security Policy is present. An overly broad or naïve CSP can break Next hydration, image handling, Supabase API/WebSocket connections, and inline styles/scripts. | Design a nonce-based policy, exercise auth/modules/admin flows and report previews, then enforce it with automated browser tests. |
| Medium | Optional report screenshots are embedded in PostgreSQL rows rather than object storage; provider backups may retain logical deletions until backup expiry. | Define retention and backup policies; if usage grows, migrate attachments to private object storage with quotas, ownership policies, and deletion tests. |
| Medium | Application-level sign-up abuse controls and anti-automation settings depend partly on hosted Auth configuration. | Verify provider rate limits; consider CAPTCHA/abuse protection after assessing accessibility and operational impact. |
| Medium | CI/E2E and local pgTAP use synthetic fixtures; they do not prove hosted Supabase/Netlify configuration, load behavior, or a human learning outcome. | Run a controlled user test with consent, synthetic data, a documented task, sample size, and pre/post measurement; publish results with limitations. |
| Low/ongoing | Security dependencies and platform defaults change. | Review dependency updates, provider advisories, migrations, and ASVS-aligned tests regularly; run a scoped external assessment before handling sensitive/high-volume data. |

## Local checks for this framework

```sh
pnpm run typecheck
pnpm run lint
pnpm test
pnpm run build
pnpm run test:e2e
bash scripts/verify-migrations.sh
git diff --check
```

The migration script creates a disposable local PostgreSQL cluster. Do not use `--linked`, the hosted database URL, real users, or production credentials for any of these checks.

## Reference standards and provider guidance

- [OWASP Application Security Verification Standard (ASVS)](https://owasp.org/www-project-application-security-verification-standard/) — a technical verification checklist; no conformance level is claimed here.
- [Supabase production checklist](https://supabase.com/docs/guides/deployment/going-into-prod) and [shared-responsibility model](https://supabase.com/docs/guides/deployment/shared-responsibility-model) — production configuration and provider/operator responsibilities.
- [Supabase API key guidance](https://supabase.com/docs/guides/getting-started/api-keys) — publishable keys are public and must be constrained by authorization policies; secret keys must remain server-side.
- [Netlify Next.js deployment guide](https://docs.netlify.com/build/frameworks/framework-setup-guides/nextjs/overview/) — framework adapter and deployment behavior.
