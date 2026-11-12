import { deleteAccountData } from "../../../../lib/auth/delete-account";
import { getRequestId, jsonWithRequestId, logApiFailure } from "../../../../lib/observability";

export async function POST(request: Request): Promise<Response> {
  const requestId = getRequestId(request);
  const json = (payload: unknown, init?: ResponseInit) => jsonWithRequestId(payload, requestId, init);
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return json({ error: "AUTHENTICATION_REQUIRED" }, { status: 401 });
  }
  const body = await request.json().catch(() => null) as { confirm?: unknown } | null;
  if (body?.confirm !== "HAPUS AKUN SAYA") {
    return json({ error: "CONFIRMATION_REQUIRED" }, { status: 400 });
  }
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publicKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const secretKey = process.env.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !publicKey || !secretKey) {
    logApiFailure("account_deletion_configuration_missing", requestId, new Error("ConfigurationError"));
    return json({ error: "unavailable" }, { status: 503 });
  }
  try {
    const result = await deleteAccountData({ url, publicKey, secretKey, accessToken: authorization.slice(7) });
    return json(result, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    logApiFailure("account_deletion_upstream_failure", requestId, error);
    const unauthenticated = error instanceof Error && error.message === "AUTHENTICATION_REQUIRED";
    return json({ error: unauthenticated ? "AUTHENTICATION_REQUIRED" : "ACCOUNT_DELETION_FAILED" },
      { status: unauthenticated ? 401 : 503 });
  }
}
