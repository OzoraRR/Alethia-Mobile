# Supabase Security Advisor review

**Checked:** 14 November 2026  
**Project:** `Alethia Mobile` (`zbeaiphxmmwutzmqydlk`; CLI labels it `production`, but the owner designated it as staging)  
**Method:** read-only `supabase db advisors --remote --type security --level info`

The scan returned 26 findings: 19 warnings, 7 informational findings, and no errors. This is the hosted baseline before the public-profile change below was applied. The warnings are classifications of exposed `SECURITY DEFINER` functions; they do not by themselves show that a caller can cross account boundaries. The grants and function bodies were compared with the repository migrations and database tests. No hosted grants, policies, or settings were changed during this review.

## Warnings: callable `SECURITY DEFINER` functions

### Public function

At the time of the hosted scan, `public.get_public_profile(text)` was callable by `anon` and `authenticated` and returned report and investigation summaries. The owner selected a limited public profile. Migration `20261114100000_limit_public_profile_to_basics.sql` keeps the public grant but limits the response to username, completed-module count, mastery, and selected badges. It omits report counts, reports, investigations, email, points, streaks, and locale. The migration is applied to hosted staging and locally tested; a synthetic hosted request returned exactly those four fields, then the test account was deleted.

The Advisor will continue to warn about this function after the migration because it remains callable by `anon` as a `SECURITY DEFINER` function. Avatar images are also intentionally public objects, although writes and metadata access remain owner-scoped; their visibility is separate from the profile RPC and was not changed by the owner's selection.

This change hides report and investigation activity from profile lookup only. It does not change the existing community report feed, which remains readable to permanent signed-in users under its current RLS policies, and it does not add a per-report sharing control.

### Authenticated functions

The Advisor flags these 18 functions for authenticated callers:

| Function | Review |
| --- | --- |
| `account_accepts_avatar_uploads()` | Narrow boolean helper used by Storage policies; checks the caller's own profile and deletion-request state. It does not accept another user's ID. |
| `begin_verified_practice_attempt(text)` | Account-scoped app RPC; wrapper requires a permanent account before starting a server-validated attempt. |
| `cast_report_verdict(uuid, text, text)` | Account-scoped investigator RPC; wrapper requires a permanent account and the inner function validates eligibility and target report. |
| `change_username(text)` | Changes the caller's own username through the guarded RPC. |
| `claim_daily_quest(text, date)` | Claims a quest for the caller through the guarded RPC and server-calculated reward. |
| `complete_verified_practice_attempt(uuid, jsonb)` | Completes the caller's server-created attempt; validates the attempt and decisions in the database. |
| `delete_my_account(text)` | Deletes only the caller's account after explicit confirmation and the avatar-preparation flow. |
| `export_my_data()` | Exports only the caller's account data. |
| `get_dashboard_state()` | Reads the caller's dashboard data. |
| `get_module_access()` | Reads the caller's module access and progress. |
| `get_module_result(text)` | Reads the caller's result for a module. |
| `get_public_profile(text)` | Limited public projection described above; callable by both `anon` and `authenticated`. Hosted staging now has the limited implementation. |
| `get_verified_module_access()` | Reads the caller's verified module access and progress. |
| `is_investigator()` | Narrow boolean helper used by community-write policies; checks the caller's own permanent-account claim and completed-module eligibility. It takes no user ID. |
| `mark_notification_read(uuid)` | Updates a notification belonging to the caller. |
| `prepare_account_deletion(text)` | Freezes the caller's avatar uploads and returns only that caller's avatar paths before deletion. |
| `record_daily_activity(text)` | Records activity and streaks for the caller; dates and rewards are computed in the database. |
| `set_profile_badge(text, boolean)` | Updates a badge selection for the caller. |

The 15 account RPCs (all except the two helpers and public-profile function) are granted explicitly in the migrations and use permanent-account or caller-identity checks. The functions use explicit search paths and schema-qualified objects. The two helper grants support Row Level Security policies that need protected-table lookups. The warnings are therefore expected for the current API design; do not remove these grants without replacing the Android-facing RPC or policy behavior.

The pgTAP suite contains checks for the narrowed public RPC allow-list, anonymous-account rejection, admin and service-only boundaries, account deletion, username-login rate-limit isolation, and the public-profile response fields. The latest local run passed all 313 assertions across 19 files. The hosted avatar deletion smoke test also passed through the deployed Preview API.

## Informational findings: RLS enabled with no policies

These seven tables have RLS enabled and no client policies:

| Table | Review |
| --- | --- |
| `public.account_deletion_requests` | Internal deletion coordination state; direct client and service-role table grants are revoked. Access is through the narrow user-scoped deletion RPCs. |
| `public.admin_accounts` | Admin credential hashes; no direct client access. Admin flows use server-side RPCs. |
| `public.admin_audit_log` | Internal audit records; no direct client access. |
| `public.admin_login_attempts` | Internal admin login throttle state; no direct client access. |
| `public.admin_sessions` | Hashed admin sessions; no direct client access. |
| `public.report_review_events` | Private moderation history; anon and authenticated reads are tested as denied. |
| `public.username_login_rate_limits` | HMAC-keyed backend throttle state; clients cannot read it, and the service role cannot select the table directly. The server uses a narrow RPC. |

RLS with no permissive policy denies row access to API roles. These findings are expected and do not need broad client policies. The tests assert access denials for sensitive tables and the login limiter.

## Follow-up before production

1. Decide separately whether public avatar URLs are acceptable. The profile projection is already limited on hosted staging.
2. Auth Rate Limits were reviewed on 14 November and match the displayed Supabase defaults: email 2/hour, SMS 30/hour, token refresh 150/5 minutes, verification 30/5 minutes, anonymous users 30/hour, sign-ups/sign-ins 30/5 minutes, Web3 30/5 minutes, and 60 seconds between emails per user when custom SMTP is used. No limits were changed. Per the owner's dashboard review, sign-up is enabled, email confirmation and anonymous sign-in are disabled for this test setup, and the minimum password length is 8. Password recovery and redirect configuration are deferred until the native app supports those flows. Leaked-password protection was not confirmed and depends on the Supabase plan; account-owner MFA was deferred by the owner. Decide the email-confirmation/recovery policy before production. PostgreSQL SSL enforcement is enabled on hosted staging and was verified with the CLI.
3. Create a separate Supabase production project before connecting production users. The current hosted project is the designated staging target despite its CLI environment label.

