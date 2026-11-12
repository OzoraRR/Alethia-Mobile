import { callAdminRpc } from "../../../../lib/admin/server";
import { createUsernameLoginHandler } from "../../../../lib/auth/username-login";

/**
 * Username login resolves the private email only on the server. The mobile
 * client receives session tokens only after Supabase Auth verifies the password;
 * it never receives an email address for a username guess.
 */
export const POST = createUsernameLoginHandler({
  getConfig: () => {
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const publishableKey =
      process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    return url && publishableKey ? { url, publishableKey } : null;
  },
  resolveEmail: (username) => callAdminRpc<string>("get_profile_email_by_username", {
    requested_username: username,
  }),
});
