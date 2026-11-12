import { getRequestId, jsonWithRequestId } from "../../../lib/observability";

/** Liveness probe only; it deliberately exposes no dependency or configuration details. */
export function GET(request: Request): Response {
  const requestId = getRequestId(request);
  return jsonWithRequestId(
    { status: "ok" },
    requestId,
    { headers: { "Cache-Control": "no-store" } },
  );
}
