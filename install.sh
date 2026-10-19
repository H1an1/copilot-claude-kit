#!/usr/bin/env bash
#
# Claude-on-Copilot installer
# ---------------------------
# Lets a fresh Claude Code (and Claude Desktop's built-in Claude Code) run on
# GitHub Copilot's models, fully in the background, with model-id quirks fixed
# automatically so it "just works".
#
# Usage:
#   bash install.sh                     # install / repair (idempotent)
#   bash install.sh --with-codex        # add a Codex CLI profile
#   bash install.sh --with-codex-desktop # configure Claude Code + Codex Desktop
#   bash install.sh --with-codex-desktop --codex-model gpt-6.1-sol
#   bash install.sh --restore-codex-desktop # undo only the Desktop change
#   bash install.sh --verify            # health-check an existing install
#   bash install.sh --uninstall         # remove everything this script created
#   bash install.sh --help
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/H1an1/copilot-claude-kit/main/install.sh | bash
#
# What it sets up:
#   copilot-api  @ :4141   reverse-engineered Anthropic-compatible Copilot proxy
#   normalizer   @ :4142   ~50-line shim: rewrites model ids Copilot rejects,
#                          fixes trailing-message quirks, hides variant ids
#   watchdog     (periodic) probes :4141/:4142 every 90s and kickstarts a wedged
#                          daemon — fixes the "works, then after sleep/reboot I
#                          have to re-run the installer" problem automatically
#   ~/.claude/settings.json env -> points Claude Code at :4142 in every launch
#
# Heads-up: copilot-api is a reverse-engineered proxy. Using your Copilot
# entitlement outside GitHub's official clients violates Copilot's ToS; on a
# corporate/enterprise seat that's a compliance risk. You accept that knowingly.

set -uo pipefail

# ----- pretty output -------------------------------------------------------
if [ -t 1 ]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; X=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; X=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$G" "$X" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$X" "$*"; }
err()  { printf '%s✗%s %s\n' "$R" "$X" "$*" >&2; }
step() { printf '\n%s==>%s %s%s%s\n' "$C" "$X" "$B" "$*" "$X"; }
die()  { err "$*"; exit 1; }

# ----- constants -----------------------------------------------------------
KIT_DIR="$HOME/.copilot-api"
NORMALIZER="$KIT_DIR/model-normalizer.js"
LA_DIR="$HOME/Library/LaunchAgents"
API_PLIST="$LA_DIR/com.copilot-api.plist"
NORM_PLIST="$LA_DIR/com.copilot-api-normalize.plist"
WATCHDOG="$KIT_DIR/watchdog.sh"
WATCHDOG_PLIST="$LA_DIR/com.copilot-api-watchdog.plist"
WATCHDOG_MODE_FILE="$KIT_DIR/watchdog-mode"
SETTINGS="$HOME/.claude/settings.json"
API_PORT=4141
NORM_PORT=4142
# copilot-api 0.7.0 has no --host flag; its server (srvx) binds every interface
# unless HOST is set (srvx: hostname ?? process.env.HOST). Without this, :4141
# (unauthenticated, backed by your Copilot token) is reachable from the LAN.
BIND_HOST="127.0.0.1"
WATCHDOG_INTERVAL=90
GH_TOKEN_FILE="$HOME/.local/share/copilot-api/github_token"
CODEX_DIR="$HOME/.codex"
CODEX_CONFIG="$CODEX_DIR/config.toml"
CODEX_CATALOG="$CODEX_DIR/copilot-models.json"
CODEX_CATALOG_BACKUP="$CODEX_DIR/copilot-models.pre-copilot-claude-kit.json"
CODEX_CATALOG_CREATED_MARKER="$CODEX_DIR/.copilot-models-created-by-copilot-claude-kit"
CODEX_CONFIG_CREATED_MARKER="$CODEX_DIR/.config-created-by-copilot-claude-kit"
CODEX_DESKTOP_MODEL="gpt-6-astra"
# Copilot models served over /responses that Codex can select (newest first).
# Each is probed with a real completion before it is listed in a picker.
# Live-verified over /responses on 2026-10-08 except gpt-5.6-luna and
# gpt-5.6-sol-fast (listed by Copilot, not yet exercised); the probe gates them.
CODEX_MODEL_CHOICES=(gpt-6.1-sol gpt-6-astra gpt-6-sol gpt-6-luna gpt-5.6-sol gpt-5.6-sol-fast gpt-5.6-luna gpt-5.5 gpt-5.3-codex)
# Models Copilot has announced for retirement. Still accepted by an explicit
# --codex-model (with a warning) until they actually stop working, but never
# probed for or offered in the picker. GitHub changelog 2026-10-15: GPT-5.6
# Terra is deprecated 2026-11-16; suggested alternatives gpt-6.1-sol, gpt-6-luna.
CODEX_RETIRING_MODELS=(gpt-5.6-terra)
CODEX_RETIRING_NOTE="deprecated by GitHub Copilot on 2026-11-16; use gpt-6.1-sol or gpt-6-luna"
CODEX_PROFILE_CATALOG="$CODEX_DIR/copilot-profile-models.json"
CODEX_VERIFIED_MODELS=()
CODEX_WATCHDOG_MODEL_FILE="$KIT_DIR/codex-model"
CODEX_ROOT_BEGIN="# >>> copilot-claude-kit: Codex Desktop model >>>"
CODEX_ROOT_END="# <<< copilot-claude-kit: Codex Desktop model <<<"
CODEX_PROVIDER_BEGIN="# >>> copilot-claude-kit: Codex Desktop provider >>>"
CODEX_PROVIDER_END="# <<< copilot-claude-kit: Codex Desktop provider <<<"

# ===========================================================================
#  model-normalizer.js  (embedded so users never copy-paste it)
# ===========================================================================
write_normalizer() {
  mkdir -p "$KIT_DIR"
  cat > "$NORMALIZER" <<'NORMALIZER_EOF'
#!/usr/bin/env node
/*
 * copilot-api model-id normalizer
 * -------------------------------
 * Claude Code (and Claude Desktop's built-in Claude Code) emit Anthropic-style
 * model ids such as claude-opus-4-8, claude-opus-4-8[1m], claude-3-5-haiku-...
 * GitHub Copilot (via copilot-api on :4141) only accepts the exact dot-form ids
 * it advertises (claude-opus-4.8). The mismatch yields 400 model_not_supported.
 *
 * This tiny reverse proxy sits in FRONT of copilot-api and, per request:
 *   1. rewrites the `model` id to a live, Copilot-supported id;
 *   2. ensures the conversation ends with a user message (Copilot rejects a
 *      trailing assistant/system message);
 *   3. hides -1m/-high/-xhigh variant ids from GET /v1/models so the client's
 *      /model picker only shows ids Copilot can actually serve.
 * It also adds a /responses passthrough so OpenAI-style clients (e.g. Codex)
 * can reach Copilot's native Responses API — which copilot-api doesn't proxy —
 * unlocking models (gpt-5.x) that Copilot only serves over /responses. It has
 * no dependencies and auto-discovers the live model list.
 */
const http = require("http");
const fs = require("fs");
const { Readable } = require("stream");

const UPSTREAM_HOST = "127.0.0.1";
const UPSTREAM_PORT = 4141;          // copilot-api
const LISTEN_PORT = 4142;            // what clients point at
const GH_TOKEN_FILE = `${process.env.HOME}/.local/share/copilot-api/github_token`;

let supported = new Set();           // live ids copilot-api accepts
let modelMaxOut = new Map();         // id -> real max_output_tokens (per Copilot)
let lastFetch = 0;

// --- Copilot token exchange (for the /responses passthrough) ----------------
// copilot-api stores the long-lived GitHub OAuth token on disk. We exchange it
// for a short-lived Copilot token (and discover the right API host, which is
// the enterprise host on enterprise seats), caching until just before expiry.
let copilotToken = null, copilotApi = null, copilotTokenExp = 0;
async function getCopilotToken() {
  const now = Math.floor(Date.now() / 1000);
  if (copilotToken && now < copilotTokenExp - 60) return { token: copilotToken, api: copilotApi };
  const ght = fs.readFileSync(GH_TOKEN_FILE, "utf8").trim();
  const r = await fetch("https://api.github.com/copilot_internal/v2/token", {
    headers: {
      authorization: "token " + ght,
      "editor-version": "vscode/1.99.0",
      "user-agent": "GithubCopilot/1.155.0",
    },
  });
  if (!r.ok) throw new Error("token exchange failed: HTTP " + r.status);
  const j = await r.json();
  copilotToken = j.token;
  copilotTokenExp = j.expires_at || (now + 1500);
  copilotApi = (j.endpoints && j.endpoints.api) || "https://api.githubcopilot.com";
  return { token: copilotToken, api: copilotApi };
}

function copilotHeaders(token, accept) {
  return {
    authorization: "Bearer " + token,
    "content-type": "application/json",
    "copilot-integration-id": "vscode-chat",
    "editor-version": "vscode/1.99.0",
    "editor-plugin-version": "copilot-chat/0.26.0",
    "user-agent": "GitHubCopilotChat/0.26.0",
    "openai-intent": "conversation-edits",
    accept: accept || "text/event-stream",
  };
}

// OpenAI "hosted" tool types that Copilot's Responses endpoint rejects. Codex's
// own coding tools are function/local_shell/custom and are NOT in this set.
const HOSTED_TOOLS = new Set([
  "image_generation", "web_search", "web_search_preview", "web_search_2025_08_26",
  "code_interpreter", "file_search", "computer_use", "computer_use_preview",
]);

// Request params Copilot's Responses endpoint doesn't accept (Codex sends some
// OpenAI-platform-only fields). Stripped before forwarding.
const UNSUPPORTED_PARAMS = ["service_tier", "store", "safety_identifier", "prompt_cache_key"];

// Bound discovery even when the peer accepts a socket but never finishes.
// Concurrent requests share one refresh; failed refreshes retain the last catalog.
// The 30s back-off only applies once a valid catalog exists: with no catalog
// (cold start while copilot-api is still booting), every request retries, as
// guessing ids blind for 30s turns into avoidable model_not_supported errors.
let modelRefresh = null;
function refreshModels() {
  if (modelRefresh) return modelRefresh;
  modelRefresh = new Promise((resolve) => {
    let settled = false, req = null;
    const finish = (ok) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (ok === true || supported.size > 0) lastFetch = Date.now();
      resolve();
    };
    const timer = setTimeout(() => {
      finish();
      if (req) req.destroy();
    }, 5000);
    req = http.request(
      { host: UPSTREAM_HOST, port: UPSTREAM_PORT, path: "/v1/models", method: "GET" },
      (r) => {
        let b = "";
        r.on("data", (c) => (b += c));
        r.on("error", () => finish());
        r.on("aborted", () => finish());
        r.on("end", () => {
          if (settled) return;
          try {
            const data = JSON.parse(b).data;
            if (r.statusCode !== 200 || !Array.isArray(data) ||
                !data.every(m => m && typeof m.id === "string")) throw new Error("Invalid model catalog");
            supported = new Set(data.map((m) => m.id));
            modelMaxOut = new Map(data.map((m) => {
              const limit = m?.capabilities?.limits?.max_output_tokens;
              return [m.id, Number.isSafeInteger(limit) && limit > 0 ? limit : 0];
            }));
            return finish(true);
          } catch { /* keep the last valid catalog */ }
          finish();
        });
      }
    );
    req.on("error", () => finish());
    req.end();
  }).finally(() => { modelRefresh = null; });
  return modelRefresh;
}

// Claude model families Copilot serves, newest-first parsing for fallbacks.
// Copilot spells ids in dot-form (claude-opus-5.5); Anthropic/Claude Code use
// dash-form (claude-opus-5-5). Both parse to the same {family, major, minor}.
const FAMILY_RE = /^claude-(opus|sonnet|haiku|fable)-(\d+)(?:[.-](\d+))?$/;
function parseClaude(id) {
  const m = typeof id === "string" ? FAMILY_RE.exec(id) : null;
  return m ? { family: m[1], major: +m[2], minor: m[3] === undefined ? 0 : +m[3] } : null;
}

// id suffixes Copilot exposes as request-time params, not standalone models.
const VARIANT_RE = /-(?:low|medium|high|xhigh|max|1m)(?:-internal)?$/;

// Copilot retires models on a date (2026-11-16: claude-opus-4.8, except for
// individual annual-plan subscribers, and claude-opus-5), but copilot-api
// loads /models once at startup and never refreshes it, so its catalog keeps
// listing an id that Copilot now rejects with 400 model_not_supported. An id
// Copilot rejected that way is treated as unserved for REJECTED_TTL_MS, so
// family fallbacks skip it even though the stale catalog still lists it.
const REJECTED_TTL_MS = 3600000;
const UNSUPPORTED_MODEL_RE = /model_not_supported|model is not supported/i;
const rejected = new Map();          // id -> time Copilot rejected it
function isRejected(id) {
  const t = rejected.get(id);
  if (t === undefined) return false;
  if (Date.now() - t < REJECTED_TTL_MS) return true;
  rejected.delete(id);
  return false;
}
function served(id) { return supported.has(id) && !isRejected(id); }

// Newest model of a family in the live catalog (variant ids excluded).
function newestServed(family) {
  let best = null, bestP = null;
  for (const id of supported) {
    if (VARIANT_RE.test(id) || isRejected(id)) continue;
    const p = parseClaude(id);
    if (!p || p.family !== family) continue;
    if (!bestP || p.major > bestP.major || (p.major === bestP.major && p.minor > bestP.minor)) {
      best = id; bestP = p;
    }
  }
  return best;
}

// Used only while no catalog has loaded yet (cold start / :4141 unreachable):
// real Copilot dot-form ids (docs.github.com supported-models, 2026-10-12).
// Haiku 5.5 is GA in Copilot as of 2026-10-07 (gradual rollout); cold-start
// matches ANTHROPIC_DEFAULT_HAIKU_MODEL. Watchdog still probes haiku-4.5.
const COLD_START = {
  opus: "claude-opus-5.5", sonnet: "claude-sonnet-5.5",
  haiku: "claude-haiku-5.5", fable: "claude-fable-5.1",
};
function familyDefault(family) {
  return newestServed(family) || (supported.size === 0 ? COLD_START[family] : null);
}

// Output ceilings for known ids when the catalog carries no limits (copilot-api
// 0.7.0's /v1/models strips `capabilities`, so this table is what applies in
// practice). Values never exceed the previously verified 64k; ids not listed
// fall back to modelCeiling(). Sending more than a model allows yields HTTP 400.
// Opus 4.8 and Opus 5 stay: Copilot serves them until 2026-11-16, and Opus 4.8
// stays available after that for individual annual-plan subscribers.
const KNOWN_MAX_OUTPUT = {
  "claude-sonnet-4.6": 32000,
  "claude-haiku-4.5": 64000,
  "claude-opus-4.8": 64000,
  "claude-opus-5": 64000,
  "claude-sonnet-5": 64000,
  "claude-opus-5.5": 64000,
  "claude-sonnet-5.5": 64000,
  "claude-haiku-5.5": 64000,
  "claude-fable-5": 64000,
  "claude-fable-5.1": 64000,
};
function modelCeiling(id) {
  if (typeof id !== "string") return 32000;
  const p = parseClaude(id);
  const dotId = p ? `claude-${p.family}-${p.major}${p.minor ? "." + p.minor : ""}` : id;
  if (KNOWN_MAX_OUTPUT[id]) return KNOWN_MAX_OUTPUT[id];
  if (KNOWN_MAX_OUTPUT[dotId]) return KNOWN_MAX_OUTPUT[dotId];
  if (/claude-(opus|sonnet)-4\.5$/.test(dotId)) return 32000;
  if (/^claude-/.test(id)) return 64000;
  return 32000;
}
function outputCeiling(id) {
  return modelMaxOut.get(id) || modelCeiling(id);
}

// Copilot rejects `thinking` / `reasoning_effort` for models that don't support
// reasoning effort — notably the haiku family (small/fast). This matters here
// because patch_copilot_api() translates `thinking:{enabled}` into
// reasoning_effort:"high" for ALL models, and the background (haiku) model
// would then 400 with invalid_reasoning_effort. So after the id is settled,
// drop effort fields for models that can't take them. Opus/sonnet keep thinking.
function supportsEffort(id) {
  if (typeof id !== "string") return true;
  if (/haiku/i.test(id)) return false;
  return true;
}

// Claude Desktop only shows the effort selector for models whose id matches
// Anthropic's canonical dash+date shape (e.g. claude-opus-4-1-20250805). Copilot
// serves dot-form ids (claude-opus-4.8). So in the /v1/models listing we present
// the canonical shape (forwardId), and on the request path we convert it back to
// the dot-form Copilot accepts (handled in normalize()).
const SENTINEL_DATE = "20260301";
function forwardId(id) {
  const m = /^claude-(opus|sonnet|haiku|fable)-(\d+)(?:\.(\d+))?$/.exec(id);
  if (!m) return id;
  return `claude-${m[1]}-${m[2]}${m[3] === undefined ? "" : "-" + m[3]}-${SENTINEL_DATE}`;
}

// Some Copilot accounts (org policy) have no Claude models at all; their model
// list is GPT/Grok only. Forwarding a Claude request then yields an opaque
// 400 model_not_supported, so answer it here with an actionable message.
const NO_CLAUDE_CODE = "copilot_no_claude_models";
const NO_CLAUDE_MESSAGE = "This Copilot account has no Claude models enabled; ask your org admin to enable them in Copilot policy. (Copilot's model list for this account contains no claude-* ids; Codex/GPT models are unaffected.)";
function hasClaudeModels() {
  for (const id of supported) if (/^claude-/.test(id)) return true;
  return false;
}
function isClaudeRequest(model) {
  if (typeof model !== "string") return false;
  const base = model.trim().replace(/\[[^\]]*\]\s*$/, "").toLowerCase();
  return base.startsWith("claude") || /^(opus|sonnet|haiku|fable)$/.test(base);
}

// Map a client model id to one Copilot serves.
//   * An id the catalog lists (either spelling) is used exactly.
//   * Claude Code aliases resolve to Anthropic's newest ids (sonnet ->
//     claude-sonnet-5-5, haiku -> claude-haiku-5-5), and saved settings can hold
//     retired ids. If the catalog is loaded and the requested version is not in
//     it, use the newest SERVED model of the same family (fable falls back to
//     opus) instead of forwarding an id that can only 400.
//   * `exact` (header x-cck-exact-model: 1, used by the installer self-tests)
//     disables that substitution so verification never passes on another model.
//   * With no catalog yet, send the canonical dot-form id unchanged.
//   * An id Copilot just rejected as unsupported (see `rejected`) counts as
//     unserved even if copilot-api's stale catalog still lists it.
function normalize(model, exact = false) {
  if (typeof model !== "string" || !model) return model;
  let base = model.trim().replace(/\[[^\]]*\]\s*$/, "");         // strip "[1m]"
  base = base.replace(/-\d{8}$/, "");                            // strip date sentinel
  if (served(base)) return base;
  const dotted = base.replace(/^claude-(opus|sonnet|haiku|fable)-(\d+)-(\d+)$/, "claude-$1-$2.$3");
  if (served(dotted)) return dotted;
  // Prefer the exact upstream spelling, including newer dash-form model ids.
  const dashed = dotted.replace(/^(claude-(?:opus|sonnet|haiku|fable)-\d+)\.(\d+)$/, "$1-$2");
  if (served(dashed)) return dashed;
  const p = parseClaude(dotted);
  if (p) {
    if (exact || supported.size === 0) return dotted;
    const alt = newestServed(p.family) || (p.family === "fable" ? newestServed("opus") : null);
    if (alt) {
      console.error(`[normalize] ${dotted} is not served by this Copilot account; using ${alt}`);
      return alt;
    }
    return dotted;
  }
  const low = base.toLowerCase();
  if (!low.startsWith("claude") && !/^(opus|sonnet|haiku|fable)$/.test(low)) return base;  // gpt-*/gemini-* pass through
  for (const family of ["haiku", "sonnet", "fable", "opus"]) {
    if (low.includes(family)) {
      return familyDefault(family) || (family !== "opus" ? familyDefault("opus") : null) || base;
    }
  }
  return familyDefault("opus") || base;
}

// Forwarded requests get a connect timeout and an IDLE timeout, never a total
// one: a long streaming answer keeps the timer reset with every chunk, while a
// wedged upstream that sends nothing for UPSTREAM_IDLE_MS is cut off instead of
// hanging the client forever. Stream errors on either side end the response
// cleanly instead of crashing the process; a client that goes away aborts the
// upstream request.
const UPSTREAM_IDLE_MS = 300000;
const UPSTREAM_CONNECT_MS = 10000;
function upstreamFailed(res, e, what) {
  if (res.writableEnded || res.destroyed) return;   // client already gone/done
  const msg = `${what}: ${(e && e.message) || e}`;
  console.error(`[proxy] ${msg}`);
  if (!res.headersSent) {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: msg } }));
  } else {
    res.destroy();
  }
}
function forwardLocal(res, opts, body, onResponse) {
  let connectTimer = null;
  const up = http.request(opts, (ur) => {
    clearTimeout(connectTimer);
    ur.on("error", (e) => upstreamFailed(res, e, "normalizer upstream error"));
    ur.on("aborted", () => upstreamFailed(res, new Error("upstream closed mid-response"), "normalizer upstream error"));
    onResponse(ur);
  });
  connectTimer = setTimeout(() => up.destroy(new Error("connect timeout")), UPSTREAM_CONNECT_MS);
  up.on("socket", (sock) => {
    if (!sock.connecting) clearTimeout(connectTimer);
    else sock.once("connect", () => clearTimeout(connectTimer));
  });
  up.setTimeout(UPSTREAM_IDLE_MS, () =>
    up.destroy(new Error(`no upstream activity for ${UPSTREAM_IDLE_MS / 1000}s`)));
  up.on("error", (e) => { clearTimeout(connectTimer); upstreamFailed(res, e, "normalizer upstream error"); });
  up.on("close", () => clearTimeout(connectTimer));
  res.on("close", () => { if (!res.writableFinished) up.destroy(); });
  up.end(body);
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("error", () => {});
  req.on("data", (c) => chunks.push(c));
  req.on("end", async () => {
    let body = Buffer.concat(chunks);
    // Installer self-tests ask for the exact model (no family substitution).
    const exact = req.headers["x-cck-exact-model"] === "1";
    if (Date.now() - lastFetch > 30000) await refreshModels();

    // --- Responses API passthrough (Codex etc.) ---------------------------
    // copilot-api has no /responses route, and Copilot serves gpt-5.x only over
    // /responses. We forward straight to Copilot's native Responses endpoint
    // using a freshly-exchanged Copilot token, streaming the result back.
    if (req.method === "POST" && /^\/(v1\/)?responses\b/.test(req.url)) {
      if (body.length) {
        try {
          const j = JSON.parse(body.toString("utf8"));
          // This is a dedicated approval workload, not a chat-model alias.
          // Fail closed with an actionable explanation; never invent a verdict
          // or silently run the approval policy on an arbitrary chat model.
          if (j.model === "codex-auto-review") {
            res.writeHead(400, { "content-type": "application/json" });
            res.end(JSON.stringify({ error: {
              type: "invalid_request_error", code: "copilot_auto_review_unsupported", param: "model",
              message: 'Copilot provider does not support codex-auto-review. Select Ask for approval in Codex, or set approvals_reviewer = "user" and approval_policy = "on-request", then start a new task. Also check app-specific reviewer overrides.',
            } }));
            return;
          }
          if (typeof j.model === "string") {
            const fixed = normalize(j.model, exact);
            if (fixed !== j.model) { console.error(`[responses] ${j.model} -> ${fixed}`); j.model = fixed; }
          }
          // Copilot's Responses endpoint rejects OpenAI hosted tools (e.g.
          // image_generation, web_search). Drop them; keep Codex's own
          // function/shell tools so coding still works.
          if (Array.isArray(j.tools)) {
            const before = j.tools.length;
            j.tools = j.tools.filter((t) => t && !HOSTED_TOOLS.has(t.type));
            if (j.tools.length !== before) console.error(`[responses] stripped ${before - j.tools.length} hosted tool(s)`);
          }
          // Drop request params Copilot's Responses endpoint doesn't accept.
          for (const k of UNSUPPORTED_PARAMS) if (k in j) { delete j[k]; }
          body = Buffer.from(JSON.stringify(j), "utf8");
        } catch { /* forward as-is */ }
      }
      let auth;
      try { auth = await getCopilotToken(); }
      catch (e) {
        res.writeHead(502, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: { message: "responses passthrough: " + e.message } }));
        return;
      }
      const ac = new AbortController();
      let idle = null;
      const done = () => clearTimeout(idle);
      const bump = () => {
        done();
        idle = setTimeout(() => ac.abort(new Error(`no upstream activity for ${UPSTREAM_IDLE_MS / 1000}s`)), UPSTREAM_IDLE_MS);
      };
      res.on("close", () => { done(); if (!res.writableFinished) ac.abort(new Error("client closed")); });
      bump();
      try {
        const up = await fetch(auth.api + "/responses", {
          method: "POST",
          headers: copilotHeaders(auth.token, req.headers["accept"]),
          body,
          signal: ac.signal,
        });
        bump();
        const h = {};
        const ct = up.headers.get("content-type");
        if (ct) h["content-type"] = ct;
        res.writeHead(up.status, h);
        if (up.body) {
          const rs = Readable.fromWeb(up.body);
          rs.on("data", bump);
          rs.on("end", done);
          rs.on("error", (e) => { done(); upstreamFailed(res, e, "responses upstream error"); });
          rs.pipe(res);
        } else {
          res.end(await up.text());
          done();
        }
      } catch (e) {
        done();
        upstreamFailed(res, e, "responses upstream error");
      }
      return;
    }

    // --- Hide variant ids from the model picker (GET /v1/models) ----------
    if (req.method === "GET" && req.url.startsWith("/v1/models")) {
      const gh = { ...req.headers };
      delete gh["host"];
      delete gh["x-cck-exact-model"];
      forwardLocal(res,
        { host: UPSTREAM_HOST, port: UPSTREAM_PORT, path: req.url, method: "GET", headers: gh },
        undefined,
        (ur) => {
          const ch = [];
          ur.on("data", (c) => ch.push(c));
          ur.on("end", () => {
            let out = Buffer.concat(ch);
            try {
              const j = JSON.parse(out.toString("utf8"));
              if (Array.isArray(j.data)) {
                j.data = j.data
                  .filter((m) => !(typeof m.id === "string" && /^claude-/.test(m.id) &&
                    (VARIANT_RE.test(m.id) || isRejected(m.id))))
                  .map((m) => (typeof m.id === "string" ? { ...m, id: forwardId(m.id) } : m));
                out = Buffer.from(JSON.stringify(j), "utf8");
              }
            } catch {}
            const h = { ...ur.headers };
            delete h["content-encoding"];
            delete h["transfer-encoding"];
            h["content-length"] = Buffer.byteLength(out);
            if (res.writableEnded || res.destroyed) return;
            res.writeHead(ur.statusCode, h);
            res.end(out);
          });
        }
      );
      return;
    }

    // --- Rewrite model id + sanitize messages on POST bodies --------------
    let retry = null;                  // set when a model_not_supported 400 may be retried
    if (req.method === "POST" && body.length) {
      try {
        const j = JSON.parse(body.toString("utf8"));
        const clientModel = j && j.model;
        let changed = false;
        if (/^\/(v1\/)?messages\b/.test(req.url) && j && isClaudeRequest(j.model) &&
            supported.size > 0 && !hasClaudeModels()) {
          console.error(`[normalize] ${j.model}: no Claude models on this Copilot account`);
          res.writeHead(400, { "content-type": "application/json" });
          res.end(JSON.stringify({ type: "error", error: {
            type: "invalid_request_error", code: NO_CLAUDE_CODE, message: NO_CLAUDE_MESSAGE } }));
          return;
        }
        if (j && typeof j.model === "string") {
          const fixed = normalize(j.model, exact);
          if (fixed && fixed !== j.model) {
            console.error(`[normalize] ${j.model} -> ${fixed}`);
            j.model = fixed;
            changed = true;
          }
        }
        // Drop reasoning-effort fields for models that can't accept them (haiku).
        // Without this, rewriting an opus request down to the small haiku model
        // leaves a `thinking`/`reasoning_effort` that haiku rejects with 400.
        if (!supportsEffort(j.model)) {
          if (j.thinking !== undefined) {
            console.error(`[normalize] dropped thinking for ${j.model} (no effort support)`);
            delete j.thinking;
            changed = true;
          }
          if (j.reasoning_effort !== undefined) {
            console.error(`[normalize] dropped reasoning_effort for ${j.model} (no effort support)`);
            delete j.reasoning_effort;
            changed = true;
          }
        }
        // Maximize the output budget so tool_use arguments can never get cut
        // off mid-stream. A starved budget truncates a long tool call, leaving
        // an unclosed input_json_delta -> the harness leaks <invoke> as text or
        // reports "command missing". Pin max_tokens to the model's ceiling
        // (upstream metadata when present, else KNOWN_MAX_OUTPUT / 32k-64k) so
        // even the longest pipeline fits; clamp down if a client asked for more
        // than the model allows (avoids HTTP 400).
        const ceiling = outputCeiling(j.model);
        // Non-streaming requests keep a 16k default, never above the ceiling.
        const maxOut = j.stream === false ? Math.min(16000, ceiling) : ceiling;
        if (j.max_tokens !== maxOut) {
          console.error(`[normalize] max_tokens ${j.max_tokens} -> ${maxOut}`);
          j.max_tokens = maxOut;
          changed = true;
        }
        // Copilot requires the conversation to END WITH A USER MESSAGE.
        if (Array.isArray(j.messages) && j.messages.length > 1) {
          while (j.messages.length > 1 && j.messages[j.messages.length - 1].role === "assistant") {
            j.messages.pop();
            changed = true;
            console.error("[normalize] stripped trailing assistant prefill");
          }
          const last = j.messages[j.messages.length - 1];
          if (last && last.role !== "user") {
            console.error(`[normalize] retagged trailing '${last.role}' message -> 'user'`);
            last.role = "user";
            changed = true;
          }
        }
        if (changed) body = Buffer.from(JSON.stringify(j), "utf8");
        // A Claude id the (possibly stale) catalog lists can still be retired
        // upstream. Retry such a 400 once on the newest served model of the
        // family. Never in exact mode: self-tests must see the real failure.
        if (!exact && isClaudeRequest(clientModel) && parseClaude(j.model)) retry = { j, clientModel };
      } catch { /* not JSON; forward untouched */ }
    }

    const headers = { ...req.headers };
    delete headers["host"];
    delete headers["x-cck-exact-model"];
    const send = (payload, again) => {
      headers["content-length"] = Buffer.byteLength(payload);
      forwardLocal(res,
        { host: UPSTREAM_HOST, port: UPSTREAM_PORT, path: req.url, method: req.method, headers },
        payload,
        (ur) => {
          if (res.writableEnded || res.destroyed) { ur.resume(); return; }
          if (!again || ur.statusCode !== 400) {
            res.writeHead(ur.statusCode, ur.headers);
            ur.pipe(res);
            return;
          }
          const ch = [];
          ur.on("data", (c) => ch.push(c));
          ur.on("end", () => {
            const errBody = Buffer.concat(ch);
            if (UNSUPPORTED_MODEL_RE.test(errBody.toString("utf8"))) {
              const { j, clientModel } = again;
              const failed = j.model;
              rejected.set(failed, Date.now());
              const alt = normalize(clientModel);
              if (alt && alt !== failed && served(alt)) {
                console.error(`[normalize] Copilot rejected ${failed} as unsupported (retired?); retrying on ${alt}`);
                j.model = alt;
                if (typeof j.max_tokens === "number") {
                  const ceiling = outputCeiling(alt);
                  j.max_tokens = j.stream === false ? Math.min(16000, ceiling) : ceiling;
                }
                send(Buffer.from(JSON.stringify(j), "utf8"), null);
                return;
              }
            }
            if (res.writableEnded || res.destroyed) return;
            const h = { ...ur.headers };
            delete h["transfer-encoding"];
            h["content-length"] = errBody.length;
            res.writeHead(ur.statusCode, h);
            res.end(errBody);
          });
        }
      );
    };
    send(body, retry);
  });
});

// Loopback only, regardless of HOST in the environment.
const LISTEN_HOST = "127.0.0.1";
refreshModels().finally(() => {
  server.listen(LISTEN_PORT, LISTEN_HOST, () => {
    console.error(`model-normalizer listening on http://${LISTEN_HOST}:${LISTEN_PORT} -> :${UPSTREAM_PORT}`);
  });
});
NORMALIZER_EOF
  ok "normalizer written to $NORMALIZER"
}

# ===========================================================================
#  watchdog.sh  (embedded so users never copy-paste it)
# ===========================================================================
# launchd's KeepAlive only keeps the PROCESS alive, not the process HEALTHY.
# After sleep/wake or a network blip, copilot-api's node process is often still
# "running" (so KeepAlive never restarts it) but its socket is wedged — the port
# stops answering. That is exactly why re-running this installer "fixes" a dead
# setup: it is NOT re-authenticating (the GitHub token is still on disk), it is
# just reloading the daemons. The watchdog automates that: probe the exit ports,
# and kickstart -k whichever service is wedged. No auth involved.
write_watchdog() {
  mkdir -p "$KIT_DIR"
  cat > "$WATCHDOG" <<'WATCHDOG_EOF'
#!/usr/bin/env bash
#
# copilot-api watchdog
# --------------------
# Health is decided by a REAL completion through the configured client path:
# Anthropic Messages for a Claude install, or OpenAI Responses for a Codex
# install. It is not decided by GET /v1/models, which copilot-api serves from
# an in-memory cache
# (`if (!state.models) await cacheModels()`), which never expires — so it keeps
# answering 200 long after the Copilot token has died or the network has gone.
# Probing it means the watchdog reports "healthy" while every user request 401s.
# A tiny completion costs ~nothing and sees what the user sees.
#
# Failure is then triaged instead of guessed:
#   * no network        -> stay quiet, change nothing; it will heal itself
#   * network, wedged   -> kickstart -k (what a manual installer re-run does)
#   * network, still bad-> auth is genuinely dead; throttled notification
# The old script skipped this triage and blamed the token for every failure, so
# an offline laptop got told to run `copilot-api auth` — which cannot help, and
# sends people back to re-running the installer for a problem it never fixes.
#
# Runs as a periodic launchd job (StartInterval), not a resident process.
set -uo pipefail

UID_N="$(id -u)"
LOG="/tmp/com.copilot-api-watchdog.log"
NOTIFY_STAMP="/tmp/com.copilot-api-watchdog.notified"
NOTIFY_THROTTLE=3600          # seconds between "re-auth needed" notifications
MODEL_STAMP="/tmp/com.copilot-api-watchdog.model-notified"
# Widely served Codex models, used only to tell "the chain is down" apart from
# "the configured Codex model is gone" (retired, e.g. gpt-5.6-terra on
# 2026-11-16, or blocked by org policy). A restart can't bring a model back.
CODEX_HEALTH_FALLBACKS="gpt-6-astra gpt-6.1-sol"
API_PORT=4141                 # copilot-api
NORM_PORT=4142                # normalizer
API_LABEL="com.copilot-api"
NORM_LABEL="com.copilot-api-normalize"
MODE_FILE="$HOME/.copilot-api/watchdog-mode"
LOG_MAX=200000                # bytes; trimmed to the last half when exceeded

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
log()   { printf '%s %s\n' "$(stamp)" "$*" >> "$LOG"; }

# Socket liveness only — says the port is bound, NOT that requests work.
alive() { curl -fsS -m 5 "http://localhost:$1/v1/models" >/dev/null 2>&1; }

# End-to-end Claude health: use a dash-form id so rewriting is exercised too.
works_claude() {
  local out
  out="$(curl -sS -m 25 "http://localhost:$NORM_PORT/v1/messages" \
    -H 'content-type: application/json' -H 'x-api-key: dummy' \
    -H 'anthropic-version: 2023-06-01' \
    -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}' \
    2>/dev/null)" || return 1
  case "$out" in
    *'"type":"message"'*) return 0 ;;
    # The chain works; the account just has no Claude models (org policy).
    # Restarting or re-authorizing cannot fix that, so don't.
    *copilot_no_claude_models*) log "Copilot account has no Claude models enabled (org policy); proxy is healthy"; return 0 ;;
    *) return 1 ;;
  esac
}

# End-to-end Codex health: Responses is forwarded straight to Copilot by the
# normalizer, exactly like Codex Desktop and CLI.
works_codex_model() {
  local model="$1" out
  out="$(curl -fsS -m 25 "http://localhost:$NORM_PORT/v1/responses" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$model\",\"input\":\"reply with exactly one word: pong\",\"stream\":false}" \
    2>/dev/null)" || return 1
  case "$out" in *'"status":"completed"'*|*'"output"'*) return 0 ;; *) return 1 ;; esac
}

# Throttled (hourly) log line + notification: the configured Codex model fails
# while another model works through the same chain.
codex_model_unavailable() {  # $1 = configured model, $2 = model that works
  local now last=0
  now="$(date +%s)"
  [ -f "$MODEL_STAMP" ] && last="$(cat "$MODEL_STAMP" 2>/dev/null || echo 0)"
  [ $((now - last)) -ge "$NOTIFY_THROTTLE" ] || return 0
  log "Codex model $1 fails but $2 works: the proxy is healthy and $1 is not served to this Copilot account (retired or blocked by policy); no restart. Re-run the installer with --codex-model to switch (e.g. gpt-6.1-sol)."
  osascript -e "display notification \"Codex model $1 is no longer served by Copilot. Re-run the installer to pick another model.\" with title \"copilot-api: Codex model unavailable\"" >/dev/null 2>&1 || true
  printf '%s' "$now" > "$MODEL_STAMP"
}

works_codex() {
  local model="gpt-6-astra" alt
  [ ! -f "$HOME/.copilot-api/codex-model" ] || model="$(cat "$HOME/.copilot-api/codex-model")"
  works_codex_model "$model" && return 0
  # One alternative probe (only on failure) keeps a retired or blocked pinned
  # model from looking like a dead chain, which used to kickstart both daemons
  # every 90s and send a false "token expired" notification (B2).
  for alt in $CODEX_HEALTH_FALLBACKS; do
    [ "$alt" != "$model" ] || continue
    works_codex_model "$alt" || return 1
    codex_model_unavailable "$model" "$alt"
    return 0
  done
  return 1
}

works() {
  local mode="claude"
  [ -f "$MODE_FILE" ] && mode="$(cat "$MODE_FILE" 2>/dev/null || echo claude)"
  case "$mode" in
    codex) works_codex ;;
    combined)
      local failed=0
      works_claude || { log "Claude Messages probe failed"; failed=1; }
      works_codex || { log "Codex Responses probe failed"; failed=1; }
      return "$failed" ;;
    *) works_claude ;;
  esac
}

# Is the machine actually online? Without this, a closed lid / dropped VPN is
# indistinguishable from an expired token, and we cry wolf.
net_ok() { curl -fsS -m 8 -o /dev/null https://api.github.com/ >/dev/null 2>&1; }

kick() { launchctl kickstart -k "gui/$UID_N/$1" >/dev/null 2>&1; }

# copilot-api needs 15-25s to serve again after a kickstart. Judging earlier
# misreads a slow-but-fine restart as a dead token.
works_retry() {  # ~25s across 5 tries (3+4+5+6+7)
  local w
  for w in 3 4 5 6 7; do
    works && return 0
    sleep "$w"
  done
  works
}

trim_log() {
  [ -f "$LOG" ] || return 0
  local size; size="$(wc -c < "$LOG" 2>/dev/null || echo 0)"
  [ "$size" -gt "$LOG_MAX" ] || return 0
  tail -c $((LOG_MAX / 2)) "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}

notify_reauth() {
  local now last=0
  now="$(date +%s)"
  [ -f "$NOTIFY_STAMP" ] && last="$(cat "$NOTIFY_STAMP" 2>/dev/null || echo 0)"
  if [ $((now - last)) -ge "$NOTIFY_THROTTLE" ]; then
    osascript -e 'display notification "Run: copilot-api auth (token expired)" with title "copilot-api needs re-auth"' >/dev/null 2>&1 || true
    printf '%s' "$now" > "$NOTIFY_STAMP"
  fi
}

trim_log

# Healthy: nothing to do. This is the overwhelmingly common path, and it costs
# one 1-token completion.
if works; then
  rm -f "$NOTIFY_STAMP" 2>/dev/null || true
  exit 0
fi

# Offline: not our problem to fix, and restarting into a dead network only
# burns launchd backoff. Say nothing, touch nothing — it heals on reconnect
# (the normalizer re-fetches the model list on any request older than 30s).
if ! net_ok; then
  log "chain unhealthy but the machine is offline — waiting for the network, no action"
  exit 0
fi

# Online but broken -> restart whichever side isn't even holding its socket;
# if both are bound, the wedge is internal, so rebuild both.
if ! alive "$API_PORT"; then
  log ":$API_PORT ($API_LABEL) socket down -> kickstart -k"
  kick "$API_LABEL"
elif ! alive "$NORM_PORT"; then
  log ":$NORM_PORT ($NORM_LABEL) socket down -> kickstart -k"
  kick "$NORM_LABEL"
else
  log "both ports answer but completions fail -> kickstart -k both"
  kick "$API_LABEL"; kick "$NORM_LABEL"
fi

# Only now, after restarts have had real time to finish, do we decide.
if works_retry; then
  log "recovered: end-to-end completion succeeds again"
  rm -f "$NOTIFY_STAMP" 2>/dev/null || true
  exit 0
fi

# Still broken with a working network and a fresh process: authentication is the
# remaining explanation, and no restart can fix that. The one human-needed case.
if net_ok; then
  log "still failing after restart, network is up — GitHub token likely expired; run 'copilot-api auth'"
  notify_reauth
else
  log "still failing, but the network dropped again mid-check — treating as offline, no action"
fi

exit 0
WATCHDOG_EOF
  chmod +x "$WATCHDOG"
  ok "watchdog written to $WATCHDOG"
}

# ----- helpers -------------------------------------------------------------
need_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "This installer targets macOS. See the README for manual Linux steps."
}

find_node() {
  local n
  n="$(command -v node 2>/dev/null)" || true
  [ -n "$n" ] && { printf '%s' "$n"; return 0; }
  for c in /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

ensure_node() {
  local n
  if ! n="$(find_node)"; then
    die "Node.js not found. Install it first (e.g. 'brew install node'), then re-run."
  fi
  NODE_BIN="$n"
  NODE_DIR="$(dirname "$n")"
  ok "node: $NODE_BIN ($("$NODE_BIN" -v 2>/dev/null))"
}

ensure_copilot_api() {
  if command -v copilot-api >/dev/null 2>&1; then
    COPILOT_API_BIN="$(command -v copilot-api)"
    ok "copilot-api already installed: $COPILOT_API_BIN"
  else
    step "Installing copilot-api (this can take a minute)"
    command -v npm >/dev/null 2>&1 || die "npm not found. Install Node.js (which bundles npm) and re-run."
    npm i -g copilot-api@latest >/dev/null 2>&1 || npm i -g copilot-api@latest || die "npm install failed."
    COPILOT_API_BIN="$(command -v copilot-api)" || die "copilot-api still not on PATH after install."
    ok "installed copilot-api: $COPILOT_API_BIN"
  fi
  patch_copilot_api
  patch_token_refresh
}

# copilot-api collapses Claude extended-thinking blocks to plain text and drops
# the thinking/reasoning_effort knobs, so opus "thinks" only superficially. We
# patch its translator to forward reasoning_effort and surface reasoning_text as
# Anthropic thinking blocks. Idempotent; re-applies after every reinstall.
patch_copilot_api() {
  local m; m="$(npm root -g 2>/dev/null)/copilot-api/dist/main.js"
  if [ ! -f "$m" ]; then
    warn "extended-thinking compatibility NOT verified: copilot-api bundle not found"
    return 0
  fi
  if "${NODE_BIN:-node}" - "$m" <<'THINKING_PATCH_EOF'
const f = process.argv[2], fs = require("fs");
const original = fs.readFileSync(f, "utf8");
let s = original;
const patches = [
  ["tool_choice: translateAnthropicToolChoiceToOpenAI(payload.tool_choice)\n\t};",
   "tool_choice: translateAnthropicToolChoiceToOpenAI(payload.tool_choice),\n\t\treasoning_effort: payload.thinking?.type===\"enabled\"?\"high\":void 0\n\t};"],
  ["content: [...allTextBlocks, ...allToolUseBlocks],",
   "content: [...(response.choices[0]?.message?.reasoning_text?[{type:\"thinking\",thinking:response.choices[0].message.reasoning_text,signature:\"\"}]:[]), ...allTextBlocks, ...allToolUseBlocks],"],
];
// Validate BOTH replacements before writing; repair a partially applied patch.
for (const [before, after] of patches) {
  const oldCount = s.split(before).length - 1;
  const newCount = s.split(after).length - 1;
  if (oldCount === 0 && newCount === 1) continue;
  if (oldCount !== 1 || newCount !== 0) {
    console.error("Upstream bundle does not match the supported thinking patch; no changes written.");
    process.exit(1);
  }
  s = s.replace(before, after);
}
if (s !== original) {
  const tmp = f + ".cck-tmp." + process.pid;
  try {
    fs.writeFileSync(tmp, s, { mode: fs.statSync(f).mode });
    fs.renameSync(tmp, f);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch {}
    console.error(`could not write ${f}: ${e.code || e.message} (try re-running with write access to the npm global dir)`);
    process.exit(2);
  }
}
console.log(s === original ? "extended-thinking patch already verified" : "extended-thinking patch applied and verified");
THINKING_PATCH_EOF
  then
    ok "copilot-api extended-thinking patch verified"
  else
    warn "extended-thinking compatibility NOT verified; unsupported upstream bundle or write failure (see above)"
  fi
}

# copilot-api refreshes its Copilot token every ~25 min. Upstream's catch block
# re-throws inside an async setInterval callback — an unhandled rejection, which
# Node 24 turns into process exit. If the network happens to be down at that
# moment (VPN drop, closed lid) the daemon dies, launchd restarts it into the
# same dead network, and it dies again: a crash loop that looks exactly like an
# expired token, so the old watchdog told people to re-auth and they ended up
# re-running this installer for a problem it never fixed. Replace the re-throw
# with capped exponential backoff: a transient outage costs a retry, not the
# process. Idempotent; re-applies after every reinstall.
patch_token_refresh() {
  local m; m="$(npm root -g 2>/dev/null)/copilot-api/dist/main.js"
  if [ ! -f "$m" ]; then
    warn "token-refresh crash fix NOT verified: copilot-api bundle not found"
    return 0
  fi
  # Script goes in on stdin (no temp file, so no mktemp portability issues and
  # no way to end up running node with an empty script path).
  if "${NODE_BIN:-node}" - "$m" <<'REFRESH_PATCH_EOF'
const f = process.argv[2], fs = require("fs");
let s = fs.readFileSync(f, "utf8");
if (s.includes("__cck_refresh_retry")) { console.log("token-refresh patch already verified"); process.exit(0); }
const re = /consola\.error\("Failed to refresh Copilot token:", error\);\s*throw error;/;
const hits = s.match(new RegExp(re.source, "g")) || [];
if (hits.length !== 1) {
  console.error("Upstream bundle does not match the supported token-refresh patch; no changes written.");
  process.exit(1);
}
s = s.replace(re, [
  'consola.error("Failed to refresh Copilot token (__cck_refresh_retry):", error);',
  'globalThis.__cck_refresh_retry = (globalThis.__cck_refresh_retry || 0) + 1;',
  'const __d = Math.min(300, 5 * Math.pow(2, Math.min(globalThis.__cck_refresh_retry - 1, 6))) * 1e3;',
  'setTimeout(async () => { try { const r = await getCopilotToken(); state.copilotToken = r.token; ',
  'globalThis.__cck_refresh_retry = 0; consola.info("Copilot token recovered after retry"); } ',
  'catch (e) { consola.error("Copilot token retry failed:", e); } }, __d).unref?.();'
].join(""));
const tmp = f + ".cck-tmp." + process.pid;
try {
  fs.writeFileSync(tmp, s, { mode: fs.statSync(f).mode });
  fs.renameSync(tmp, f);
} catch (e) {
  try { fs.unlinkSync(tmp); } catch {}
  console.error(`could not write ${f}: ${e.code || e.message} (try re-running with write access to the npm global dir)`);
  process.exit(2);
}
console.log("token-refresh patch applied and verified");
REFRESH_PATCH_EOF
  then
    ok "copilot-api token-refresh patch verified (backoff, no crash)"
  else
    warn "token-refresh crash fix NOT verified; unsupported upstream bundle or write failure (see above)"
  fi
}

write_plist() {  # $1=path $2=label $3..=program args
  local path="$1" label="$2"; shift 2
  local args="" a
  for a in "$@"; do args+="    <string>${a}</string>"$'\n'; done
  mkdir -p "$LA_DIR"
  cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
${args}  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${NODE_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOST</key>
    <string>${BIND_HOST}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/${label}.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/${label}.err</string>
</dict>
</plist>
EOF
}

# The watchdog is a PERIODIC job, not a resident daemon: StartInterval + RunAtLoad
# and deliberately NO KeepAlive (write_plist hardcodes KeepAlive, which would make
# it run forever instead of every WATCHDOG_INTERVAL seconds). After sleep/wake,
# launchd runs a missed interval promptly, so "just woke up" is covered too.
write_watchdog_plist() {
  mkdir -p "$LA_DIR"
  cat > "$WATCHDOG_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.copilot-api-watchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WATCHDOG}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${NODE_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartInterval</key>
  <integer>${WATCHDOG_INTERVAL}</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/com.copilot-api-watchdog.out</string>
  <key>StandardErrorPath</key>
  <string>/tmp/com.copilot-api-watchdog.err</string>
</dict>
</plist>
EOF
}

plist_binds_loopback() {  # $1=plist; true if its env pins HOST to BIND_HOST
  [ -f "$1" ] && tr -d ' \t\n' < "$1" | grep -qF "<key>HOST</key><string>${BIND_HOST}</string>"
}

load_service() {  # $1=plist $2=label
  launchctl unload "$1" >/dev/null 2>&1 || true
  launchctl load "$1" || warn "launchctl load reported an issue for $2 (may already be loaded)"
}

wait_for_port() {  # $1=port $2=tries
  local port="$1" tries="${2:-20}" i=0
  while [ "$i" -lt "$tries" ]; do
    if curl -fsS -m 2 "http://localhost:${port}/v1/models" >/dev/null 2>&1; then return 0; fi
    i=$((i+1)); sleep 1
  done
  return 1
}

is_authed() {  # daemon up AND /v1/models returns a model list (not 401)
  local out
  out="$(curl -fsS -m 3 "http://localhost:${API_PORT}/v1/models" 2>/dev/null)" || return 1
  case "$out" in *'"id"'*) return 0 ;; *) return 1 ;; esac
}

# A freshly (re)started copilot-api binds its port well before it has fetched the
# model catalog — 15-25s can pass between the two. Asking is_authed once inside
# that window says "not authorized" about a machine that is perfectly authorized,
# which sends an already-working install into the device-code flow and then out
# through `exit 1`. Give the daemon room to finish before drawing a conclusion.
is_authed_retry() {  # ~30s across 6 tries (2+3+4+6+7+8)
  local w
  for w in 2 3 4 6 7 8; do
    is_authed && return 0
    sleep "$w"
  done
  is_authed
}

# Distinguishes "no network" from "no token" — without it, an offline machine is
# told to re-authorize, which cannot possibly help.
net_ok() { curl -fsS -m 8 -o /dev/null https://api.github.com/ >/dev/null 2>&1; }

service_loaded() {  # $1=label ; true if launchd knows this service (no pipe -> no SIGPIPE/pipefail trap)
  launchctl list "$1" >/dev/null 2>&1
}

merge_settings() {
  "$NODE_BIN" - "$SETTINGS" <<'NODE_EOF'
const fs = require("fs");
const path = process.argv[2];
fs.mkdirSync(require("path").dirname(path), { recursive: true });
let d = {};
if (fs.existsSync(path)) {
  fs.copyFileSync(path, path + ".bak");
  try { d = JSON.parse(fs.readFileSync(path, "utf8")); } catch { d = {}; }
}
d.env = d.env || {};
Object.assign(d.env, {
  ANTHROPIC_BASE_URL: "http://localhost:4142",
  ANTHROPIC_AUTH_TOKEN: "dummy",
  // NOTE: we deliberately do NOT pin ANTHROPIC_MODEL. Pinning it locks the
  // in-app model/effort picker in Claude Code & Claude Desktop ("model is set
  // by ANTHROPIC_MODEL"), so you can't change effort. The normalizer maps
  // whatever model id the app sends, so pinning is unnecessary.
  // Defaults keep /model usable; an explicit saved model selection wins.
  // The sonnet/haiku aliases are pinned to the newest Claude ids Copilot
  // serves; the normalizer falls back to the newest served id of the same
  // family if a seat doesn't have them yet (instead of a 400).
  ANTHROPIC_DEFAULT_OPUS_MODEL: "claude-opus-5-5",
  ANTHROPIC_DEFAULT_SONNET_MODEL: "claude-sonnet-5-5",
  ANTHROPIC_DEFAULT_HAIKU_MODEL: "claude-haiku-5-5",
  ANTHROPIC_DEFAULT_MODEL: "opus",
  // Deprecated name for the haiku slot; kept for older Claude Code builds.
  ANTHROPIC_SMALL_FAST_MODEL: "claude-haiku-5-5",
  CLAUDE_CODE_DISABLE_LEGACY_MODEL_REMAP: "1",
  CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1",
  DISABLE_PROMPT_CACHING: "1",
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
});
// If an older install pinned the main model, remove it so the picker unlocks.
delete d.env.ANTHROPIC_MODEL;
fs.writeFileSync(path, JSON.stringify(d, null, 2));
console.log("  merged env into " + path + (fs.existsSync(path + ".bak") ? " (backup: " + path + ".bak)" : ""));
NODE_EOF
}

NO_CLAUDE_HINT="This Copilot account has no Claude models enabled; ask your org admin to enable them in Copilot policy."
claude_models_available() {  # 0 = Claude ids listed, 1 = list has none, 2 = unknown
  local out node
  node="${NODE_BIN:-$(find_node)}" || return 2
  out="$(curl -fsS -m 10 "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null)" || return 2
  printf '%s' "$out" | "$node" -e '
    let s=""; process.stdin.on("data", c => s+=c); process.stdin.on("end", () => {
      let ids; try { ids=(JSON.parse(s).data||[]).map(m => m && m.id).filter(i => typeof i === "string"); } catch { process.exit(2); }
      if (!ids.length) process.exit(2);
      process.exit(ids.some(i => /^claude-/.test(i)) ? 0 : 1);
    });'
}

smoke_test() {  # test Opus 5.5 explicitly (x-cck-exact-model: no fallback to older Opus)
  local out node
  node="${NODE_BIN:-$(find_node)}" || return 1
  out="$(curl -fsS -m 30 "http://localhost:${NORM_PORT}/v1/messages" \
    -H 'content-type: application/json' -H 'x-api-key: dummy' -H 'anthropic-version: 2023-06-01' \
    -H 'x-cck-exact-model: 1' \
    -d '{"model":"claude-opus-5-5","stream":false,"max_tokens":1024,"messages":[{"role":"user","content":"ping"}]}' 2>/dev/null)" || return 1
  printf '%s' "$out" | "$node" -e '
    let s=""; process.stdin.on("data", c => s+=c); process.stdin.on("end", () => {
      try { const j=JSON.parse(s); process.exit(j.type === "message" && !j.error &&
        Array.isArray(j.content) && j.content.some(c => c.type === "text" && c.text?.trim()) ? 0 : 1); }
      catch { process.exit(1); }
    });'
}

CODEX_PROFILE="$CODEX_DIR/copilot.config.toml"
write_codex_profile() {
  mkdir -p "$CODEX_DIR"
  [ -f "$CODEX_PROFILE" ] && cp "$CODEX_PROFILE" "$CODEX_PROFILE.bak"
  cat > "$CODEX_PROFILE" <<EOF
# Written by copilot-claude-kit (bash install.sh --with-codex).
# A self-contained Codex profile — use it with:   codex --profile copilot
# It routes Codex through the local proxy to GitHub Copilot's Responses API,
# which is how GPT-6.x and GPT-5.x models are served. Edit 'model' to taste;
# the picker lists the models that passed a live probe at install time.
model = "$CODEX_DESKTOP_MODEL"
model_provider = "copilot"
model_catalog_json = "$CODEX_PROFILE_CATALOG"
approval_policy = "on-request"
approvals_reviewer = "user"
sandbox_mode = "workspace-write"

[model_providers.copilot]
name = "GitHub Copilot (local proxy)"
base_url = "http://localhost:${NORM_PORT}/v1"
wire_api = "responses"
EOF
  ok "wrote Codex profile: $CODEX_PROFILE"
}

read_codex_model() {
  local node
  node="${NODE_BIN:-$(find_node)}" || return 1
  "$node" -e 'const fs=require("fs"); const s=fs.readFileSync(process.argv[1],"utf8").split(/^\s*\[/m)[0]; const m=s.match(/^model\s*=\s*"([^"\n]+)"/m); if (!m) process.exit(1); console.log(m[1]);' "$1"
}

codex_smoke_test() {  # POST /v1/responses through the normalizer; expect a completed response
  local model="${1:-$CODEX_DESKTOP_MODEL}" out node
  node="${NODE_BIN:-$(find_node)}" || return 1
  out="$(curl -fsS -m 40 "http://localhost:${NORM_PORT}/v1/responses" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"${model}\",\"input\":\"reply with exactly one word: pong\",\"stream\":false}" 2>/dev/null)" || return 1
  printf '%s' "$out" | "$node" -e '
    let s=""; process.stdin.on("data", c => s+=c); process.stdin.on("end", () => {
      try { const j=JSON.parse(s); process.exit(j.status === "completed" && !j.error &&
        Array.isArray(j.output) && j.output.some(o => o.type === "message" &&
        o.content?.some(c => c.type === "output_text" && c.text?.trim())) ? 0 : 1); }
      catch { process.exit(1); }
    });'
}

# Probe known Codex-capable models with real completions, not cached /models.
# The explicit/default selection must succeed; alternatives never silently replace it.
select_codex_models() {
  local model
  codex_smoke_test "$CODEX_DESKTOP_MODEL" || die "$CODEX_DESKTOP_MODEL failed its Responses check; Codex config was not changed. Check connectivity/account access, or use --codex-model gpt-5.6-sol."
  CODEX_VERIFIED_MODELS=("$CODEX_DESKTOP_MODEL")
  for model in "${CODEX_MODEL_CHOICES[@]}"; do
    [ "$model" != "$CODEX_DESKTOP_MODEL" ] || continue
    if codex_smoke_test "$model"; then
      CODEX_VERIFIED_MODELS+=("$model")
      ok "Available in Codex picker: $model"
    else
      warn "$model did not complete its probe; omitted from picker"
    fi
  done
}

backup_codex_file() {
  local path="$1" stamp backup n=1
  [ -f "$path" ] || return 0
  stamp="$(date '+%Y%m%d-%H%M%S')"
  backup="${path}.bak.${stamp}.$$"
  while [ -e "$backup" ]; do
    backup="${path}.bak.${stamp}.$$.$n"
    n=$((n+1))
  done
  cp "$path" "$backup" || return 1
  ok "backup: $backup"
}

prepare_codex_catalog_backup() {
  mkdir -p "$CODEX_DIR"
  if [ ! -e "$CODEX_CATALOG_BACKUP" ] && [ ! -e "$CODEX_CATALOG_CREATED_MARKER" ]; then
    if [ -f "$CODEX_CATALOG" ]; then
      cp "$CODEX_CATALOG" "$CODEX_CATALOG_BACKUP" || die "couldn't back up $CODEX_CATALOG"
      ok "preserved existing model catalog: $CODEX_CATALOG_BACKUP"
    else
      : > "$CODEX_CATALOG_CREATED_MARKER"
    fi
  fi
}

write_codex_catalog() {
  prepare_codex_catalog_backup
  build_codex_catalog "$CODEX_CATALOG"
}

build_codex_catalog() {  # $1 = destination catalog path
  local dest="$1" tmp="${1}.tmp.$$"
  mkdir -p "$(dirname "$dest")"
  cat > "$tmp" <<'CATALOG_EOF'
{
  "models": [
    {
      "slug": "gpt-5.6-sol",
      "display_name": "GPT-5.6 Sol (Copilot)",
      "description": "GitHub Copilot through the local Responses proxy.",
      "default_reasoning_level": "high",
      "supported_reasoning_levels": [
        { "effort": "low", "description": "Fast" },
        { "effort": "medium", "description": "Balanced" },
        { "effort": "high", "description": "Deep reasoning" },
        { "effort": "xhigh", "description": "Extra deep reasoning" },
        { "effort": "max", "description": "Maximum reasoning" }
      ],
      "shell_type": "shell_command",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 1,
      "context_window": 272000,
      "base_instructions": "You are Codex, a coding agent. Work carefully, use tools when needed, and complete the user's request.",
      "support_verbosity": true,
      "default_verbosity": "low",
      "truncation_policy": { "mode": "tokens", "limit": 10000 },
      "experimental_supported_tools": [],
      "supports_parallel_tool_calls": true,
      "supports_reasoning_summary_parameter": true,
      "default_reasoning_summary": "none",
      "apply_patch_tool_type": "freeform",
      "web_search_tool_type": "text_and_image",
      "input_modalities": ["text", "image"]
    }
  ]
}
CATALOG_EOF
  local node
  node="${NODE_BIN:-$(find_node)}" || die "Node.js required for model catalog"
  "$node" - "$tmp" "${CODEX_VERIFIED_MODELS[@]}" <<'CATALOG_MODELS_EOF'
const fs = require("fs");
const [path, ...ids] = process.argv.slice(2);
if (!ids.length) throw new Error("No verified Codex models");
const catalog = JSON.parse(fs.readFileSync(path, "utf8"));
const template = catalog.models[0];
const names = {
  "gpt-6.1-sol": "GPT-6.1 Sol", "gpt-6-astra": "GPT-6 Astra", "gpt-6-sol": "GPT-6 Sol",
  "gpt-6-luna": "GPT-6 Luna", "gpt-5.6-sol": "GPT-5.6 Sol", "gpt-5.6-sol-fast": "GPT-5.6 Sol Fast",
  "gpt-5.6-terra": "GPT-5.6 Terra", "gpt-5.6-luna": "GPT-5.6 Luna",
  "gpt-5.5": "GPT-5.5", "gpt-5.4": "GPT-5.4", "gpt-5.3-codex": "GPT-5.3-Codex",
};
// GPT-6.x and GPT-5.6 accept low..max; GPT-5.5 and older stop at xhigh.
const noMax = new Set(["gpt-5.5", "gpt-5.4", "gpt-5.3-codex"]);
const levelsFor = (slug) => template.supported_reasoning_levels
  .filter((l) => !(noMax.has(slug) && l.effort === "max"));
// Keep the existing conservative proxy context budget. OpenAI's direct API
// context window is not evidence of the window available on a Copilot seat.
catalog.models = ids.map((slug, i) => ({ ...template, slug,
  display_name: `${names[slug] || slug} (Copilot)`, priority: i + 1,
  supported_reasoning_levels: levelsFor(slug) }));
fs.writeFileSync(path, JSON.stringify(catalog, null, 2) + "\n");
CATALOG_MODELS_EOF
  [ "$?" -eq 0 ] || { rm -f "$tmp"; die "couldn't build model catalog"; }
  mv "$tmp" "$dest" || die "couldn't write $dest"
  ok "wrote Codex model catalog: $dest"
}

merge_codex_desktop_config() {
  local node
  node="${NODE_BIN:-$(find_node)}" || die "Node.js is required to merge Codex config safely"
  mkdir -p "$CODEX_DIR"
  if [ ! -f "$CODEX_CONFIG" ] && [ ! -e "$CODEX_CONFIG_CREATED_MARKER" ]; then
    : > "$CODEX_CONFIG_CREATED_MARKER"
  fi
  backup_codex_file "$CODEX_CONFIG" || die "couldn't back up $CODEX_CONFIG"

  "$node" - "$CODEX_CONFIG" "$CODEX_CATALOG" "$CODEX_DESKTOP_MODEL" "$NORM_PORT" \
    "$CODEX_ROOT_BEGIN" "$CODEX_ROOT_END" "$CODEX_PROVIDER_BEGIN" "$CODEX_PROVIDER_END" <<'NODE_EOF'
const fs = require("fs");
const [
  configPath, catalogPath, model, port,
  rootBegin, rootEnd, providerBegin, providerEnd,
] = process.argv.slice(2);
const disabled = "# CCK-DISABLED ";

let lines = fs.existsSync(configPath)
  ? fs.readFileSync(configPath, "utf8").replace(/\r\n/g, "\n").split("\n")
  : [];

function stripManaged(input, begin, end) {
  const out = [];
  let skipping = false;
  for (const line of input) {
    if (!skipping && line === begin) { skipping = true; continue; }
    if (skipping && line === end) { skipping = false; continue; }
    if (!skipping) out.push(line);
  }
  return out;
}

// Make re-runs idempotent: first return the previous managed edit to its
// original shape, then apply the current values.
lines = stripManaged(lines, rootBegin, rootEnd);
lines = stripManaged(lines, providerBegin, providerEnd);
lines = lines.map((line) => line.startsWith(disabled) ? line.slice(disabled.length) : line);

// Preserve, but temporarily disable, only the root keys Codex Desktop needs.
let firstTable = lines.findIndex((line) => /^\s*\[/.test(line));
if (firstTable < 0) firstTable = lines.length;
const rootKey = /^\s*(model|model_provider|model_catalog_json|model_reasoning_effort|approval_policy|approvals_reviewer|sandbox_mode)\s*=/;
for (let i = 0; i < firstTable; i++) {
  if (rootKey.test(lines[i])) lines[i] = disabled + lines[i];
}

// Preserve an existing copilot provider table verbatim. The managed provider is
// appended at the end; restore simply removes ours and uncomments theirs.
let inCopilotProvider = false;
let inApprovalPolicy = false;
for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  if (/^\s*\[/.test(line)) {
    inApprovalPolicy = /^\s*\[\s*approval_policy(?:\s*\]|\.)/.test(line);
    inCopilotProvider =
      /^\s*\[\s*model_providers\.(?:copilot|"copilot"|'copilot')(?:\s*\]|\.)/.test(line);
  }
  if (inCopilotProvider || inApprovalPolicy) lines[i] = disabled + line;
}

firstTable = lines.findIndex((line) => /^\s*\[/.test(line));
if (firstTable < 0) firstTable = lines.length;
const rootBlock = [
  rootBegin,
  `model = ${JSON.stringify(model)}`,
  'model_provider = "copilot"',
  `model_catalog_json = ${JSON.stringify(catalogPath)}`,
  'model_reasoning_effort = "high"',
  'approval_policy = "on-request"',
  'approvals_reviewer = "user"',
  'sandbox_mode = "workspace-write"',
  "",
  rootEnd,
];
lines.splice(firstTable, 0, ...rootBlock);

lines.push(
  providerBegin,
  "[model_providers.copilot]",
  'name = "GitHub Copilot (local proxy)"',
  `base_url = "http://127.0.0.1:${port}/v1"`,
  'wire_api = "responses"',
  "",
  providerEnd
);

const tmp = configPath + ".tmp." + process.pid;
fs.writeFileSync(tmp, lines.join("\n"));
fs.renameSync(tmp, configPath);
NODE_EOF
  [ "$?" -eq 0 ] || die "couldn't merge Codex config"
  ok "merged Codex Desktop config: $CODEX_CONFIG"
}

restore_codex_desktop_config() {
  local node changed=0
  node="$(find_node)" || die "Node.js is required to restore Codex config safely"

  if [ -f "$CODEX_CONFIG" ] && grep -qF "$CODEX_ROOT_BEGIN" "$CODEX_CONFIG" 2>/dev/null; then
    backup_codex_file "$CODEX_CONFIG" || die "couldn't back up $CODEX_CONFIG"
    "$node" - "$CODEX_CONFIG" "$CODEX_ROOT_BEGIN" "$CODEX_ROOT_END" \
      "$CODEX_PROVIDER_BEGIN" "$CODEX_PROVIDER_END" <<'NODE_EOF'
const fs = require("fs");
const [configPath, rootBegin, rootEnd, providerBegin, providerEnd] = process.argv.slice(2);
const disabled = "# CCK-DISABLED ";
let lines = fs.readFileSync(configPath, "utf8").replace(/\r\n/g, "\n").split("\n");
function stripManaged(input, begin, end) {
  const out = [];
  let skipping = false;
  for (const line of input) {
    if (!skipping && line === begin) { skipping = true; continue; }
    if (skipping && line === end) { skipping = false; continue; }
    if (!skipping) out.push(line);
  }
  return out;
}
lines = stripManaged(lines, rootBegin, rootEnd);
lines = stripManaged(lines, providerBegin, providerEnd);
lines = lines.map((line) => line.startsWith(disabled) ? line.slice(disabled.length) : line);
let text = lines.join("\n");
const tmp = configPath + ".tmp." + process.pid;
fs.writeFileSync(tmp, text);
fs.renameSync(tmp, configPath);
NODE_EOF
    changed=1
    if [ -e "$CODEX_CONFIG_CREATED_MARKER" ] && ! grep -q '[^[:space:]]' "$CODEX_CONFIG"; then
      rm -f "$CODEX_CONFIG"
    fi
    rm -f "$CODEX_CONFIG_CREATED_MARKER"
    ok "restored previous Codex config"
  fi

  if [ -f "$CODEX_CATALOG_BACKUP" ]; then
    mv "$CODEX_CATALOG_BACKUP" "$CODEX_CATALOG" || die "couldn't restore previous model catalog"
    rm -f "$CODEX_CATALOG_CREATED_MARKER"
    changed=1
    ok "restored previous Codex model catalog"
  elif [ -e "$CODEX_CATALOG_CREATED_MARKER" ]; then
    rm -f "$CODEX_CATALOG" "$CODEX_CATALOG_CREATED_MARKER"
    changed=1
    ok "removed Codex model catalog created by this installer"
  fi

  [ "$changed" -eq 1 ] || warn "no managed Codex Desktop configuration found"
}

find_codex_binary() {
  local candidate
  for candidate in \
    "/Applications/ChatGPT.app/Contents/Resources/codex" \
    "/Applications/Codex.app/Contents/Resources/codex"
  do
    if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  command -v codex 2>/dev/null
}

codex_desktop_tool_test() {
  local bin output log rc=0
  bin="$(find_codex_binary)" || return 2
  output="$(mktemp -t cck-codex-output)"
  log="$(mktemp -t cck-codex-log)"
  "$bin" exec --skip-git-repo-check --sandbox read-only --color never \
    -c 'model_reasoning_effort="low"' -o "$output" \
    "Use the local shell tool exactly once to run: printf desktop-copilot-ok. Then reply with exactly desktop-copilot-ok and nothing else." \
    >"$log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && grep -qx 'desktop-copilot-ok' "$output" 2>/dev/null; then
    rm -f "$output" "$log"
    return 0
  fi
  warn "Codex executable test failed (exit $rc); diagnostic tail:"
  tail -n 8 "$log" 2>/dev/null || true
  rm -f "$output" "$log"
  return 1
}

# A real approval-boundary test. Observe the client approval RPC and decline it;
# no command outside the sandbox is approved or executed by this installer.
# A sandbox printf or a model merely repeating a marker cannot pass this check.
codex_approval_test() {
  local bin node
  bin="$(find_codex_binary)" || return 2
  node="${NODE_BIN:-$(find_node)}" || return 2
  "$node" - "$bin" <<'APPROVAL_TEST_EOF'
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const readline = require("readline");
const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "cck-approval-"));
const child = spawn(process.argv[2], ["app-server", "--listen", "stdio://"],
  { cwd, stdio: ["pipe", "pipe", "pipe"] });
let sequence = 0, finished = false, observed = false, threadId;
const pending = new Map();
function finish(code, message) {
  if (finished) return;
  finished = true;
  clearTimeout(timer);
  console.log(message);
  child.kill("SIGTERM");
  setTimeout(() => { child.kill("SIGKILL"); fs.rmSync(cwd, { recursive: true, force: true }); process.exit(code); }, 300);
}
const timer = setTimeout(() => finish(1, "Approval test timed out; approval routing is NOT verified."), 60000);
child.on("error", e => finish(1, "Cannot start Codex app-server: " + e.message));
child.on("exit", code => { if (!finished) finish(1, `Codex app-server exited (${code}); approval routing NOT verified.`); });
// Drain diagnostics without printing credentials, prompts, or unrelated config.
child.stderr.resume();
function send(message) { child.stdin.write(JSON.stringify(message) + "\n"); }
child.stdin.on("error", () => finish(1, "Codex app-server input closed."));
function rpc(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve, reject });
    send({ id, method, params });
  });
}
readline.createInterface({ input: child.stdout }).on("line", line => {
  let msg; try { msg = JSON.parse(line); } catch { return; }
  if (msg.method && msg.id !== undefined) {
    if (msg.method === "item/commandExecution/requestApproval") {
      observed = msg.params?.threadId === threadId;
      send({ id: msg.id, result: { decision: "decline" } });
      if (observed) finish(0, "Approval boundary verified: Codex sent a client approval request; test declined it without escalation. Desktop UI confirmation still needs a manual check.");
      else finish(1, "Unexpected approval thread; test failed.");
    } else {
      send({ id: msg.id, error: { code: -32601, message: "Installer test does not approve this operation" } });
      finish(1, "Unexpected approval/tool request: " + msg.method);
    }
    return;
  }
  if (pending.has(msg.id)) {
    const p = pending.get(msg.id); pending.delete(msg.id);
    msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
  }
  if (msg.method === "turn/completed" && !observed)
    finish(1, "Turn finished without a client approval request; approval routing is NOT verified.");
  if (msg.method === "error" && !msg.params?.willRetry)
    finish(1, "Codex turn failed; inspect Codex/proxy logs for approval or model errors.");
});
(async () => {
  await rpc("initialize", { clientInfo: { name: "cck_approval_test", version: "1.0" }, capabilities: { experimentalApi: true } });
  send({ method: "initialized" });
  const { config } = await rpc("config/read", { includeLayers: false });
  if (config.model_provider !== "copilot") throw new Error("Effective provider is not copilot");
  if (config.approvals_reviewer !== "user" || config.approval_policy !== "on-request")
    throw new Error('Effective config must use approvals_reviewer="user" and approval_policy="on-request". Select Ask for approval, then retry.');
  // Detect app-specific auto reviewers that would survive the root setting.
  for (const [name, app] of Object.entries(config.apps || {})) {
    if (app?.approvals_reviewer && app.approvals_reviewer !== "user")
      throw new Error(`apps.${name}.approvals_reviewer still selects automatic review`);
  }
  const t = await rpc("thread/start", { cwd, ephemeral: true, sandbox: "read-only" });
  threadId = t.thread.id;
  if (t.approvalPolicy !== "on-request" || t.approvalsReviewer !== "user")
    throw new Error("Thread effective approval settings are not manual; check managed requirements or permission profiles.");
  await rpc("turn/start", { threadId, effort: "low", input: [{ type: "text", text:
    "Installation diagnostic: call the shell tool once with command `printf cck-approval-probe`, explicitly request sandbox_permissions=require_escalated and give justification 'Test the approval dialog'. Do not run it without escalation, use another tool, or retry. The client will decline the request; that is the expected result. No other action is needed." }] });
})().catch(e => finish(1, "Approval test failed: " + e.message));
APPROVAL_TEST_EOF
}

do_with_codex() {
  do_install codex
  step "Setting up Codex (GitHub Copilot via Responses API)"
  select_codex_models
  build_codex_catalog "$CODEX_PROFILE_CATALOG"
  write_codex_profile
  printf '%s\n' "$CODEX_DESKTOP_MODEL" > "$CODEX_WATCHDOG_MODEL_FILE"
  if codex_smoke_test; then ok "Codex round-trip through :$NORM_PORT/v1/responses succeeded"; else warn "Codex self-test didn't complete; the proxy is up — try 'codex --profile copilot'"; fi
  printf '\n%s%s Codex ready.%s Run: %scodex --profile copilot%s\n' "$G" "$B" "$X" "$B" "$X"
  command -v codex >/dev/null 2>&1 || warn "codex CLI not found on PATH — install it, then use 'codex --profile copilot'"
}

do_with_codex_desktop() {
  local approval_rc=0 claude_rc=0
  # Share setup/auth once; still configure Codex if the Claude model probe fails.
  do_install combined || claude_rc=$?
  step "Checking Codex models through Copilot's Responses API"
  select_codex_models

  step "Setting up Codex Desktop globally (with reversible config merge)"
  write_codex_catalog
  merge_codex_desktop_config
  printf '%s\n' "$CODEX_DESKTOP_MODEL" > "$CODEX_WATCHDOG_MODEL_FILE"

  step "Testing a real Codex local-shell tool call"
  if codex_desktop_tool_test; then
    ok "Codex completed a local-shell tool call through Copilot"
  else
    case "$?" in
      2) warn "Codex executable not found; config is ready for Codex Desktop when installed" ;;
      *) warn "direct Responses test passed, but the Codex executable test did not; run --verify for diagnostics" ;;
    esac
  fi

  step "Testing the real Codex approval boundary (request then decline)"
  if codex_approval_test; then
    ok "Manual approval routing passed"
  else
    approval_rc=$?
    warn "Approval self-test NOT verified. Run --verify after installing/updating Codex; use Ask for approval in the app."
  fi

  printf '\n%s%s Claude Code + Codex Desktop are configured.%s Fully quit and reopen both clients.%s\n' "$G" "$B" "$X" "$X"
  say "This changes the shared user-level Codex model/provider selection."
  say "Undo only the Codex change (keep Claude): bash install.sh --restore-codex-desktop"
  [ "$claude_rc" -eq 0 ] || return "$claude_rc"
  [ "$approval_rc" -eq 2 ] && return 0  # no installed Codex: explicitly reported as unverified
  return "$approval_rc"
}

do_restore_codex_desktop() {
  need_macos
  step "Restoring Codex Desktop configuration"
  restore_codex_desktop_config
  if [ -f "$WATCHDOG_MODE_FILE" ] && [ "$(cat "$WATCHDOG_MODE_FILE")" = "combined" ]; then
    printf '%s\n' claude > "$WATCHDOG_MODE_FILE"
    ok "Claude configuration retained; watchdog now checks Claude"
  fi
  say ""
  ok "Codex Desktop settings restored. Fully quit and reopen the app."
}

# ===========================================================================
#  commands
# ===========================================================================
do_install() {
  local install_mode="${1:-claude}" smoke_rc=0
  need_macos
  step "Checking prerequisites"
  ensure_node
  ensure_copilot_api

  step "Writing the model-id normalizer"
  write_normalizer

  step "Creating background services (launchd)"
  # Always rewritten (and reloaded below), so re-running over an older install
  # also picks up the loopback-only HOST binding.
  write_plist "$API_PLIST" "com.copilot-api" "$COPILOT_API_BIN" "start"
  write_plist "$NORM_PLIST" "com.copilot-api-normalize" "$NODE_BIN" "$NORMALIZER"
  load_service "$API_PLIST" "com.copilot-api"
  ok "copilot-api service loaded"

  step "Waiting for copilot-api on :$API_PORT"
  if wait_for_port "$API_PORT" 15; then
    ok "copilot-api is responding"
  else
    warn "copilot-api is up but not returning models yet — likely needs GitHub authorization"
  fi

  if ! is_authed_retry; then
    step "GitHub authorization (one-time, needs you)"
    say "A device code will appear below. Open the URL, enter the code, approve Copilot access."
    say "${B}This is the only manual step.${X}"
    echo
    # copilot-api auth just prints the device code/URL and polls GitHub — it
    # needs no stdin. But when this script is run via `curl | bash`, stdin is
    # the script text, so attach the real terminal if one is available, in case
    # a future version prompts.
    if [ -r /dev/tty ]; then
      "$COPILOT_API_BIN" auth < /dev/tty || warn "auth exited non-zero; if you approved it in the browser, that's usually fine"
    else
      "$COPILOT_API_BIN" auth || warn "auth exited non-zero; if you approved it in the browser, that's usually fine"
    fi
    echo
    # auth writes the token; restart copilot-api so it picks it up
    load_service "$API_PLIST" "com.copilot-api"
    wait_for_port "$API_PORT" 20 || true
  fi

  if ! is_authed_retry; then
    if ! net_ok; then
      err "Can't reach github.com — this looks like a network/VPN problem, not an auth one."
      err "Reconnect and re-run. Nothing else needs doing; the watchdog will pick it up on its own."
    else
      err "Still not authorized to Copilot. Re-run 'bash install.sh' after finishing the browser step."
      err "Check logs: /tmp/com.copilot-api.err"
    fi
    exit 1
  fi
  ok "authorized to Copilot — models are available"

  step "Starting the normalizer on :$NORM_PORT"
  load_service "$NORM_PLIST" "com.copilot-api-normalize"
  if wait_for_port "$NORM_PORT" 15; then
    ok "normalizer is forwarding to copilot-api"
  else
    die "normalizer didn't come up. Check /tmp/com.copilot-api-normalize.err"
  fi

  step "Installing the watchdog (auto-heals a wedged daemon after sleep/reboot)"
  printf '%s\n' "$install_mode" > "$WATCHDOG_MODE_FILE"
  write_watchdog
  write_watchdog_plist
  load_service "$WATCHDOG_PLIST" "com.copilot-api-watchdog"
  ok "watchdog active — probes :$API_PORT/:$NORM_PORT every ${WATCHDOG_INTERVAL}s"

  if [ "$install_mode" = "codex" ]; then
    step "Codex proxy ready"
    ok "watchdog will probe the Responses API (Claude settings left untouched)"
  else
    say "Opus 5.5 requires Claude Code 2.1.280 or newer: run claude update."
    step "Pointing Claude Code at the proxy (~/.claude/settings.json)"
    merge_settings || die "could not write Claude settings"

    step "End-to-end self-test"
    local claude_rc=0
    claude_models_available || claude_rc=$?
    if [ "$claude_rc" -eq 1 ]; then
      smoke_rc=1
      err "$NO_CLAUDE_HINT"
      warn "Claude settings are in place and will work once Claude models are enabled; Codex/GPT models are unaffected (bash install.sh --with-codex)."
    elif smoke_test; then
      ok "Opus 5.5 round-trip through :$NORM_PORT succeeded"
    else
      smoke_rc=1
      warn "Opus 5.5 self-test failed: check account rollout/model policy and /tmp/com.copilot-api.err. Opus 5.5 access is NOT verified."
    fi

    printf '\n%s%s Claude proxy configured.%s Open a NEW terminal and run: %sclaude%s\n' "$G" "$B" "$X" "$B" "$X"
    say "Claude Desktop's built-in Claude Code will use this automatically too."
    say "If a saved model still selects an older version, run /model opus (or /model claude-opus-5-5)."
  fi
  say "Add Codex CLI profile:  bash install.sh --with-codex"
  say "Configure Codex Desktop: bash install.sh --with-codex-desktop"
  say "Health-check anytime:  bash install.sh --verify"
  say "Remove everything:     bash install.sh --uninstall"
  return "$smoke_rc"
}

do_verify() {
  need_macos
  local fail=0 install_mode="claude"
  [ -f "$WATCHDOG_MODE_FILE" ] && install_mode="$(cat "$WATCHDOG_MODE_FILE" 2>/dev/null || echo claude)"
  step "Health check"

  if service_loaded com.copilot-api; then ok "launchd: com.copilot-api loaded"; else err "launchd: com.copilot-api NOT loaded"; fail=1; fi
  if service_loaded com.copilot-api-normalize; then ok "launchd: com.copilot-api-normalize loaded"; else err "launchd: com.copilot-api-normalize NOT loaded"; fail=1; fi
  if service_loaded com.copilot-api-watchdog; then ok "launchd: com.copilot-api-watchdog loaded"; else warn "launchd: com.copilot-api-watchdog NOT loaded (auto-heal off; re-run: bash install.sh)"; fi

  if plist_binds_loopback "$API_PLIST"; then ok "copilot-api bound to $BIND_HOST only"
  else err "copilot-api plist has no HOST=$BIND_HOST, so :$API_PORT listens on all interfaces (re-run: bash install.sh)"; fail=1; fi

  if curl -fsS -m 3 "http://localhost:$API_PORT/v1/models" >/dev/null 2>&1; then ok ":$API_PORT copilot-api responding"; else err ":$API_PORT copilot-api not responding"; fail=1; fi
  if curl -fsS -m 3 "http://localhost:$NORM_PORT/v1/models" >/dev/null 2>&1; then ok ":$NORM_PORT normalizer responding"; else err ":$NORM_PORT normalizer not responding"; fail=1; fi

  if is_authed_retry; then ok "authorized to Copilot (models listed)"
  elif ! net_ok; then warn "can't reach github.com — network/VPN issue, not auth; reconnect and re-check"; fail=1
  else err "not authorized to Copilot (run: copilot-api auth)"; fail=1; fi

  if [ "$install_mode" = "codex" ]; then
    ok "watchdog mode: Codex Responses API"
  else
    if [ -f "$SETTINGS" ] && grep -q "localhost:$NORM_PORT" "$SETTINGS" 2>/dev/null; then
      ok "settings.json points at :$NORM_PORT"
    else
      err "settings.json missing or not pointing at :$NORM_PORT"; fail=1
    fi
    [ "$install_mode" != "combined" ] || ok "watchdog mode: Claude Messages + Codex Responses"
    step "Claude end-to-end self-test"
    local claude_rc=0
    claude_models_available || claude_rc=$?
    if [ "$claude_rc" -eq 1 ]; then err "$NO_CLAUDE_HINT"; fail=1
    elif smoke_test; then ok "Opus 5.5 round-trip through :$NORM_PORT succeeded"; else err "smoke test failed — check /tmp/com.copilot-api.err"; fail=1; fi
  fi

  if [ "$install_mode" = "combined" ] && ! grep -qF "$CODEX_ROOT_BEGIN" "$CODEX_CONFIG" 2>/dev/null; then
    err "Combined install is missing Codex Desktop configuration; re-run --with-codex-desktop"
    fail=1
  fi

  if [ -f "$CODEX_PROFILE" ]; then
    step "Codex check"
    local profile_model
    profile_model="$(read_codex_model "$CODEX_PROFILE")" || profile_model=""
    if [ -n "$profile_model" ] && codex_smoke_test "$profile_model"; then ok "Codex /v1/responses round-trip succeeded"; else err "Codex self-test failed — check /tmp/com.copilot-api-normalize.err"; fail=1; fi
  fi

  if [ -f "$CODEX_CONFIG" ] && grep -qF "$CODEX_ROOT_BEGIN" "$CODEX_CONFIG" 2>/dev/null; then
    step "Codex Desktop check"
    if [ -f "$CODEX_CATALOG" ]; then ok "Codex Desktop model catalog present"; else err "Codex Desktop model catalog missing"; fail=1; fi
    local selected node
    node="$(find_node)" || die "Node.js is required for verification"
    # Read the installed choice rather than checking this script's new default.
    selected="$(read_codex_model "$CODEX_CONFIG")" || selected=""
    if [ -n "$selected" ] && codex_smoke_test "$selected"; then ok "Codex Desktop $selected round-trip succeeded"; else err "Codex Desktop model round-trip failed"; fail=1; fi
    step "Codex approval boundary check"
    if codex_approval_test; then ok "Manual approval routing passed"; else err "Approval routing NOT verified (ordinary chat success is insufficient)"; fail=1; fi
  fi

  echo
  if [ "$fail" -eq 0 ]; then ok "${B}Everything looks healthy.${X}"; else err "${B}Some checks failed (see above).${X} Re-run your original install command (--with-codex-desktop for both clients) to repair."; exit 1; fi
}

do_uninstall() {
  need_macos
  step "Uninstalling"
  launchctl unload "$API_PLIST" >/dev/null 2>&1 || true
  launchctl unload "$NORM_PLIST" >/dev/null 2>&1 || true
  launchctl unload "$WATCHDOG_PLIST" >/dev/null 2>&1 || true
  rm -f "$API_PLIST" "$NORM_PLIST" "$WATCHDOG_PLIST" && ok "removed launchd services"
  rm -f "$NORMALIZER" "$WATCHDOG" "$WATCHDOG_MODE_FILE" "$CODEX_WATCHDOG_MODEL_FILE" && ok "removed normalizer + watchdog scripts"
  rm -f /tmp/com.copilot-api-watchdog.log /tmp/com.copilot-api-watchdog.notified \
        /tmp/com.copilot-api-watchdog.out /tmp/com.copilot-api-watchdog.err 2>/dev/null || true
  rmdir "$KIT_DIR" >/dev/null 2>&1 || true

  if [ -f "$SETTINGS" ]; then
    "$(find_node)" - "$SETTINGS" <<'NODE_EOF' || warn "couldn't auto-clean settings.json; edit it manually"
const fs = require("fs");
const path = process.argv[2];
let d; try { d = JSON.parse(fs.readFileSync(path, "utf8")); } catch { process.exit(0); }
if (d && d.env) {
  fs.copyFileSync(path, path + ".bak");
  for (const k of ["ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_MODEL","ANTHROPIC_DEFAULT_OPUS_MODEL","ANTHROPIC_DEFAULT_SONNET_MODEL","ANTHROPIC_DEFAULT_HAIKU_MODEL","ANTHROPIC_DEFAULT_MODEL","ANTHROPIC_SMALL_FAST_MODEL",
                    "CLAUDE_CODE_DISABLE_LEGACY_MODEL_REMAP","CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS",
                    "DISABLE_PROMPT_CACHING","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]) delete d.env[k];
  if (Object.keys(d.env).length === 0) delete d.env;
  fs.writeFileSync(path, JSON.stringify(d, null, 2));
  console.log("  removed our keys from " + path + " (backup: " + path + ".bak)");
}
NODE_EOF
    ok "cleaned settings.json"
  fi

  if [ -f "$CODEX_PROFILE" ]; then
    rm -f "$CODEX_PROFILE" && ok "removed Codex profile ($CODEX_PROFILE)"
  fi
  if [ -f "$CODEX_PROFILE_CATALOG" ]; then
    rm -f "$CODEX_PROFILE_CATALOG" && ok "removed Codex profile catalog ($CODEX_PROFILE_CATALOG)"
  fi
  if { [ -f "$CODEX_CONFIG" ] && grep -qF "$CODEX_ROOT_BEGIN" "$CODEX_CONFIG" 2>/dev/null; } \
      || [ -e "$CODEX_CATALOG_BACKUP" ] || [ -e "$CODEX_CATALOG_CREATED_MARKER" ]; then
    restore_codex_desktop_config
  fi

  say ""
  warn "Left in place (remove manually if you want): copilot-api npm package and your Copilot auth token."
  say "  npm rm -g copilot-api"
  say "  rm -f $GH_TOKEN_FILE"
  ok "${B}Uninstalled.${X}"
}

# CLI dispatch (also the boundary used by offline tests).
COMMAND="${1:-}"
[ "$#" -eq 0 ] || shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --codex-model)
      [ "$#" -ge 2 ] || die "--codex-model requires a model id"
      case " ${CODEX_MODEL_CHOICES[*]} " in
        *" $2 "*) CODEX_DESKTOP_MODEL="$2" ;;
        *) case " ${CODEX_RETIRING_MODELS[*]} " in
             *" $2 "*) CODEX_DESKTOP_MODEL="$2"; warn "$2 is $CODEX_RETIRING_NOTE. It stops working then; re-run with another --codex-model before that date." ;;
             *) die "Supported selections: ${CODEX_MODEL_CHOICES[*]}" ;;
           esac ;;
      esac
      case "$COMMAND" in --with-codex|with-codex|--with-codex-desktop|with-codex-desktop) ;; *) die "--codex-model requires a Codex install mode" ;; esac
      shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
case "$COMMAND" in
  ""|install)   do_install ;;
  --with-codex|with-codex) do_with_codex ;;
  --with-codex-desktop|with-codex-desktop) do_with_codex_desktop ;;
  --restore-codex-desktop|restore-codex-desktop) do_restore_codex_desktop ;;
  --verify|verify|doctor) do_verify ;;
  --uninstall|uninstall)  do_uninstall ;;
  --help|-h|help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "Unknown argument: $COMMAND  (try --help)" ;;
esac
