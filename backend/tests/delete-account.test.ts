import test from "node:test";
import assert from "node:assert/strict";
import { deleteAccountData } from "../lib/auth/delete-account";

const config = { url: "http://example.invalid", publicKey: "public", secretKey: "server-secret", accessToken: "caller-token" };
const json = (value: unknown, status = 200) => Response.json(value, { status });

test("deletion removes all historical avatars in batches before deleting identity", async () => {
  const calls: string[] = [];
  const paths = Array.from({ length: 1001 }, (_, i) => `owner/avatar-${i}.png`);
  const request: typeof fetch = async (input, init) => {
    const url = String(input); calls.push(url);
    const headers = new Headers(init?.headers);
    if (url.endsWith("/user")) return json({ id: "owner", is_anonymous: false });
    if (url.includes("/storage/")) {
      assert.equal(headers.get("apikey"), config.secretKey);
      const body = JSON.parse(String(init?.body)) as { prefixes: string[] };
      assert.equal(body.prefixes.length, calls.length === 3 ? 1000 : 1);
      return json([]);
    }
    assert.equal(headers.get("Authorization"), "Bearer caller-token");
    assert.equal(headers.get("apikey"), config.publicKey);
    if (url.endsWith("prepare_account_deletion")) return json(paths);
    return json({ account_deleted: true, reports_anonymised: 2 });
  };
  const result = await deleteAccountData(config, request);
  assert.deepEqual(result, { account_deleted: true, reports_anonymised: 2 });
  assert.equal(calls.at(-1), `${config.url}/rest/v1/rpc/delete_my_account`);
});

test("a partial Storage failure leaves identity deletion available for a safe retry", async () => {
  let deleted = false;
  let failure = true;
  const request: typeof fetch = async (input) => {
    const url = String(input);
    if (url.endsWith("/user")) return json({ id: "owner", is_anonymous: false });
    if (url.endsWith("prepare_account_deletion")) return json(["owner/orphan.png"]);
    if (url.includes("/storage/")) return json({}, failure ? 503 : 200);
    deleted = true; return json({ account_deleted: true });
  };
  await assert.rejects(deleteAccountData(config, request), /ACCOUNT_DELETION_FAILED/);
  assert.equal(deleted, false);
  failure = false;
  await deleteAccountData(config, request);
  assert.equal(deleted, true);
});

test("an invalid identity never reaches privileged Storage", async () => {
  let calls = 0;
  await assert.rejects(deleteAccountData(config, async () => {
    calls += 1; return json({ id: "anonymous", is_anonymous: true });
  }), /AUTHENTICATION_REQUIRED/);
  assert.equal(calls, 1);
});

test("a path outside the verified account is never removed", async () => {
  let storageCalled = false;
  await assert.rejects(deleteAccountData(config, async (input) => {
    const url = String(input);
    if (url.endsWith("/user")) return json({ id: "owner", is_anonymous: false });
    if (url.includes("/storage/")) storageCalled = true;
    return json(["another-user/avatar.png"]);
  }), /ACCOUNT_DELETION_FAILED/);
  assert.equal(storageCalled, false);
});
