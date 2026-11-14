# Backend staging deployment

**Status:** A Vercel Preview deployment is live with the username-login rate limiter. The Vercel project is linked to `OzoraRR/Alethia-Mobile`; push-triggered deployment has not yet been verified. `release` is the intended Production branch, but it does not exist on GitHub and Vercel currently offers only `main`. Keep Production branch setup deferred until a separate Production Supabase project and Production variables are ready; this does not block staging Preview work. The existing Supabase project `Alethia Mobile` is the user-designated staging target; all 50 repository migrations are now applied there.
**Last reviewed:** 14 November 2026

Migrations `20261114000000_username_login_rate_limit.sql` and `20261114100000_limit_public_profile_to_basics.sql` are applied to the hosted staging target. The profile migration narrows public results to username, module progress, mastery, and selected badges; a synthetic hosted call confirmed the response shape. A synthetic username-login smoke test confirmed the `429` response, `Retry-After`, and `Cache-Control: no-store` behavior. The API intentionally fails closed with `503` if the limiter RPC is unavailable.

## Current staging target

- Host: Vercel project `alethia-mobile-backend`.
- Current Preview URL: https://alethia-mobile-backend-qy3fzlgjp-ozorarr.vercel.app
- The GitHub repository link exists. The project root directory is set to `backend/` and Node.js is set to 24.x to match the backend engine range. The Production branch is intentionally not set yet. Before a production release, create/select `release` in Project Settings → Environments → Production → Branch Tracking after the separate Production Supabase project and its Production variables are ready. Keep current work on Preview deployments ([Git deployment behavior](https://vercel.com/docs/git)).
- For a future manual Preview deploy, run `pnpm dlx vercel@65.15.0 deploy --project alethia-mobile-backend` from the monorepo root. Do not add `--prod` while this project is staging. `pnpm dlx vercel@65.15.0 deploy --dry --project alethia-mobile-backend` verifies the upload manifest without deploying. The root `.vercelignore` keeps Android and root docs out of the CLI upload; `backend/.vercelignore` excludes SQL, tests, scripts, and local documentation. The dry-run packaged 28 files (about 150 KB) and excluded local environment files.
- Runtime: Node.js 24; package manager: pnpm 12.17.0, as pinned by the backend.
- Function region: Singapore (`sin1`), configured in `backend/vercel.json` to stay close to the current Supabase region ([region settings](https://vercel.com/docs/functions/configuring-functions/region)).
- Supabase: the project owner designated the existing `Alethia Mobile` project as staging. Supabase CLI labels its environment `production`; it is not isolated from a separate production project. Do not connect real production users to it. Create a separate Supabase project before production release.
- Preview environment: connect only to the user-designated `Alethia Mobile` staging target, with synthetic accounts for deletion tests.
- Preview environment variables are configured for Supabase URL, publishable key, and server secret. The server secret is sensitive and is not in Git.
- The Preview build is `READY`; `GET /api/health` returned HTTP 200 with `{"status":"ok"}`. This endpoint does not query Supabase, so it does not confirm database connectivity.
- Vercel Authentication is disabled on this project so the Android client can reach the API. Preview URLs are public; API routes must enforce their own authentication and authorization. A temporary automation bypass used for the health check was revoked.
- The initial Production bootstrap build failed because its root directory was misconfigured. It was launched with `--skip-domain`, so no Production alias was attached. No Supabase variables are configured for Production; this is not a usable Production deployment.
- Transport: use the provider HTTPS URL for staging. Attach a custom domain only when one is available; verify its TLS certificate after DNS setup ([Vercel SSL](https://vercel.com/docs/domains/working-with-ssl)).

Vercel Hobby is limited to personal, non-commercial use. Vercel lists Pro at USD 20/month plus usage beyond its included credit ([pricing](https://vercel.com/pricing)). Choose the plan that matches the project's use before connecting an account; this repository change does not create an account, deployment, or charge.

## Provider setup checklist

1. Verify a pull request to `main` gets a Preview deployment. Before production release, create the `release` branch and select it as the Production branch only after separate production Supabase credentials are configured.
2. The Vercel project root directory is set to `backend/` and Node.js is set to 24.x.
3. Use the existing `Alethia Mobile` project for Preview as designated above. It currently has all 50 repository migrations applied. Keep production user data out of this project. Supabase CLI labels it `production`, so provision a distinct Supabase project for real production users.
4. These variables are already configured for **Preview only**:
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
   - `SUPABASE_SECRET_KEY` (server-only; never add this to Android or a `NEXT_PUBLIC_` variable)
5. The current Preview health check and synthetic signup, username sign-in, wrong-password rejection, username-login rate-limit, and account-deletion smoke tests passed after the server secret was configured. The account-deletion test uploaded a synthetic avatar, deleted the synthetic account through the API, verified that the avatar object was removed, and verified that the deleted token was rejected. Never use a real user's account for deletion testing.
6. Record the deployment URL, staging project reference, migration head, test date, and outcome without copying any keys into this repository.

Production release is still pending: use a separate Supabase project and Production-scoped variables, confirm auth and rate-limit policies, and review the production migration plan before enabling it.

## Health and logs

`GET /api/health` is a liveness endpoint. It deliberately does not query Supabase, so HTTP 200 confirms that the API process can answer requests; it does not prove database connectivity.

API responses include a request ID. Failure logs contain only structured metadata (timestamp, event, request ID, and error class); credentials, request bodies, and raw upstream error messages are excluded. Use the request ID to correlate a client report with provider logs. Keep provider log access limited to project maintainers and use the host's retention controls.

## Rollback

For an API-only regression, roll back to the last healthy deployment and preserve the failing deployment's request IDs for investigation. For a database migration, first determine whether the change is backward compatible with the prior API build; do not assume that rolling back the API reverses a schema change. Database restoration follows [BACKUP_AND_INCIDENTS.md](BACKUP_AND_INCIDENTS.md).
