import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";
import { supabaseAdminKeyHeaders } from "../lib/admin/rpc-headers";
import { callAdminRpcWithConfig } from "../lib/admin/rpc-client";
import { createUsernameLoginHandler } from "../lib/auth/username-login";

const enabled = process.env.ALETHIA_LOCAL_AUTH_TEST === "1";

test("local Supabase signup creates a username profile and username login returns a valid Auth session", {
  skip: !enabled,
}, async () => {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  const secretKey = process.env.SUPABASE_SECRET_KEY;
  const serviceRoleKey = process.env.ALETHIA_LOCAL_SERVICE_ROLE_KEY;

  assert.ok(supabaseUrl && publishableKey && secretKey && serviceRoleKey, "local Supabase test config is incomplete");
  const parsedUrl = new URL(supabaseUrl);
  assert.ok(
    parsedUrl.hostname === "127.0.0.1" || parsedUrl.hostname === "localhost" || parsedUrl.hostname === "::1",
    "refusing to run this test against a non-local Supabase URL",
  );

  const email = `alethia-test-${randomUUID()}@example.com`;
  const username = `alethia_${randomUUID().replaceAll("-", "").slice(0, 14)}`;
  const password = `Alethia-local-${randomUUID()}!1A`;
  const localFetch: typeof fetch = (input, init) => fetch(input, {
    ...init,
    signal: init?.signal ?? AbortSignal.timeout(15_000),
  });
  let userId: string | null = null;

  try {
    const signupResponse = await localFetch(`${supabaseUrl}/auth/v1/signup`, {
      method: "POST",
      headers: {
        apikey: publishableKey,
        Authorization: `Bearer ${publishableKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ email, password, data: { username } }),
    });
    const signup = await signupResponse.json().catch(() => null) as {
      user?: { id?: unknown } | null;
    } | null;
    assert.equal(signupResponse.status, 200, "local Supabase signup did not succeed");
    if (typeof signup?.user?.id !== "string") {
      throw new Error("signup did not return a user id");
    }
    userId = signup.user.id;

    const handler = createUsernameLoginHandler({
      getConfig: () => ({ url: supabaseUrl, publishableKey }),
      resolveEmail: (requestedUsername) => callAdminRpcWithConfig<string>(
        { url: supabaseUrl, key: secretKey, fetch: localFetch },
        "get_profile_email_by_username",
        { requested_username: requestedUsername },
      ),
      fetch: localFetch,
    });

    const loginResponse = await handler(new Request("http://alethia.test/api/auth/username-login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: username.toUpperCase(), password }),
    }));
    assert.equal(loginResponse.status, 200, "username login failed against local Supabase Auth");
    const session = await loginResponse.json() as { access_token?: unknown; refresh_token?: unknown };
    assert.equal(typeof session.access_token, "string");
    assert.equal(typeof session.refresh_token, "string");
    assert.equal("email" in session, false, "private email leaked into the client session response");

    const identityResponse = await localFetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: publishableKey, Authorization: `Bearer ${session.access_token}` },
    });
    const identity = await identityResponse.json().catch(() => null) as { id?: unknown } | null;
    assert.equal(identityResponse.status, 200, "returned access token was not accepted by local Supabase Auth");
    assert.equal(identity?.id, userId);

    const rejectedLogin = await handler(new Request("http://alethia.test/api/auth/username-login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, password: `${password}-wrong` }),
    }));
    assert.equal(rejectedLogin.status, 401, "incorrect password was not rejected");
    assert.deepEqual(await rejectedLogin.json(), { error: "invalid_credentials" });
  } finally {
    if (userId) {
      const deletionResponse = await localFetch(`${supabaseUrl}/auth/v1/admin/users/${userId}`, {
        method: "DELETE",
        headers: supabaseAdminKeyHeaders(serviceRoleKey),
      });
      assert.ok(deletionResponse.ok, "failed to remove the temporary local Auth user");
    }
  }
});
