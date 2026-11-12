/**
 * recipe-import — Supabase Edge Function behind "Add a recipe from a website"
 * on the Meals tab of Family Hub.
 *
 * WHAT IT DOES
 *   Takes a recipe page's address, downloads the page, and returns the recipe
 *   the site publishes for search engines (schema.org "Recipe" data, which most
 *   recipe sites include). A browser can't download another site's page itself
 *   (cross-origin rules block it), which is why this runs on the server.
 *   No AI and no API key: if a page doesn't publish recipe data, the caller is
 *   told so and can type the recipe or add a photo instead.
 *
 * ORDER OF OPERATIONS (cheapest check first)
 *   1. Origin + method check   — no I/O
 *   2. Read the body (capped)  — refuses oversized requests before parsing
 *   3. Validate the link       — pure CPU; blocks private / internal addresses
 *   4. Family gate             — one small database call
 *   5. Download + parse page   — the only step that talks to the outside world
 *
 * DEPENDS ON
 *   - Env SUPABASE_URL — injected by Supabase into every Edge Function.
 *   - Postgres functions created by CLOUD_SETUP_SQL in family-hub-app/index.html:
 *       fh_me()               signed-in (Google) member path; needs the user's JWT
 *       family_hub_meta(fid)  family-code path; executable with the public key
 *     If either is missing or errors, the gate refuses the call (fails closed).
 *   - supabase/config.toml `[functions.recipe-import] verify_jwt = false`. The
 *     household key is a publishable key (sb_publishable_...), not a JWT, so
 *     Supabase's built-in JWT check would reject every call. The family gate
 *     replaces it.
 *   - The recipe site itself. Slow sites time out after 12 s; sites that block
 *     automated downloads answer 403, which is reported in plain words.
 *   No npm packages: Deno's built-in fetch, URL, and crypto only.
 *
 * DEPENDED ON BY
 *   family-hub-app/index.html — callFamilyFunction('recipe-import', { url }).
 *
 * DEPLOY (once, and again after any change to this file)
 *   npx supabase functions deploy recipe-import
 */

/* =============================== Settings =============================== */

// Browsers allowed to call this function. A browser on any other site is
// refused before any work happens. Requests with no Origin header (curl,
// scripts) are not browsers; they still have to pass the family gate.
const ALLOWED_ORIGINS = new Set(["https://markingmyname.github.io"]);
const LOCAL_ORIGIN = /^http:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?$/;

const MAX_BODY_BYTES = 10_000;     // a link and a family code; nothing more
const MAX_URL_CHARS = 2_000;

// Output ceilings: the recipe lands in the family's synced board, which is one
// shared document, so nothing a web page sends is kept unbounded.
const MAX_NAME_CHARS = 120;
const MAX_INGREDIENTS = 80;
const MAX_STEPS = 60;
const MAX_LINE_CHARS = 1_000;

// Page download limits.
const PAGE_MAX_BYTES = 3_000_000;
const PAGE_TIMEOUT_MS = 12_000;
const PAGE_MAX_REDIRECTS = 4;

/* ================================ Types ================================= */

type Recipe = { name: string; ingredients: string[]; instructions: string[] };

/** An error whose message is safe to show the family. `detail` goes to the log only. */
class HttpError extends Error {
  status: number;
  detail: string;
  constructor(status: number, message: string, detail = "") {
    super(message);
    this.status = status;
    this.detail = detail;
  }
}

/* =============================== Logging ================================ */

/* One JSON line per event, readable in Supabase -> Edge Functions -> Logs.
   Never logs the family code, the user's token, or page contents: families are
   identified by a short one-way hash ("tag"), pages by their host name only. */
type Level = "DEBUG" | "INFO" | "WARN" | "ERROR";
function log(level: Level, fields: Record<string, unknown>): void {
  const line = JSON.stringify({ level, fn: "recipe-import", at: new Date().toISOString(), ...fields });
  if (level === "ERROR") console.error(line);
  else if (level === "WARN") console.warn(line);
  else console.log(line);
}

function errText(err: unknown): string {
  return err instanceof Error ? `${err.name}: ${err.message}` : String(err);
}

/* ============================= HTTP helpers ============================= */

function isAllowedOrigin(origin: string): boolean {
  return ALLOWED_ORIGINS.has(origin) || LOCAL_ORIGIN.test(origin);
}

function corsHeaders(origin: string | null): Record<string, string> {
  // Echo an allowed origin back; otherwise name the real site, which a
  // disallowed browser will then refuse to hand the response to.
  const allow = origin && isAllowedOrigin(origin) ? origin : [...ALLOWED_ORIGINS][0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

function json(status: number, body: unknown, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

/* Reads a stream up to maxBytes. "reject" throws past the cap (requests);
   "truncate" keeps the first maxBytes (web pages, whose recipe data sits near
   the top). Reading in chunks means an oversized body is never held whole. */
async function readCapped(
  stream: ReadableStream<Uint8Array> | null,
  maxBytes: number,
  overflow: "reject" | "truncate",
): Promise<string> {
  if (!stream) return "";
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (total + value.byteLength > maxBytes) {
        if (overflow === "reject") throw new HttpError(413, "That request is too large.");
        chunks.push(value.subarray(0, maxBytes - total));
        total = maxBytes;
        break;
      }
      chunks.push(value);
      total += value.byteLength;
    }
  } finally {
    await reader.cancel().catch(() => {/* stream already closed */});
  }
  // Join into one buffer, then decode once, so a multi-byte character split
  // across two network chunks still decodes correctly.
  const all = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    all.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8").decode(all);
}

async function readBody(req: Request): Promise<Record<string, unknown>> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new HttpError(413, "That request is too large.");
  const text = await readCapped(req.body, MAX_BODY_BYTES, "reject");
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new HttpError(400, "The request wasn't valid JSON.");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new HttpError(400, "The request must be a JSON object.");
  }
  return parsed as Record<string, unknown>;
}

/* =========================== Link validation ============================ */

/* Server-side request forgery guard. This function downloads whatever link it
   is given, so the link must name a public website — never an IP address,
   localhost, or a private-network name that could reach Supabase's own network.
   WHATWG URL parsing normalizes tricks like http://2130706433 and http://0x7f.1
   into dotted IPv4 before this check sees them. */
function safePublicUrl(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    throw new HttpError(400, "That doesn't look like a web address.");
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new HttpError(400, "Only http and https addresses can be imported.");
  }
  if (url.username || url.password) throw new HttpError(400, "Addresses with a username or password can't be imported.");
  if (url.port && url.port !== "80" && url.port !== "443") {
    throw new HttpError(400, "Addresses with an unusual port can't be imported.");
  }
  const host = url.hostname.toLowerCase();
  const isIpLiteral = host.startsWith("[") || /^\d{1,3}(\.\d{1,3}){3}$/.test(host);
  const isPrivateName = !host.includes(".") || host === "localhost" ||
    /\.(localhost|local|internal|lan|home|arpa|corp)$/.test(host);
  if (isIpLiteral || isPrivateName) throw new HttpError(400, "That address doesn't point to a public website.");
  return url;
}

function readUrl(body: Record<string, unknown>): URL {
  const raw = typeof body.url === "string" ? body.url.trim() : "";
  if (!raw) throw new HttpError(400, "Paste a recipe page's address.");
  if (raw.length > MAX_URL_CHARS) throw new HttpError(400, "That address is too long.");
  return safePublicUrl(raw);
}

/* ============================== Family gate ============================= */

/* Talks to the family database's existing RPC functions with the CALLER'S own
   credentials. This function holds no database key of its own, so it can do
   nothing the caller couldn't already do from the browser. */
async function callRpc(
  base: string,
  fn: string,
  args: Record<string, unknown>,
  headers: Record<string, string>,
  deniedMessage: string,
): Promise<unknown> {
  let res: Response;
  try {
    res = await fetch(`${base}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(8_000),
    });
  } catch (err) {
    throw new HttpError(502, "Couldn't reach the family database to check access.", `rpc ${fn}: ${errText(err)}`);
  }
  if (res.status === 401 || res.status === 403) {
    const body = await res.text().catch(() => "");
    throw new HttpError(401, deniedMessage, `rpc ${fn} ${res.status}: ${body.slice(0, 200)}`);
  }
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new HttpError(502, "Couldn't check your family's access right now.", `rpc ${fn} ${res.status}: ${body.slice(0, 200)}`);
  }
  try {
    return await res.json();
  } catch {
    throw new HttpError(502, "The family database sent an unreadable answer.", `rpc ${fn}: bad JSON`);
  }
}

/** First 8 hex characters of SHA-256 — enough to tell families apart in logs, useless for recovering the code. */
async function shortHash(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest).slice(0, 4), (b) => b.toString(16).padStart(2, "0")).join("");
}

/* The same two doors the app itself uses to reach the family board:
     member path — a signed-in Google account; the Bearer token is that user's
                   Supabase session, and fh_me() says which family they're on.
     code path   — the device holds the family code; family_hub_meta(fid)
                   returns a row only for a real family.
   Only people who can already open the family board can use this function.
   Returns a log tag, never the family code itself. */
async function verifyFamily(req: Request, body: Record<string, unknown>): Promise<string> {
  const base = Deno.env.get("SUPABASE_URL");
  if (!base) throw new HttpError(500, "The server is missing its database address.", "SUPABASE_URL is not set");
  const apikey = (req.headers.get("apikey") ?? "").trim();
  if (!apikey) throw new HttpError(401, "Missing the project key. Reload the app and try again.");
  const authHeader = req.headers.get("authorization") ?? "";
  const bearer = /^bearer\s+/i.test(authHeader) ? authHeader.replace(/^bearer\s+/i, "").trim() : "";

  // Member path. A project key repeated in the Bearer slot (legacy anon keys
  // are JWTs) is not a user, so it falls through to the code path.
  if (bearer && bearer !== apikey) {
    const rows = await callRpc(base, "fh_me", {}, { apikey, Authorization: `Bearer ${bearer}` },
      "Your sign-in has expired. Sign in again and retry.");
    const first = Array.isArray(rows) ? (rows[0] as Record<string, unknown> | undefined) : undefined;
    const familyId = typeof first?.family_id === "string" ? first.family_id : "";
    if (!familyId) throw new HttpError(403, "This account isn't on a family's list yet.");
    return await shortHash(familyId);
  }

  // Family-code path.
  const fid = typeof body.fid === "string" ? body.fid.trim() : "";
  if (!fid || fid.length > 200) {
    throw new HttpError(401, "Turn on Family sync in Settings first — website import runs through it.");
  }
  const headers: Record<string, string> = { apikey };
  if (apikey.startsWith("eyJ")) headers.Authorization = `Bearer ${apikey}`; // legacy anon keys are JWTs
  const rows = await callRpc(base, "family_hub_meta", { fid }, headers, "The project key was refused. Reload the app.");
  if (!Array.isArray(rows) || rows.length === 0) throw new HttpError(403, "That family code isn't recognized.");
  return await shortHash(fid);
}

/* ============================ Text clean-up ============================= */

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", deg: "°", times: "×",
  frac12: "½", frac14: "¼", frac34: "¾", frac13: "⅓", frac23: "⅔",
  ndash: "–", mdash: "—", lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”", hellip: "…",
};

function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z0-9]+);/gi, (whole, code: string) => {
    if (code[0] === "#") {
      const n = code[1].toLowerCase() === "x" ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      return Number.isFinite(n) && n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : whole;
    }
    return NAMED_ENTITIES[code.toLowerCase()] ?? whole;
  });
}

/** Strips tags, decodes entities, collapses whitespace, clips length. */
function cleanLine(value: unknown, maxChars = MAX_LINE_CHARS): string {
  if (typeof value !== "string" && typeof value !== "number") return "";
  return decodeEntities(String(value).replace(/<[^>]*>/g, " "))
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxChars);
}

function cleanList(value: unknown, maxItems: number): string[] {
  if (!Array.isArray(value)) return [];
  return value.map((v) => cleanLine(v)).filter(Boolean).slice(0, maxItems);
}

/* ===================== Recipe from the page's own data ================== */

const LD_JSON_SCRIPT = /<script\b[^>]*\btype\s*=\s*["']?application\/ld\+json["']?[^>]*>([\s\S]*?)<\/script>/gi;

function isType(type: unknown, name: string): boolean {
  return type === name || (Array.isArray(type) && type.includes(name));
}

/** Depth-limited walk: Recipe can sit at the top, in an array, or inside @graph / mainEntity. */
function findRecipeNode(value: unknown, depth: number): Record<string, unknown> | null {
  if (depth > 6 || value === null || typeof value !== "object") return null;
  if (Array.isArray(value)) {
    for (const entry of value) {
      const hit = findRecipeNode(entry, depth + 1);
      if (hit) return hit;
    }
    return null;
  }
  const obj = value as Record<string, unknown>;
  if (isType(obj["@type"], "Recipe")) return obj;
  for (const key of ["@graph", "mainEntity", "mainEntityOfPage", "itemListElement"]) {
    const hit = findRecipeNode(obj[key], depth + 1);
    if (hit) return hit;
  }
  return null;
}

/* recipeInstructions comes as a string, a list of strings, HowToStep objects,
   or HowToSection objects holding more steps. Flattened to one line per step,
   with a section's name kept as its own line ("For the sauce:"). */
function flattenInstructions(value: unknown, depth: number): string[] {
  if (depth > 5 || value === null || value === undefined) return [];
  if (typeof value === "string") {
    return value.split(/\r?\n|<br\s*\/?>/i).map((s) => cleanLine(s)).filter(Boolean);
  }
  if (Array.isArray(value)) return value.flatMap((v) => flattenInstructions(v, depth + 1));
  if (typeof value === "object") {
    const obj = value as Record<string, unknown>;
    if (isType(obj["@type"], "HowToSection")) {
      const heading = cleanLine(obj.name);
      const steps = flattenInstructions(obj.itemListElement, depth + 1);
      return heading ? [`${heading}:`, ...steps] : steps;
    }
    const text = cleanLine(obj.text) || cleanLine(obj.name);
    return text ? [text] : [];
  }
  return [];
}

function recipeFromJsonLd(html: string): Recipe | null {
  for (const match of html.matchAll(LD_JSON_SCRIPT)) {
    let data: unknown;
    try {
      data = JSON.parse(match[1].trim());
    } catch {
      continue; // malformed blocks are common on real sites; try the next one
    }
    const node = findRecipeNode(data, 0);
    if (!node) continue;
    const recipe: Recipe = {
      name: cleanLine(node.name, MAX_NAME_CHARS),
      ingredients: cleanList(node.recipeIngredient ?? node.ingredients, MAX_INGREDIENTS),
      instructions: flattenInstructions(node.recipeInstructions, 0).slice(0, MAX_STEPS),
    };
    if (recipe.name && recipe.ingredients.length) return recipe;
  }
  return null;
}

/* Downloads a page, following redirects by hand so every hop passes the
   public-website check again (a public link can redirect to a private one). */
async function downloadPage(start: URL): Promise<{ html: string; url: string }> {
  let current = start;
  for (let hop = 0; hop <= PAGE_MAX_REDIRECTS; hop++) {
    let res: Response;
    try {
      res = await fetch(current, {
        redirect: "manual",
        signal: AbortSignal.timeout(PAGE_TIMEOUT_MS),
        headers: {
          "User-Agent": "Mozilla/5.0 (compatible; FamilyHubRecipeImport/1.0)",
          "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
          "Accept-Language": "en-US,en;q=0.8",
        },
      });
    } catch (err) {
      throw new HttpError(422, "Couldn't download that page. Check the address, or add the recipe from a photo instead.",
        `fetch ${current.hostname}: ${errText(err)}`);
    }
    if (res.status >= 300 && res.status < 400) {
      const location = res.headers.get("location");
      await res.body?.cancel();
      if (!location) throw new HttpError(422, "That page redirected nowhere.");
      current = safePublicUrl(new URL(location, current).href);
      continue;
    }
    if (!res.ok) {
      await res.body?.cancel();
      const blocked = res.status === 401 || res.status === 403 || res.status === 429;
      throw new HttpError(422,
        blocked
          ? "That site blocks automatic downloads. Add the recipe from a photo (a screenshot works) instead."
          : `That site answered with an error (${res.status}).`,
        `page ${current.hostname} ${res.status}`);
    }
    const type = res.headers.get("content-type") ?? "";
    if (type && !/html|xml/i.test(type)) {
      await res.body?.cancel();
      throw new HttpError(422, "That address isn't a web page.");
    }
    return { html: await readCapped(res.body, PAGE_MAX_BYTES, "truncate"), url: current.href };
  }
  throw new HttpError(422, "That address redirected too many times.");
}

async function importRecipe(url: URL): Promise<{ recipe: Recipe; source: string }> {
  const page = await downloadPage(url);
  const recipe = recipeFromJsonLd(page.html);
  if (!recipe) {
    throw new HttpError(422,
      "That page doesn't share its recipe in a form the app can read. Type it in, or add it from a photo (a screenshot works).",
      `no Recipe data on ${new URL(page.url).hostname}`);
  }
  return { recipe, source: page.url };
}

/* ================================ Server ================================ */

Deno.serve(async (req: Request): Promise<Response> => {
  const started = Date.now();
  const origin = req.headers.get("origin");
  const cors = corsHeaders(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });

  let family = "-";
  let host = "-";
  try {
    if (origin !== null && !isAllowedOrigin(origin)) {
      throw new HttpError(403, "This site isn't allowed to import recipes.", `origin ${origin}`);
    }
    if (req.method !== "POST") throw new HttpError(405, "Use POST.");
    const body = await readBody(req);
    const url = readUrl(body);
    host = url.hostname;
    family = await verifyFamily(req, body);
    const data = await importRecipe(url);
    log("INFO", {
      event: "imported", family, host, status: 200, ms: Date.now() - started,
      ingredients: data.recipe.ingredients.length, steps: data.recipe.instructions.length,
    });
    return json(200, { ok: true, data }, cors);
  } catch (err) {
    const failure = err instanceof HttpError
      ? err
      : new HttpError(500, "Something went wrong on the server.", errText(err));
    log(failure.status >= 500 ? "ERROR" : "WARN", {
      event: "failed", family, host, status: failure.status, ms: Date.now() - started,
      error: failure.message, detail: failure.detail,
    });
    return json(failure.status, { ok: false, error: failure.message }, cors);
  }
});
