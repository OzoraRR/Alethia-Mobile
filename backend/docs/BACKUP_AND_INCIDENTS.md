# Backup, restore, and incident response

**Status:** policy proposal documented; repository-local restore rehearsal is implemented. Hosted backup configuration and hosted restore rehearsal remain pending.
**Last reviewed:** 12 November 2026

## Backup policy

### Proposed recovery targets

- Database recovery point objective (RPO): at most 24 hours of lost changes.
- Recovery time objective (RTO): restore critical API and sign-in operations within one business day. This is a target; it has not yet been measured on the hosted project.
- Database retention: keep at least one daily restore point for 7 days.
- Supabase Storage objects: maintain a separate encrypted off-site copy with at least 7 days of retention, updated daily. Database backups do not contain the bytes of Storage objects.
- Configuration: keep schema and policy changes in migrations; maintain provider settings and secret recovery material in an approved password manager. Never put secret values in Git or backup logs.

Supabase's automatic daily database backups and retention depend on the subscription tier ([backup coverage and retention](https://supabase.com/docs/guides/platform/backups)). If the selected tier does not provide the required 7-day retention, configure encrypted scheduled exports to an access-controlled off-site location before storing real user data. Database snapshots do not include the bytes of Storage objects, so the Storage object copy is a separate control and must be verified independently. For a hosted rehearsal, follow Supabase's [restore-to-new-project guidance](https://supabase.com/docs/guides/platform/clone-project) and validate the project settings that are not copied.

### Restore rehearsal

The local rehearsal is run with `cd backend && pnpm db:verify-restore`. It creates a temporary custom-format dump of the **local Docker database**, restores it into a second temporary database in that same local container, compares migration/table/policy/auth-user counts, and removes both temporary artifacts on exit. It skips owner and ACL/default-privilege restoration, `pg_cron`, the managed `realtime` schema, and Vault secrets because those depend on provider/cluster-level roles, settings, extensions, or credentials. This smoke test checks schema and data restoration; it does not validate grants or complete project recovery. The dump contains local database data while it exists; keep the rehearsal local and do not copy it into the repository or a shared location.

This rehearsal checks that a PostgreSQL dump can be restored locally. It is not evidence that a provider-managed snapshot, hosted Auth configuration, Storage objects, secrets, or a full Supabase project can be restored. It must never be pointed at a hosted project.

Before production, rehearse a provider-supported restore into a **new non-production Supabase project**. Verify schema and migration head, RLS and grants, Auth sign-in, a representative user data read/write, and retrieval of a restored avatar object. Record start/end time to measure RTO. Repeat quarterly and after material backup or schema changes. Do not restore over the source project during a rehearsal.

### Current status

- [x] Local dump/restore smoke script added to the database CI workflow.
- [ ] Confirm the selected hosted project's backup entitlement and retention.
- [ ] Enable/verify off-site Storage object backups.
- [ ] Complete a hosted provider restore rehearsal in a separate staging project.
- [ ] Measure RPO/RTO against these proposed targets and revise them if needed.

## Security contact

**A monitored security contact has not been configured yet.** Before public release, the project owner must configure a monitored private reporting channel (for example, the repository's private vulnerability reporting feature or a dedicated security email address) and give maintainers access. Do not publish a personal address in this file without the owner's decision. Until then, do not treat a public issue tracker as a secure disclosure channel.

## Incident response

1. **Triage:** record when the report arrived, affected environment, observed behavior, request IDs, and an initial severity. Do not copy tokens, passwords, or personal data into public issues or chat.
2. **Contain:** disable a vulnerable endpoint or affected deployment if needed; revoke and rotate potentially exposed Supabase/Vercel credentials through the provider console; invalidate affected sessions where appropriate. Do not paste replacement secrets into Git.
3. **Preserve:** restrict access to provider audit/application logs and retain relevant timestamps and request IDs. Keep an incident timeline and avoid destructive cleanup before evidence is preserved.
4. **Assess:** identify affected projects, data, accounts, Storage objects, deployments, and time window. Check RLS/auth changes and database migration history.
5. **Recover:** deploy a reviewed fix or roll back the API. Restore data only into a separate recovery project first, validate it, and document any data-loss window before deciding on production recovery.
6. **Communicate:** the project owner determines any notifications to users, providers, or other required parties after establishing the facts. Use the configured monitored security contact for follow-up.
7. **Close:** document root cause, scope, containment, recovery, and follow-up controls; add regression coverage and verify the fix in staging.

No hosted incident, backup, or restore operation has been performed as part of this repository preparation.
