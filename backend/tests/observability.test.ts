import assert from "node:assert/strict";
import test from "node:test";
import { getRequestId, jsonWithRequestId, logApiFailure } from "../lib/observability";

test("request IDs accept safe correlation IDs and replace invalid values", () => {
  const accepted = getRequestId(new Request("http://alethia.test", {
    headers: { "x-request-id": "mobile-request_7.2" },
  }));
  assert.equal(accepted, "mobile-request_7.2");

  const generated = getRequestId(new Request("http://alethia.test", {
    headers: { "x-request-id": "bad request with spaces" },
  }));
  assert.match(generated, /^[0-9a-f-]{36}$/);
});

test("JSON responses return the correlation ID without changing the response body", async () => {
  const response = jsonWithRequestId({ status: "ok" }, "req-42", {
    headers: { "Cache-Control": "no-store" },
  });

  assert.equal(response.headers.get("x-request-id"), "req-42");
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), { status: "ok" });
});

test("structured failure logs omit raw error messages", () => {
  const originalError = console.error;
  let record = "";
  console.error = (...values: unknown[]) => { record = values.join(" "); };
  try {
    logApiFailure("username_login_upstream_failure", "req-55", new Error("private email and token"));
  } finally {
    console.error = originalError;
  }

  const parsed = JSON.parse(record) as Record<string, string>;
  assert.equal(parsed.event, "username_login_upstream_failure");
  assert.equal(parsed.request_id, "req-55");
  assert.equal(parsed.error_type, "Error");
  assert.equal(record.includes("private email and token"), false);
});
