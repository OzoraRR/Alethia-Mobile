import { supabaseAdminKeyHeaders } from "../admin/rpc-headers";

type DeletionConfig = {
  url: string;
  publicKey: string;
  secretKey: string;
  accessToken: string;
};

/** The caller's JWT scopes the RPCs; the server key is used only for object removal. */
export async function deleteAccountData(config: DeletionConfig, request: typeof fetch = fetch) {
  const userHeaders = { apikey: config.publicKey, Authorization: `Bearer ${config.accessToken}` };
  const identity = await request(`${config.url}/auth/v1/user`, { headers: userHeaders, cache: "no-store" });
  const user = await identity.json().catch(() => null) as { id?: unknown; is_anonymous?: unknown } | null;
  if (!identity.ok || typeof user?.id !== "string" || user.is_anonymous !== false) {
    throw new Error("AUTHENTICATION_REQUIRED");
  }
  const rpc = async (name: string) => {
    const response = await request(`${config.url}/rest/v1/rpc/${name}`, {
      method: "POST", headers: { ...userHeaders, "Content-Type": "application/json" },
      body: JSON.stringify({ requested_confirm: "HAPUS AKUN SAYA" }), cache: "no-store",
    });
    const data: unknown = await response.json().catch(() => null);
    if (!response.ok) throw new Error("ACCOUNT_DELETION_FAILED");
    return data;
  };
  // Preparation freezes uploads and returns every historical avatar path, including
  // abandoned uploads. Repeating this after a partial failure is safe.
  const paths = await rpc("prepare_account_deletion");
  if (!Array.isArray(paths) || !paths.every((path): path is string =>
    typeof path === "string" && path.startsWith(`${user.id}/`) && !path.split("/").includes(".."))) {
    throw new Error("ACCOUNT_DELETION_FAILED");
  }
  for (let start = 0; start < paths.length; start += 1000) {
    const response = await request(`${config.url}/storage/v1/object/avatars`, {
      method: "DELETE", headers: { ...supabaseAdminKeyHeaders(config.secretKey), "Content-Type": "application/json" },
      body: JSON.stringify({ prefixes: paths.slice(start, start + 1000) }), cache: "no-store",
    });
    if (!response.ok) throw new Error("ACCOUNT_DELETION_FAILED");
  }
  // The RPC refuses deletion if any avatar metadata remains, allowing retry when
  // an upload was already in flight when preparation froze new uploads.
  return rpc("delete_my_account");
}
