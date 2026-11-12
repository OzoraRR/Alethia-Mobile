import "server-only";
import { callAdminRpcWithConfig } from "./rpc-client";
export { AdminRpcError } from "./rpc-client";

export async function callAdminRpc<T>(
  name: string,
  body: Record<string, unknown>,
): Promise<T | null> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) {
    throw new Error("Supabase server environment is not configured.");
  }

  return callAdminRpcWithConfig({ url, key }, name, body);
}
