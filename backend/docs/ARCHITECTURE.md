# Alethia Backend architecture baseline

## Responsibilities

- `app/api/**/route.ts` is the HTTP boundary: validate request shape, authenticate the caller, map service outcomes to status codes, and avoid exposing private identity data.
- `lib/auth/` contains account-level operations and the injectable username-login handler. Account deletion uses the caller's access token for user-scoped RPCs and a server secret only for Storage cleanup.
- `lib/admin/server.ts` is the server-only environment boundary for privileged RPCs. `lib/admin/rpc-client.ts` contains the injectable transport used by that boundary and by local contract tests; never pass a real secret key to client code or import the server boundary into Android.
- `supabase/migrations/` is the source of truth for schema, RLS, grants, and RPC changes; `supabase/tests/` holds pgTAP authorization and behavior tests.

This backend is an API service, not a web frontend. Most future learner data can use Supabase's authenticated API/RPCs directly from Android with the public key; privileged tasks continue through narrowly scoped server endpoints.

## Change a feature safely

1. Define or update the request/response contract and validation in the route.
2. Keep reusable privileged work in a server-only library function.
3. Add a migration for database changes and a pgTAP test for access/behavior changes.
4. Update the matching Android repository/model when native integration exists.
5. Let API CI validate TypeScript, handler tests, and the production build; let database CI reset a fresh local stack, apply migrations, run pgTAP, and exercise the username/Auth handshake against local Supabase.

Both workflows always post required summary checks, then detect relevant file changes internally. API changes do not boot the database stack, migration changes do not rebuild the API service, and documentation-only changes can still pass branch protection.

## Deployment boundary

No automatic deployment is configured. A staging Supabase project, API host, GitHub environment, and deployment credentials have not been selected. Production secrets must remain in the hosting provider/GitHub environment, never in `.env.example`, CI logs, or Android configuration.
