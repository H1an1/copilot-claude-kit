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
 * It has no dependencies and auto-discovers the live model list.
 */
const http = require("http");

const UPSTREAM_HOST = "127.0.0.1";
const UPSTREAM_PORT = 4141;          // copilot-api
const LISTEN_PORT = 4142;            // what clients point at

let supported = new Set();           // live ids copilot-api accepts
let lastFetch = 0;

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

function normalize(model) {
  if (typeof model !== "string" || !model) return model;
  const base = model.trim().replace(/\[[^\]]*\]\s*$/, "");      // strip "[1m]"
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
                j.data = j.data.filter((m) => !(typeof m.id === "string" && /^claude-/.test(m.id) && VARIANT_RE.test(m.id)));
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
  ANTHROPIC_MODEL: "claude-opus-4.8",
  ANTHROPIC_SMALL_FAST_MODEL: "claude-haiku-4.5",
  CLAUDE_CODE_DISABLE_LEGACY_MODEL_REMAP: "1",
  CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1",
  DISABLE_PROMPT_CACHING: "1",
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
});
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
    "$COPILOT_API_BIN" auth || warn "auth command exited non-zero; if you completed it in the browser, that's usually fine"
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

  say ""
  warn "Left in place (remove manually if you want): copilot-api npm package and your Copilot auth token."
  say "  npm rm -g copilot-api"
  say "  rm -f $GH_TOKEN_FILE"
  ok "${B}Uninstalled.${X}"
}

case "${1:-}" in
  ""|install)   do_install ;;
  --verify|verify|doctor) do_verify ;;
  --uninstall|uninstall)  do_uninstall ;;
  --help|-h|help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "Unknown argument: $1  (try --help)" ;;
esac
