/**
 * Supabase's newer API keys are opaque strings and belong only in `apikey`.
 * Legacy service-role keys are JWTs and also need the Authorization header.
 */
export function supabaseAdminKeyHeaders(key: string): Record<string, string> {
  const headers: Record<string, string> = { apikey: key };
  const parts = key.split(".");

  if (parts.length === 3 && parts.every(Boolean)) {
    headers.Authorization = `Bearer ${key}`;
  }

  return headers;
}
