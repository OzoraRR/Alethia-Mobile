# Backend staging deployment

**Status:** configuration prepared; no hosting account connected and no deployment created.
**Last reviewed:** 12 November 2026

## Proposed staging target

- Host: Vercel, for the Next.js API in this repository.
- Vercel project root: `backend/` (the Android app remains outside the deployment; see [Vercel monorepo configuration](https://vercel.com/docs/monorepos)).
- Runtime: Node.js 24; package manager: pnpm 12.17.0, as pinned by the backend.
- Function region: Singapore (`sin1`), configured in `backend/vercel.json` to stay close to the current Supabase region ([region settings](https://vercel.com/docs/functions/configuring-functions/region)).
- First environment: Preview only, connected to a **dedicated staging Supabase project**. Do not use the production project for preview deployments or deletion tests.
- Transport: use the provider HTTPS URL for staging. Attach a custom domain only when one is available; verify its TLS certificate after DNS setup ([Vercel SSL](https://vercel.com/docs/domains/working-with-ssl)).

Vercel Hobby is limited to personal, non-commercial use. Vercel lists Pro at USD 20/month plus usage beyond its included credit ([pricing](https://vercel.com/pricing)). Choose the plan that matches the project's use before connecting an account; this repository change does not create an account, deployment, or charge.

## Provider setup checklist

1. Push this repository to its intended GitHub repository and connect that repository to Vercel.
2. Set the Vercel project root directory to `backend/`.
3. Create a separate Supabase staging project in Singapore and apply the checked-in migrations. Keep production credentials out of Preview scope.
4. Add these variables in the Vercel project settings for **Preview only**:
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
   - `SUPABASE_SECRET_KEY` (server-only; never add this to Android or a `NEXT_PUBLIC_` variable)
5. Deploy a Preview build and verify `GET /api/health` returns HTTP 200, JSON status `ok`, and an `X-Request-ID` header.
6. Verify username sign-in and account deletion using synthetic accounts in staging. Confirm deleted users and their avatar objects are removed. Never use a real user's account for deletion testing.
7. Record the deployment URL, staging project reference, migration head, test date, and outcome without copying any keys into this repository.

Production deployment is a separate decision: use a separate Supabase project and Production-scoped variables, confirm auth and rate-limit policies, and review the production migration plan before enabling it.

## Health and logs

`GET /api/health` is a liveness endpoint. It deliberately does not query Supabase, so HTTP 200 confirms that the API process can answer requests; it does not prove database connectivity.

API responses include a request ID. Failure logs contain only structured metadata (timestamp, event, request ID, and error class); credentials, request bodies, and raw upstream error messages are excluded. Use the request ID to correlate a client report with provider logs. Keep provider log access limited to project maintainers and use the host's retention controls.

## Rollback

For an API-only regression, roll back to the last healthy deployment and preserve the failing deployment's request IDs for investigation. For a database migration, first determine whether the change is backward compatible with the prior API build; do not assume that rolling back the API reverses a schema change. Database restoration follows [BACKUP_AND_INCIDENTS.md](BACKUP_AND_INCIDENTS.md).
