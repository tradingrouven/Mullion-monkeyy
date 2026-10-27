// Bullion Monkey push server (Cloudflare Worker).
// The app registers its web-push subscription here; MT5 (the EA) and a once-a-minute timer send pushes through it.
//   GET  /key             VAPID public key for the app
//   POST /sub             {key, sub, prefs}   store or update a phone (key = random id made by the app)
//   POST /unsub           {key}
//   POST /push/<key>      {title?, body, url?}   from the EA
//   POST /test/<key>      test push from the app
//   GET  /alarms/<key>    price alarms set in the app (read by the EA, which checks the price) + the ones already hit
//   GET  /sentiment       share of Myfxbook traders long/short on gold (needs worker secrets MYFXBOOK_EMAIL/PASSWORD)
//   POST /hit/<key>       {id}   the EA reports an alarm it fired; it is not handed out again
// Every minute: reminders before red USD news and before news the user starred, and session open/close.
// The VAPID key pair is made on first use and kept in KV, so nothing needs to be configured.

const APP = "https://tradingrouven.github.io/Mullion-monkeyy/";
const NEWS = APP + "news.json";
const CORS = { "access-control-allow-origin": "*", "access-control-allow-methods": "GET,POST,OPTIONS", "access-control-allow-headers": "content-type" };

export default {
  async fetch(req, env) {
    if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
    const url = new URL(req.url), p = url.pathname.split("/").filter(Boolean);
    try {
      if (req.method === "GET" && p[0] === "key") return json({ publicKey: (await vapid(env)).pub });
      if (req.method === "GET" && p[0] === "alarms" && validKey(p[1])) {
        const rec = await env.SUBS.get("s:" + p[1], "json"), hit = (await env.SUBS.get("h:" + p[1], "json")) || [];
        const all = ((rec && rec.prefs && rec.prefs.alarms) || []).filter(a => a && a.id && +a.p > 0);
        return json({ alarms: all.filter(a => !hit.includes(a.id)), hit });
      }
      if (req.method === "GET" && p[0] === "sentiment") return json(await sentiment(env));
      if (req.method !== "POST") return json({ ok: true, name: "Bullion Monkey Push" });
      const body = await req.json().catch(() => ({}));
      if (p[0] === "sub") {
        if (!validKey(body.key) || !body.sub || !body.sub.endpoint) return json({ error: "bad request" }, 400);
        await env.SUBS.put("s:" + body.key, JSON.stringify({ sub: body.sub, prefs: body.prefs || {}, at: Date.now() }));
        return json({ ok: true });
      }
      if (p[0] === "hit" && validKey(p[1]) && typeof body.id === "string") {
        const hit = (await env.SUBS.get("h:" + p[1], "json")) || [];
        if (!hit.includes(body.id)) hit.push(body.id);
        await env.SUBS.put("h:" + p[1], JSON.stringify(hit.slice(-200)));
        return json({ ok: true });
      }
      if (p[0] === "unsub") { if (validKey(body.key)) await env.SUBS.delete("s:" + body.key); return json({ ok: true }); }
      if ((p[0] === "push" || p[0] === "test") && validKey(p[1])) {
        const rec = await env.SUBS.get("s:" + p[1], "json");
        if (!rec) return json({ error: "unknown key" }, 404);
        const msg = p[0] === "test"
          ? { title: "Bullion Monkey", body: "Test: Push-Nachrichten funktionieren ✓", url: APP }
          : { title: String(body.title || "Bullion Monkey").slice(0, 80), body: String(body.body || "").slice(0, 400), url: body.url || APP + (body.journal ? "#journal" : "") };
        const r = await send(env, p[1], rec.sub, msg);
        return json({ ok: r < 300, status: r }, r < 300 ? 200 : 502);
      }
      return json({ error: "not found" }, 404);
    } catch (e) {
      return json({ error: String(e && e.message || e) }, 500);
    }
  },

  async scheduled(ev, env, ctx) { ctx.waitUntil(Promise.all([newsReminders(env), sessionPushes(env)])); }
};

const json = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json", ...CORS } });
const validKey = k => typeof k === "string" && /^[A-Za-z0-9_-]{16,64}$/.test(k);

/* ---------- gold sentiment: Myfxbook community outlook (official API, kept 15 min) ---------- */
async function sentiment(env) {
  if (!env.MYFXBOOK_EMAIL || !env.MYFXBOOK_PASSWORD) return { error: "setup" };
  const cached = await env.SUBS.get("sentiment", "json");
  if (cached && Date.now() - cached.at < 15 * 60000) return cached;
  const API = "https://www.myfxbook.com/api/";
  const login = async () => {
    const r = await (await fetch(API + "login.json?email=" + encodeURIComponent(env.MYFXBOOK_EMAIL) + "&password=" + encodeURIComponent(env.MYFXBOOK_PASSWORD))).json();
    if (r.error || !r.session) throw new Error(r.message || "login");
    await env.SUBS.put("mfx-session", r.session);
    return r.session;
  };
  try {
    let session = await env.SUBS.get("mfx-session") || await login();
    const get = s => fetch(API + "get-community-outlook.json?session=" + encodeURIComponent(decodeURIComponent(s))).then(r => r.json());
    let o = await get(session);
    if (o.error) o = await get(await login());   // session expired
    const g = (o.symbols || []).find(x => x.name === "XAUUSD");
    if (!g) throw new Error(o.message || "no XAUUSD");
    const out = { at: Date.now(), long: +g.longPercentage, short: +g.shortPercentage, longPrice: +g.avgLongPrice, shortPrice: +g.avgShortPrice, positions: +g.totalPositions };
    await env.SUBS.put("sentiment", JSON.stringify(out));
    return out;
  } catch (e) {
    return cached || { error: String(e && e.message || e) };
  }
}

/* ---------- news reminders ---------- */
async function newsReminders(env) {
  const list = await env.SUBS.list({ prefix: "s:" });
  if (!list.keys.length) return;
  let events = [];
  try { const r = await fetch(NEWS + "?t=" + Date.now(), { cf: { cacheTtl: 300 } }); events = (await r.json()).events || []; } catch { }
  const now = Date.now();
  for (const k of list.keys) {
    const key = k.name.slice(2), rec = await env.SUBS.get(k.name, "json");
    if (!rec) continue;
    const pr = rec.prefs || {}, mins = Math.max(1, Math.min(120, +pr.minutes || 15));
    const due = [];
    if (pr.news !== false)
      for (const e of events) if (e.country === "USD" && (e.impact === "High" || (pr.medium && e.impact === "Medium"))) due.push({ id: e.country + "|" + e.date + "|" + e.title, t: Date.parse(e.date), title: e.title, country: e.country, impact: e.impact, forecast: e.forecast });
    for (const s of pr.stars || []) if (s && s.id && s.t) due.push({ id: s.id, t: Date.parse(s.t), title: s.title, country: s.country, star: true });
    for (const e of due) {
      const left = e.t - now;
      if (!(left > 0 && left <= mins * 60000)) continue;
      const seen = "n:" + key + ":" + (await hash(e.id));
      if (await env.SUBS.get(seen)) continue;
      await env.SUBS.put(seen, "1", { expirationTtl: 86400 * 3 });
      const m = Math.round(left / 60000);
      const st = await send(env, key, rec.sub, {
        title: (e.star ? "★ " : "🔴 ") + (e.country || "") + " " + e.title,
        body: `In ${m} Min.` + (e.star ? " · markierte News" : " · hohes Risiko für Gold") + (e.forecast ? ` · Prognose ${e.forecast}` : ""),
        url: APP + "#news", tag: "news"
      });
      if (st === 404 || st === 410) break;
    }
  }
}

/* ---------- trading sessions: Rouven's windows in Swiss time ---------- */
const SESSIONS = [["London", 9 * 60, 12 * 60], ["New York", 14 * 60 + 30, 18 * 60 + 30]];
const hm = m => String(Math.floor(m / 60)).padStart(2, "0") + ":" + String(m % 60).padStart(2, "0");
async function sessionPushes(env) {
  const o = {};
  for (const x of new Intl.DateTimeFormat("en-US", { timeZone: "Europe/Zurich", hourCycle: "h23", weekday: "short", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(new Date())) o[x.type] = x.value;
  if (o.weekday === "Sat" || o.weekday === "Sun") return;
  const min = +o.hour * 60 + +o.minute, due = [];
  for (const [name, open, close] of SESSIONS)
    for (const [what, at] of [["open", open], ["close", close]])
      if (min - at >= 0 && min - at < 3) due.push({ name, what, open, close, id: name + ":" + what + ":" + o.year + o.month + o.day });   // 3 min window in case a timer run is skipped
  if (!due.length) return;
  const list = await env.SUBS.list({ prefix: "s:" });
  for (const k of list.keys) {
    const key = k.name.slice(2), rec = await env.SUBS.get(k.name, "json");
    const want = rec && rec.prefs && rec.prefs.sess;
    if (!Array.isArray(want)) continue;
    for (const s of due) {
      if (!want.includes(s.name)) continue;
      const seen = "x:" + key + ":" + s.id;
      if (await env.SUBS.get(seen)) continue;
      await env.SUBS.put(seen, "1", { expirationTtl: 86400 * 2 });
      const start = s.what === "open";
      const st = await send(env, key, rec.sub, {
        title: (start ? "🟢 " : "⚪️ ") + s.name + (start ? " Session startet" : " Session endet"),
        body: start ? `Dein Handelsfenster bis ${hm(s.close)} Uhr ist offen.` : `Handelsfenster ${hm(s.open)}–${hm(s.close)} Uhr ist vorbei.`,
        url: APP, tag: "sess"
      });
      if (st === 404 || st === 410) break;
    }
  }
}

/* ---------- web push (RFC 8291 + VAPID, RFC 8292) ---------- */
async function send(env, key, sub, msg) {
  const v = await vapid(env);
  const ep = new URL(sub.endpoint);
  const jwt = await signJwt(v, { aud: ep.origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: "mailto:push@bullion-monkey.app" });
  const body = await encrypt(JSON.stringify(msg), sub.keys.p256dh, sub.keys.auth);
  const headers = { authorization: `vapid t=${jwt}, k=${v.pub}`, "content-encoding": "aes128gcm", "content-type": "application/octet-stream", ttl: "3600", urgency: "high" };
  if (msg.tag) headers.topic = msg.tag;
  const r = await fetch(sub.endpoint, { method: "POST", body, headers });
  if (r.status === 404 || r.status === 410) await env.SUBS.delete("s:" + key);   // phone unsubscribed
  return r.status;
}

async function vapid(env) {
  let v = await env.SUBS.get("vapid", "json");
  if (!v) {
    const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    v = { jwk: await crypto.subtle.exportKey("jwk", kp.privateKey), pub: b64u(await crypto.subtle.exportKey("raw", kp.publicKey)) };
    await env.SUBS.put("vapid", JSON.stringify(v));
  }
  return v;
}

async function signJwt(v, claims) {
  const enc = o => b64u(new TextEncoder().encode(JSON.stringify(o)));
  const data = enc({ typ: "JWT", alg: "ES256" }) + "." + enc(claims);
  const k = await crypto.subtle.importKey("jwk", v.jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, k, new TextEncoder().encode(data));
  return data + "." + b64u(sig);
}

export async function encrypt(text, p256dh, authSecret) {
  const uaPub = unb64u(p256dh), auth = unb64u(authSecret);
  const as = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const asPub = new Uint8Array(await crypto.subtle.exportKey("raw", as.publicKey));
  const ua = await crypto.subtle.importKey("raw", uaPub, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: ua }, as.privateKey, 256));
  const te = new TextEncoder();
  const ikm = await hkdf(auth, shared, cat(te.encode("WebPush: info\0"), uaPub, asPub), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, te.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, te.encode("Content-Encoding: nonce\0"), 12);
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, cat(te.encode(text), new Uint8Array([2]))));
  const head = new Uint8Array(21); head.set(salt); new DataView(head.buffer).setUint32(16, 4096); head[20] = asPub.length;
  return cat(head, asPub, ct);
}

async function hkdf(salt, ikm, info, len) {
  const k = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, len * 8));
}
async function hash(s) { return b64u(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))).slice(0, 22); }
function cat(...a) { const o = new Uint8Array(a.reduce((n, x) => n + x.length, 0)); let i = 0; for (const x of a) { o.set(x, i); i += x.length; } return o; }
function b64u(buf) { const b = new Uint8Array(buf); let s = ""; for (const c of b) s += String.fromCharCode(c); return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); }
function unb64u(s) { s = s.replace(/-/g, "+").replace(/_/g, "/"); const b = atob(s + "===".slice((s.length + 3) % 4)); return Uint8Array.from(b, c => c.charCodeAt(0)); }
