# Backend staging deployment

**Status:** Vercel is not connected. The existing Supabase project `Alethia Mobile` was selected as the current staging target, reset from repository migrations, and passed a synthetic Auth smoke test on 12 November 2026.
**Last reviewed:** 12 November 2026

## Current staging target

- Proposed host: Vercel, for the Next.js API in this repository. No Vercel account or deployment is connected yet.
- Vercel project root: `backend/` (the Android app remains outside the deployment; see [Vercel monorepo configuration](https://vercel.com/docs/monorepos)).
- Runtime: Node.js 24; package manager: pnpm 12.17.0, as pinned by the backend.
- Function region: Singapore (`sin1`), configured in `backend/vercel.json` to stay close to the current Supabase region ([region settings](https://vercel.com/docs/functions/configuring-functions/region)).
- Supabase: the project owner designated the existing `Alethia Mobile` project as staging. Supabase CLI labels its environment `production`; it is not isolated from a separate production project. Do not connect real production users to it. Create a separate Supabase project before production release.
- Preview environment: connect only to the user-designated `Alethia Mobile` staging target, with synthetic accounts for deletion tests.
- Transport: use the provider HTTPS URL for staging. Attach a custom domain only when one is available; verify its TLS certificate after DNS setup ([Vercel SSL](https://vercel.com/docs/domains/working-with-ssl)).

Vercel Hobby is limited to personal, non-commercial use. Vercel lists Pro at USD 20/month plus usage beyond its included credit ([pricing](https://vercel.com/pricing)). Choose the plan that matches the project's use before connecting an account; this repository change does not create an account, deployment, or charge.

## Provider setup checklist

1. Connect `OzoraRR/Alethia-Mobile` to Vercel.
2. Set the Vercel project root directory to `backend/`.
3. Use the existing `Alethia Mobile` project for Preview as designated above. Its database was reset and all 48 checked-in migrations were applied; keep production user data out of it.
4. Add these variables in the Vercel project settings for **Preview only**:
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
   - `SUPABASE_SECRET_KEY` (server-only; never add this to Android or a `NEXT_PUBLIC_` variable)
5. Deploy a Preview build and verify `GET /api/health` returns HTTP 200, JSON status `ok`, and an `X-Request-ID` header.
6. Re-run username sign-in and account deletion through the deployed Preview using synthetic accounts. The local API against hosted Supabase already passed signup, username login, wrong-password rejection, and account deletion; no avatar object existed during that test. Never use a real user's account for deletion testing.
7. Record the deployment URL, staging project reference, migration head, test date, and outcome without copying any keys into this repository.

Production deployment is a separate decision: use a separate Supabase project and Production-scoped variables, confirm auth and rate-limit policies, and review the production migration plan before enabling it.

## Health and logs

`GET /api/health` is a liveness endpoint. It deliberately does not query Supabase, so HTTP 200 confirms that the API process can answer requests; it does not prove database connectivity.

API responses include a request ID. Failure logs contain only structured metadata (timestamp, event, request ID, and error class); credentials, request bodies, and raw upstream error messages are excluded. Use the request ID to correlate a client report with provider logs. Keep provider log access limited to project maintainers and use the host's retention controls.

## Rollback

For an API-only regression, roll back to the last healthy deployment and preserve the failing deployment's request IDs for investigation. For a database migration, first determine whether the change is backward compatible with the prior API build; do not assume that rolling back the API reverses a schema change. Database restoration follows [BACKUP_AND_INCIDENTS.md](BACKUP_AND_INCIDENTS.md).
