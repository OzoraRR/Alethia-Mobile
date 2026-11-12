import { supabaseAdminKeyHeaders } from "./rpc-headers";

type AdminRpcConfig = {
  url: string;
  key: string;
  fetch?: typeof fetch;
};

export class AdminRpcError extends Error {
  readonly rpc: string;

  constructor(rpc: string, message: string) {
    super(message);
    this.name = "AdminRpcError";
    this.rpc = rpc;
  }
}

/** Shared server RPC transport, injectable so API/Auth contracts can be tested locally. */
export async function callAdminRpcWithConfig<T>(
  config: AdminRpcConfig,
  name: string,
  body: Record<string, unknown>,
): Promise<T | null> {
  const request = config.fetch ?? fetch;
  const response = await request(`${config.url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      ...supabaseAdminKeyHeaders(config.key),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    cache: "no-store",
  });

  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    const message =
      payload && typeof payload === "object" && "message" in payload
        ? String((payload as { message: unknown }).message)
        : `Admin RPC ${name} failed with ${response.status}.`;
    throw new AdminRpcError(name, message);
  }

  return payload as T;
}
