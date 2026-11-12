import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import test from "node:test";
import { callAdminRpcWithConfig } from "../lib/admin/rpc-client";
import { createUsernameLoginHandler } from "../lib/auth/username-login";

type ReceivedRequest = {
  path: string;
  apikey: string | undefined;
  authorization: string | undefined;
  body: Record<string, unknown>;
};

function respond(response: ServerResponse, status: number, body: unknown) {
  response.writeHead(status, { "Content-Type": "application/json" });
  response.end(JSON.stringify(body));
}

async function readBody(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(Buffer.from(chunk));
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>;
}

async function listen(server: ReturnType<typeof createServer>): Promise<string> {
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  assert.ok(address && typeof address === "object");
  return `http://127.0.0.1:${address.port}`;
}

async function close(server: ReturnType<typeof createServer>): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
}

function post(body: string): Request {
  return new Request("http://alethia.test/api/auth/username-login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });
}

test("username login exchanges a private username lookup for a Supabase Auth session", async (t) => {
  const received: ReceivedRequest[] = [];
  const server = createServer((request, response) => {
    void readBody(request).then((body) => {
      received.push({
        path: request.url ?? "",
        apikey: request.headers.apikey?.toString(),
        authorization: request.headers.authorization?.toString(),
        body,
      });

      if (request.url === "/rest/v1/rpc/get_profile_email_by_username") {
        assert.equal(body.requested_username, "rani_7");
        respond(response, 200, "rani@example.test");
      } else if (request.url === "/auth/v1/token?grant_type=password") {
        assert.equal(body.email, "rani@example.test");
        assert.equal(body.password, "correct-password");
        respond(response, 200, {
          access_token: "test-access-token",
          refresh_token: "test-refresh-token",
          expires_in: 1800,
          token_type: "bearer",
        });
      } else {
        respond(response, 404, { message: "not found" });
      }
    }).catch(() => respond(response, 500, { message: "test server error" }));
  });
  const url = await listen(server);
  t.after(() => close(server));

  const publicKey = "sb_publishable_test-key";
  const secretKey = "sb_secret_test-key";
  const handler = createUsernameLoginHandler({
    getConfig: () => ({ url, publishableKey: publicKey }),
    resolveEmail: (username) => callAdminRpcWithConfig<string>(
      { url, key: secretKey },
      "get_profile_email_by_username",
      { requested_username: username },
    ),
  });

  const response = await handler(post(JSON.stringify({ username: " Rani_7 ", password: "correct-password" })));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), {
    access_token: "test-access-token",
    refresh_token: "test-refresh-token",
    expires_in: 1800,
    token_type: "bearer",
  });

  assert.equal(received.length, 2);
  assert.equal(received[0]?.path, "/rest/v1/rpc/get_profile_email_by_username");
  assert.equal(received[0]?.apikey, secretKey);
  assert.equal(received[0]?.body.password, undefined);
  assert.equal(received[1]?.path, "/auth/v1/token?grant_type=password");
  assert.equal(received[1]?.apikey, publicKey);
  assert.equal(received[1]?.authorization, `Bearer ${publicKey}`);
  assert.equal(received[1]?.body.email, "rani@example.test");
});

test("unknown username and rejected password return the same generic response", async () => {
  const config = { url: "http://supabase.test", publishableKey: "public-key" };
  const unknownUser = createUsernameLoginHandler({
    getConfig: () => config,
    resolveEmail: async () => null,
    fetch: async () => { throw new Error("Auth must not be called for an unknown username"); },
  });
  const invalidPassword = createUsernameLoginHandler({
    getConfig: () => config,
    resolveEmail: async () => "private@example.test",
    fetch: async () => Response.json({ msg: "Invalid login credentials" }, { status: 400 }),
  });

  const unknownResponse = await unknownUser(post(JSON.stringify({ username: "someone", password: "bad-password" })));
  const passwordResponse = await invalidPassword(post(JSON.stringify({ username: "someone", password: "bad-password" })));
  assert.equal(unknownResponse.status, 401);
  assert.equal(passwordResponse.status, 401);
  assert.deepEqual(await unknownResponse.json(), { error: "invalid_credentials" });
  assert.deepEqual(await passwordResponse.json(), { error: "invalid_credentials" });
});

test("username login validates bounded input before making Supabase calls", async () => {
  let lookupCalls = 0;
  const handler = createUsernameLoginHandler({
    getConfig: () => ({ url: "http://supabase.test", publishableKey: "public-key" }),
    resolveEmail: async () => { lookupCalls += 1; return "private@example.test"; },
    fetch: async () => { throw new Error("Auth must not be called for invalid input"); },
  });

  const invalidJson = await handler(post("{"));
  const invalidFields = await handler(post(JSON.stringify({ username: "ab", password: "pw" })));
  const oversized = await handler(post(JSON.stringify({ username: "someone", password: "x".repeat(2100) })));

  assert.equal(invalidJson.status, 400);
  assert.equal(invalidFields.status, 401);
  assert.equal(oversized.status, 400);
  assert.equal(lookupCalls, 0);
});

test("Auth rate limiting is surfaced without exposing account information", async () => {
  const handler = createUsernameLoginHandler({
    getConfig: () => ({ url: "http://supabase.test", publishableKey: "public-key" }),
    resolveEmail: async () => "private@example.test",
    fetch: async () => Response.json({ message: "rate limit" }, { status: 429 }),
  });

  const response = await handler(post(JSON.stringify({ username: "someone", password: "password" })));
  assert.equal(response.status, 429);
  assert.deepEqual(await response.json(), { error: "rate_limited" });
});
