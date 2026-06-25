#!/usr/bin/env bash
#
# Claude-on-Copilot installer
# ---------------------------
# Lets a fresh Claude Code (and Claude Desktop's built-in Claude Code) run on
# GitHub Copilot's models, fully in the background, with model-id quirks fixed
# automatically so it "just works".
#
# Usage:
#   bash install.sh              # install / repair (idempotent)
#   bash install.sh --with-codex # also set up OpenAI Codex on Copilot (gpt-5.x)
#   bash install.sh --verify     # health-check an existing install (doctor)
#   bash install.sh --uninstall  # remove everything this script created
#   bash install.sh --help
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/H1an1/copilot-claude-kit/main/install.sh | bash
#
# What it sets up:
#   copilot-api  @ :4141   reverse-engineered Anthropic-compatible Copilot proxy
#   normalizer   @ :4142   ~50-line shim: rewrites model ids Copilot rejects,
#                          fixes trailing-message quirks, hides variant ids
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
SETTINGS="$HOME/.claude/settings.json"
API_PORT=4141
NORM_PORT=4142
GH_TOKEN_FILE="$HOME/.local/share/copilot-api/github_token"

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

function refreshModels() {
  return new Promise((resolve) => {
    const req = http.request(
      { host: UPSTREAM_HOST, port: UPSTREAM_PORT, path: "/v1/models", method: "GET" },
      (r) => {
        let b = "";
        r.on("data", (c) => (b += c));
        r.on("end", () => {
          try {
            supported = new Set(JSON.parse(b).data.map((m) => m.id));
            lastFetch = Date.now();
          } catch {}
          resolve();
        });
      }
    );
    req.on("error", () => resolve());
    req.end();
  });
}

function pick(prefs) {
  for (const p of prefs) if (supported.has(p)) return p;
  return null;
}
const defaultOpus = () => pick(["claude-opus-4.8", "claude-opus-4.7", "claude-opus-4.6", "claude-opus-4.5"]);
const defaultSonnet = () => pick(["claude-sonnet-4.6", "claude-sonnet-4.5"]);
const defaultHaiku = () => pick(["claude-haiku-4.5", "claude-haiku-4"]);

// id suffixes Copilot exposes as request-time params, not standalone models.
const VARIANT_RE = /-(?:low|medium|high|xhigh|max|1m)(?:-internal)?$/;

// Claude Desktop only shows the effort selector for models whose id matches
// Anthropic's canonical dash+date shape (e.g. claude-opus-4-1-20250805). Copilot
// serves dot-form ids (claude-opus-4.8). So in the /v1/models listing we present
// the canonical shape (forwardId), and on the request path we convert it back to
// the dot-form Copilot accepts (handled in normalize()).
const SENTINEL_DATE = "20260301";
function forwardId(id) {
  const m = /^claude-(opus|sonnet|haiku)-(\d+)\.(\d+)$/.exec(id);
  return m ? `claude-${m[1]}-${m[2]}-${m[3]}-${SENTINEL_DATE}` : id;
}

function normalize(model) {
  if (typeof model !== "string" || !model) return model;
  let base = model.trim().replace(/\[[^\]]*\]\s*$/, "");         // strip "[1m]"
  base = base.replace(/-\d{8}$/, "");                            // strip date sentinel
  if (supported.has(base)) return base;
  const dotted = base.replace(/^claude-(opus|sonnet|haiku)-(\d+)-(\d+)/, "claude-$1-$2.$3");
  if (supported.has(dotted)) return dotted;
  const low = base.toLowerCase();
  if (low.includes("haiku")) return defaultHaiku() || defaultOpus() || base;
  if (low.includes("sonnet")) return defaultSonnet() || defaultOpus() || base;
  if (low.includes("opus")) return defaultOpus() || base;
  if (!low.startsWith("claude")) return base;                  // gpt-*/gemini-* pass through
  return defaultOpus() || base;
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", async () => {
    let body = Buffer.concat(chunks);
    if (Date.now() - lastFetch > 30000) await refreshModels();

    // --- Responses API passthrough (Codex etc.) ---------------------------
    // copilot-api has no /responses route, and Copilot serves gpt-5.x only over
    // /responses. We forward straight to Copilot's native Responses endpoint
    // using a freshly-exchanged Copilot token, streaming the result back.
    if (req.method === "POST" && /^\/(v1\/)?responses\b/.test(req.url)) {
      if (body.length) {
        try {
          const j = JSON.parse(body.toString("utf8"));
          if (typeof j.model === "string") {
            const fixed = normalize(j.model);
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
      try {
        const up = await fetch(auth.api + "/responses", {
          method: "POST",
          headers: copilotHeaders(auth.token, req.headers["accept"]),
          body,
        });
        const h = {};
        const ct = up.headers.get("content-type");
        if (ct) h["content-type"] = ct;
        res.writeHead(up.status, h);
        if (up.body) Readable.fromWeb(up.body).pipe(res);
        else res.end(await up.text());
      } catch (e) {
        res.writeHead(502, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: { message: "responses upstream error: " + e.message } }));
      }
      return;
    }

    // --- Hide variant ids from the model picker (GET /v1/models) ----------
    if (req.method === "GET" && req.url.startsWith("/v1/models")) {
      const gh = { ...req.headers };
      delete gh["host"];
      const up = http.request(
        { host: UPSTREAM_HOST, port: UPSTREAM_PORT, path: req.url, method: "GET", headers: gh },
        (ur) => {
          const ch = [];
          ur.on("data", (c) => ch.push(c));
          ur.on("end", () => {
            let out = Buffer.concat(ch);
            try {
              const j = JSON.parse(out.toString("utf8"));
              if (Array.isArray(j.data)) {
                j.data = j.data
                  .filter((m) => !(typeof m.id === "string" && /^claude-/.test(m.id) && VARIANT_RE.test(m.id)))
                  .map((m) => (typeof m.id === "string" ? { ...m, id: forwardId(m.id) } : m));
                out = Buffer.from(JSON.stringify(j), "utf8");
              }
            } catch {}
            const h = { ...ur.headers };
            delete h["content-encoding"];
            delete h["transfer-encoding"];
            h["content-length"] = Buffer.byteLength(out);
            res.writeHead(ur.statusCode, h);
            res.end(out);
          });
        }
      );
      up.on("error", (e) => { res.writeHead(502); res.end("normalizer upstream error: " + e.message); });
      up.end();
      return;
    }

    // --- Rewrite model id + sanitize messages on POST bodies --------------
    if (req.method === "POST" && body.length) {
      try {
        const j = JSON.parse(body.toString("utf8"));
        let changed = false;
        if (j && typeof j.model === "string") {
          const fixed = normalize(j.model);
          if (fixed && fixed !== j.model) {
            console.error(`[normalize] ${j.model} -> ${fixed}`);
            j.model = fixed;
            changed = true;
          }
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
      } catch { /* not JSON; forward untouched */ }
    }

    const headers = { ...req.headers };
    headers["content-length"] = Buffer.byteLength(body);
    delete headers["host"];
    const up = http.request(
      { host: UPSTREAM_HOST, port: UPSTREAM_PORT, path: req.url, method: req.method, headers },
      (ur) => { res.writeHead(ur.statusCode, ur.headers); ur.pipe(res); }
    );
    up.on("error", (e) => {
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: "normalizer upstream error: " + e.message } }));
    });
    up.end(body);
  });
});

refreshModels().finally(() => {
  server.listen(LISTEN_PORT, "127.0.0.1", () => {
    console.error(`model-normalizer listening on http://127.0.0.1:${LISTEN_PORT} -> :${UPSTREAM_PORT}`);
  });
});
NORMALIZER_EOF
  ok "normalizer written to $NORMALIZER"
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
  ANTHROPIC_SMALL_FAST_MODEL: "claude-haiku-4.5",
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

smoke_test() {  # send a dash-form id through the normalizer; expect a real message back
  local out
  out="$(curl -fsS -m 30 "http://localhost:${NORM_PORT}/v1/messages" \
    -H 'content-type: application/json' -H 'x-api-key: dummy' -H 'anthropic-version: 2023-06-01' \
    -d '{"model":"claude-opus-4-8","max_tokens":5,"messages":[{"role":"user","content":"ping"}]}' 2>/dev/null)" || return 1
  case "$out" in *'"type":"message"'*) return 0 ;; *) return 1 ;; esac
}

CODEX_PROFILE="$HOME/.codex/copilot.config.toml"
write_codex_profile() {
  mkdir -p "$HOME/.codex"
  [ -f "$CODEX_PROFILE" ] && cp "$CODEX_PROFILE" "$CODEX_PROFILE.bak"
  cat > "$CODEX_PROFILE" <<EOF
# Written by copilot-claude-kit (bash install.sh --with-codex).
# A self-contained Codex profile — use it with:   codex --profile copilot
# It routes Codex through the local proxy to GitHub Copilot's Responses API,
# which is how gpt-5.x models are served. Edit 'model' to taste.
model = "gpt-5.5"
model_provider = "copilot"

[model_providers.copilot]
name = "GitHub Copilot (local proxy)"
base_url = "http://localhost:${NORM_PORT}/v1"
wire_api = "responses"
EOF
  ok "wrote Codex profile: $CODEX_PROFILE"
}

codex_smoke_test() {  # POST /v1/responses through the normalizer; expect a completed response
  local out
  out="$(curl -fsS -m 40 "http://localhost:${NORM_PORT}/v1/responses" \
    -H 'content-type: application/json' \
    -d '{"model":"gpt-5.5","input":"reply with exactly one word: pong","stream":false}' 2>/dev/null)" || return 1
  case "$out" in *'"status":"completed"'*|*'"output"'*) return 0 ;; *) return 1 ;; esac
}

do_with_codex() {
  do_install
  step "Setting up Codex (GitHub Copilot via Responses API)"
  write_codex_profile
  if codex_smoke_test; then ok "Codex round-trip through :$NORM_PORT/v1/responses succeeded"; else warn "Codex self-test didn't complete; the proxy is up — try 'codex --profile copilot'"; fi
  printf '\n%s%s Codex ready.%s Run: %scodex --profile copilot%s\n' "$G" "$B" "$X" "$B" "$X"
  command -v codex >/dev/null 2>&1 || warn "codex CLI not found on PATH — install it, then use 'codex --profile copilot'"
}

# ===========================================================================
#  commands
# ===========================================================================
do_install() {
  need_macos
  step "Checking prerequisites"
  ensure_node
  ensure_copilot_api

  step "Writing the model-id normalizer"
  write_normalizer

  step "Creating background services (launchd)"
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

  if ! is_authed; then
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

  if ! is_authed; then
    err "Still not authorized to Copilot. Re-run 'bash install.sh' after finishing the browser step."
    err "Check logs: /tmp/com.copilot-api.err"
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

  step "Pointing Claude Code at the proxy (~/.claude/settings.json)"
  merge_settings

  step "End-to-end self-test"
  if smoke_test; then
    ok "round-trip through :$NORM_PORT succeeded"
  else
    warn "smoke test didn't return a message. The services are up; try 'claude' and check /tmp/com.copilot-api.err"
  fi

  printf '\n%s%s All set.%s Open a NEW terminal and run: %sclaude%s\n' "$G" "$B" "$X" "$B" "$X"
  say "Claude Desktop's built-in Claude Code will use this automatically too."
  say "Add Codex (gpt-5.x):   bash install.sh --with-codex"
  say "Health-check anytime:  bash install.sh --verify"
  say "Remove everything:     bash install.sh --uninstall"
}

do_verify() {
  need_macos
  local fail=0
  step "Health check"

  if service_loaded com.copilot-api; then ok "launchd: com.copilot-api loaded"; else err "launchd: com.copilot-api NOT loaded"; fail=1; fi
  if service_loaded com.copilot-api-normalize; then ok "launchd: com.copilot-api-normalize loaded"; else err "launchd: com.copilot-api-normalize NOT loaded"; fail=1; fi

  if curl -fsS -m 3 "http://localhost:$API_PORT/v1/models" >/dev/null 2>&1; then ok ":$API_PORT copilot-api responding"; else err ":$API_PORT copilot-api not responding"; fail=1; fi
  if curl -fsS -m 3 "http://localhost:$NORM_PORT/v1/models" >/dev/null 2>&1; then ok ":$NORM_PORT normalizer responding"; else err ":$NORM_PORT normalizer not responding"; fail=1; fi

  if is_authed; then ok "authorized to Copilot (models listed)"; else err "not authorized to Copilot (run: bash install.sh)"; fail=1; fi

  if [ -f "$SETTINGS" ] && grep -q "localhost:$NORM_PORT" "$SETTINGS" 2>/dev/null; then
    ok "settings.json points at :$NORM_PORT"
  else
    err "settings.json missing or not pointing at :$NORM_PORT"; fail=1
  fi

  step "End-to-end self-test"
  if smoke_test; then ok "round-trip through :$NORM_PORT succeeded"; else err "smoke test failed — check /tmp/com.copilot-api.err"; fail=1; fi

  if [ -f "$CODEX_PROFILE" ]; then
    step "Codex check"
    if codex_smoke_test; then ok "Codex /v1/responses round-trip succeeded"; else err "Codex self-test failed — check /tmp/com.copilot-api-normalize.err"; fail=1; fi
  fi

  echo
  if [ "$fail" -eq 0 ]; then ok "${B}Everything looks healthy.${X}"; else err "${B}Some checks failed (see above).${X} Re-run 'bash install.sh' to repair."; exit 1; fi
}

do_uninstall() {
  need_macos
  step "Uninstalling"
  launchctl unload "$API_PLIST" >/dev/null 2>&1 || true
  launchctl unload "$NORM_PLIST" >/dev/null 2>&1 || true
  rm -f "$API_PLIST" "$NORM_PLIST" && ok "removed launchd services"
  rm -f "$NORMALIZER" && ok "removed normalizer script"
  rmdir "$KIT_DIR" >/dev/null 2>&1 || true

  if [ -f "$SETTINGS" ]; then
    "$(find_node)" - "$SETTINGS" <<'NODE_EOF' || warn "couldn't auto-clean settings.json; edit it manually"
const fs = require("fs");
const path = process.argv[2];
let d; try { d = JSON.parse(fs.readFileSync(path, "utf8")); } catch { process.exit(0); }
if (d && d.env) {
  fs.copyFileSync(path, path + ".bak");
  for (const k of ["ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_MODEL","ANTHROPIC_SMALL_FAST_MODEL",
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

  say ""
  warn "Left in place (remove manually if you want): copilot-api npm package and your Copilot auth token."
  say "  npm rm -g copilot-api"
  say "  rm -f $GH_TOKEN_FILE"
  ok "${B}Uninstalled.${X}"
}

case "${1:-}" in
  ""|install)   do_install ;;
  --with-codex|with-codex) do_with_codex ;;
  --verify|verify|doctor) do_verify ;;
  --uninstall|uninstall)  do_uninstall ;;
  --help|-h|help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "Unknown argument: $1  (try --help)" ;;
esac
