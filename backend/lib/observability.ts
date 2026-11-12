import { randomUUID } from "node:crypto";

const REQUEST_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const SAFE_LOG_VALUE_PATTERN = /^[A-Za-z0-9_.-]{1,64}$/;

export function getRequestId(request: Pick<Request, "headers">): string {
  const provided = request.headers.get("x-request-id");
  return provided && REQUEST_ID_PATTERN.test(provided) ? provided : randomUUID();
}

export function jsonWithRequestId(
  payload: unknown,
  requestId: string,
  init: ResponseInit = {},
): Response {
  const headers = new Headers(init.headers);
  headers.set("X-Request-ID", requestId);
  return Response.json(payload, { ...init, headers });
}

/** Logs only structured metadata; never include the error message, request body, or credentials. */
export function logApiFailure(event: string, requestId: string, error: unknown): void {
  const safeEvent = SAFE_LOG_VALUE_PATTERN.test(event) ? event : "api_failure";
  const rawErrorType = error instanceof Error ? error.name : "UnknownError";
  const errorType = SAFE_LOG_VALUE_PATTERN.test(rawErrorType) ? rawErrorType : "Error";

  console.error(JSON.stringify({
    timestamp: new Date().toISOString(),
    level: "error",
    service: "alethia-backend",
    event: safeEvent,
    request_id: requestId,
    error_type: errorType,
  }));
}
