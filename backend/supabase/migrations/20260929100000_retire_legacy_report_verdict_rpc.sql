-- Verdicts now have an auditable, reason-bearing row in report_verdicts.
-- The older RPC only updated the denormalized badge and could bypass that
-- record, so retain its definition for historical compatibility but remove
-- every application role's ability to invoke it.
revoke all privileges on function public.set_report_verdict(uuid, text)
  from public, anon, authenticated;

comment on function public.set_report_verdict(uuid, text) is
  'Legacy write path retained for compatibility; execution is revoked from application roles. Use cast_report_verdict(uuid, text, text).';
