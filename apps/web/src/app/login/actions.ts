"use server";

import { redirect } from "next/navigation";
import { getDataMode } from "@/lib/config";
import { createSupabaseSessionClient } from "@/lib/supabase-session";

export async function signIn(formData: FormData) {
  if (getDataMode() !== "api") redirect("/");
  const email = formData.get("email");
  const password = formData.get("password");
  if (typeof email !== "string" || !email.trim() || typeof password !== "string" || !password) {
    redirect("/login?error=credentials");
  }

  const supabase = await createSupabaseSessionClient(true);
  const { data, error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
  if (error || !data.session) redirect("/login?error=credentials");
  redirect("/");
}

export async function signOut() {
  if (getDataMode() !== "api") redirect("/");
  const supabase = await createSupabaseSessionClient(true);
  // Leave the user's session on other devices, including Android, signed in.
  const { error } = await supabase.auth.signOut({ scope: "local" });
  if (error) redirect("/login?error=signout");
  redirect("/login");
}
