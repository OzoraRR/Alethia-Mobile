import { getRequestId, jsonWithRequestId, logApiFailure } from "../observability";

export type UsernameLoginConfig = {
  url: string;
  publishableKey: string;
};

type UsernameLoginDependencies = {
  getConfig: () => UsernameLoginConfig | null;
  resolveEmail: (username: string) => Promise<string | null>;
  fetch?: typeof fetch;
  logFailure?: typeof logApiFailure;
};

/** Build the username sign-in HTTP handler with injectable Supabase boundaries. */
export function createUsernameLoginHandler({
  getConfig,
  resolveEmail,
  fetch: fetchImpl = fetch,
  logFailure = logApiFailure,
}: UsernameLoginDependencies) {
  return async function POST(request: Request): Promise<Response> {
    const requestId = getRequestId(request);
    const json = (payload: unknown, init?: ResponseInit) => jsonWithRequestId(payload, requestId, init);
    const contentLength = Number(request.headers.get("content-length"));
    if (Number.isFinite(contentLength) && contentLength > 2048) {
      return json({ error: "invalid_credentials" }, { status: 400 });
    }

    const rawBody = await request.text();
    if (new TextEncoder().encode(rawBody).byteLength > 2048) {
      return json({ error: "invalid_credentials" }, { status: 400 });
    }

    let body: { username?: unknown; password?: unknown } | null;
    try {
      body = JSON.parse(rawBody || "null") as { username?: unknown; password?: unknown } | null;
    } catch {
      return json({ error: "invalid_credentials" }, { status: 400 });
    }

    if (
      typeof body?.username !== "string" ||
      typeof body.password !== "string" ||
      body.username.trim().length > 24 ||
      body.password.length < 1 ||
      body.password.length > 200
    ) {
      return json({ error: "invalid_credentials" }, { status: 400 });
    }

    const username = body.username.trim().toLowerCase();
    if (!/^[a-z0-9_]{3,24}$/.test(username)) {
      return json({ error: "invalid_credentials" }, { status: 401 });
    }

    const config = getConfig();
    if (!config) {
      return json({ error: "unavailable" }, { status: 503 });
    }

    try {
      const email = await resolveEmail(username);

      // The private email is used only for the server-to-Supabase Auth exchange.
      if (!email || typeof email !== "string") {
        return json({ error: "invalid_credentials" }, { status: 401 });
      }

      const authResponse = await fetchImpl(`${config.url}/auth/v1/token?grant_type=password`, {
        method: "POST",
        headers: {
          apikey: config.publishableKey,
          Authorization: `Bearer ${config.publishableKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ email, password: body.password }),
        cache: "no-store",
      });

      if (authResponse.status === 429) {
        return json({ error: "rate_limited" }, { status: 429 });
      }

      const session = (await authResponse.json().catch(() => null)) as {
        access_token?: unknown;
        refresh_token?: unknown;
        expires_in?: unknown;
        token_type?: unknown;
      } | null;
      if (
        !authResponse.ok ||
        typeof session?.access_token !== "string" ||
        typeof session.refresh_token !== "string"
      ) {
        return json({ error: "invalid_credentials" }, { status: 401 });
      }

      return json(
        {
          access_token: session.access_token,
          refresh_token: session.refresh_token,
          expires_in: typeof session.expires_in === "number" && Number.isFinite(session.expires_in)
            ? session.expires_in
            : 3600,
          token_type: typeof session.token_type === "string" && session.token_type.trim()
            ? session.token_type
            : "bearer",
        },
        { headers: { "Cache-Control": "no-store" } },
      );
    } catch (error) {
      logFailure("username_login_upstream_failure", requestId, error);
      return json({ error: "unavailable" }, { status: 503 });
    }
  };
}
