import { createHmac } from "node:crypto";
import { isIP } from "node:net";
import { callAdminRpc } from "../../../../lib/admin/server";
import { createUsernameLoginHandler } from "../../../../lib/auth/username-login";

/**
 * Username login resolves the private email only on the server. The mobile
 * client receives session tokens only after Supabase Auth verifies the password;
 * it never receives an email address for a username guess.
 */
export const POST = createUsernameLoginHandler({
  getConfig: () => {
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const publishableKey =
      process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    return url && publishableKey ? { url, publishableKey } : null;
  },
  consumeRateLimit: async (request) => {
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const serverKey = process.env.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!supabaseUrl || !serverKey) {
      throw new Error("Supabase server environment is not configured.");
    }

    // Vercel overwrites X-Forwarded-For with the public client IP. Outside
    // Vercel, requests without a valid forwarded address share one fallback bucket.
    const forwardedFor = request.headers.get("x-forwarded-for")?.split(",", 1)[0]?.trim();
    const clientIp = forwardedFor && isIP(forwardedFor) ? forwardedFor : "unknown";
    const identityHash = createHmac("sha256", serverKey)
      .update(`alethia:username-login:ip:v1:${clientIp}`)
      .digest("hex");

    const result = await callAdminRpc<Array<{
      allowed: boolean;
      retry_after_seconds: number;
    }>>("consume_username_login_rate_limit", {
      requested_identity_hash: identityHash,
    });
    const rateLimit = result?.[0];
    if (
      !rateLimit ||
      typeof rateLimit.allowed !== "boolean" ||
      typeof rateLimit.retry_after_seconds !== "number" ||
      !Number.isFinite(rateLimit.retry_after_seconds)
    ) {
      throw new Error("Supabase returned an invalid username login rate-limit result.");
    }

    return {
      allowed: rateLimit.allowed,
      retryAfterSeconds: rateLimit.retry_after_seconds,
    };
  },
  resolveEmail: (username) => callAdminRpc<string>("get_profile_email_by_username", {
    requested_username: username,
  }),
});
