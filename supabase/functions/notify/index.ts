// phodo `notify` — sends push notifications through Apple (APNs).
//
// The app calls this right after something happens:
//   { "type": "post",    "post_id": "<uuid>" }   → all the poster's friends (minus muted)
//   { "type": "request", "to": "<uuid>" }        → "@you wants to be friends"
//   { "type": "accept",  "to": "<uuid>" }        → "@you accepted your request"
//
// The caller must be signed in (JWT verified by Supabase). Everything is
// re-checked here with the database, so the app can't spam anyone.
//
// Secrets (set once with `npx supabase secrets set`, never committed):
//   APNS_KEY_ID       10-character key ID from developer.apple.com → Keys
//   APNS_TEAM_ID      PRRWSX8GBA
//   APNS_PRIVATE_KEY  contents of the AuthKey_XXXXXXXXXX.p8 file
//   APNS_TOPIC        app.phodo (optional, this is the default)

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { importPKCS8, SignJWT } from "npm:jose@5.9.6";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const PRIVATE_KEY = (Deno.env.get("APNS_PRIVATE_KEY") ?? "").replace(/\\n/g, "\n");
const TOPIC = Deno.env.get("APNS_TOPIC") ?? "app.phodo";

const admin = createClient(SUPABASE_URL, SERVICE_KEY);

// ── Apple auth token (valid up to 1h; reuse for 50 min) ──
let cached: { jwt: string; at: number } | null = null;
async function apnsJWT(): Promise<string> {
  if (cached && Date.now() - cached.at < 50 * 60 * 1000) return cached.jwt;
  const key = await importPKCS8(PRIVATE_KEY, "ES256");
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: KEY_ID })
    .setIssuer(TEAM_ID)
    .setIssuedAt()
    .sign(key);
  cached = { jwt, at: Date.now() };
  return jwt;
}

type Alert = { title: string; body: string; data?: Record<string, string> };

async function pushTo(userIDs: string[], alert: Alert): Promise<number> {
  if (userIDs.length === 0) return 0;
  const { data: tokens } = await admin.from("push_tokens").select("token, sandbox").in("user_id", userIDs);
  if (!tokens?.length) return 0;
  const jwt = await apnsJWT();
  let sent = 0;
  await Promise.all(tokens.map(async ({ token, sandbox }) => {
    const host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const res = await fetch(`https://${host}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        aps: { alert: { title: alert.title, body: alert.body }, sound: "default", "thread-id": alert.data?.kind ?? "phodo" },
        ...alert.data,
      }),
    });
    if (res.ok) { sent++; return; }
    const why = await res.text();
    console.log("apns", res.status, why);
    // phone uninstalled phodo / token no longer valid → forget it
    if (res.status === 410 || why.includes("BadDeviceToken") || why.includes("Unregistered")) {
      await admin.from("push_tokens").delete().eq("token", token);
    }
  }));
  return sent;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (!KEY_ID || !TEAM_ID || !PRIVATE_KEY) return json({ error: "push not configured yet" }, 503);

  // who is calling?
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await asCaller.auth.getUser();
  if (!user) return json({ error: "sign in first" }, 401);

  const { data: me } = await admin.from("profiles").select("username").eq("id", user.id).single();
  const name = `@${me?.username ?? "someone"}`;
  const body = await req.json().catch(() => ({}));

  // someone posted → their friends
  if (body.type === "post" && body.post_id) {
    const { data: post } = await admin.from("posts").select("id, user_id, caption, visibility")
      .eq("id", body.post_id).single();
    if (!post || post.user_id !== user.id || post.visibility === "private") return json({ sent: 0 });
    // every friend gets it, unless they muted this person from their profile
    const { data: links } = await admin.from("friendships").select("requester, addressee")
      .eq("status", "accepted").or(`requester.eq.${user.id},addressee.eq.${user.id}`);
    const { data: mutes } = await admin.from("post_mutes").select("user_id").eq("friend_id", user.id);
    const muted = new Set((mutes ?? []).map((m) => m.user_id));
    const recipients: string[] = [];
    for (const l of links ?? []) {
      const friend = l.requester === user.id ? l.addressee : l.requester;
      if (muted.has(friend) || recipients.includes(friend)) continue;
      const { data: blocked } = await admin.rpc("is_blocked", { a: friend, b: user.id });
      if (!blocked) recipients.push(friend);
    }
    const caption = (post.caption ?? "").trim();
    const sent = await pushTo(recipients, {
      title: `${name} posted`,
      body: caption ? caption.slice(0, 120) : "a new pic ☾",
      data: { kind: "post", post_id: post.id },
    });
    return json({ sent });
  }

  // friend request sent / accepted
  if ((body.type === "request" || body.type === "accept") && body.to) {
    const status = body.type === "request" ? "pending" : "accepted";
    const [requester, addressee] = body.type === "request" ? [user.id, body.to] : [body.to, user.id];
    const { data: row } = await admin.from("friendships").select("status")
      .eq("requester", requester).eq("addressee", addressee).maybeSingle();
    // merged requests (both added each other) arrive here as "accepted"
    if (!row || (row.status !== status && !(body.type === "request" && row.status === "accepted"))) {
      return json({ sent: 0 });
    }
    const { data: them } = await admin.from("profiles").select("notify_requests").eq("id", body.to).single();
    if (!them?.notify_requests) return json({ sent: 0 });
    const accepted = row.status === "accepted";
    const sent = await pushTo([body.to], {
      title: accepted ? `${name} is your friend now` : `${name} wants to be friends`,
      body: accepted ? "go see their day ✌︎" : "open phodo to say yes",
      data: { kind: "friend", from: user.id },
    });
    return json({ sent });
  }

  return json({ error: "unknown type" }, 400);
});
