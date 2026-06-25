# Run Claude Code on GitHub Copilot (macOS, background daemon)

Point a fresh Claude Code install at GitHub Copilot's models, with the proxy running as an
always-on background service. End state: **open a terminal, type `claude`, it just works** —
no visible window, no manual start, survives reboot.

```
Claude Code ──►  model-id normalizer @ :4142  ──►  copilot-api @ :4141  ──►  GitHub Copilot
  (the shell)     (launchd shim: fixes model         (launchd daemon:          (the brain)
                   ids + trailing-msg quirks)         Anthropic-compatible)
```

The glue is [`ericc-ch/copilot-api`](https://github.com/ericc-ch/copilot-api) — a reverse-engineered
proxy that exposes Copilot as an **Anthropic-compatible** endpoint, so Claude Code can talk to it
directly. It also has a `--claude-code` helper that generates the right environment variables.

In front of it sits a **tiny model-id normalizer** (≈40 lines of Node, included below in Step 6). It
exists because Claude Code and Copilot disagree on model-id spelling: Claude Code sends Anthropic-style
ids like `claude-opus-4-8` / `claude-opus-4-8[1m]`, while Copilot only accepts the exact dot-form ids it
advertises (`claude-opus-4.8`). The mismatch is the **single most common `400 model_not_supported`**, and
no Claude Code flag fully prevents it — so we fix it on the wire. The same shim also repairs a second
Copilot incompatibility (a trailing `system`/assistant message — "*must end with a user message*"). With
it in place, **whatever model you pick in `/model` just works.**

---

## ⚠️ Read before you start

This is a **reverse-engineered** proxy. The repo says so itself:

> Not supported by GitHub, and may break unexpectedly. Excessive automated or scripted use of
> Copilot may trigger GitHub's abuse-detection systems — account suspension risk.

- It violates GitHub Copilot's terms (using the entitlement outside GitHub's own clients).
- On a **company/enterprise Copilot seat**, misuse detection is a compliance issue, not just a ban.
- Heavy, bursty automated traffic is what tends to trip detection — worth keeping in mind, especially on a corporate seat.

You're accepting that risk knowingly. Proceed only if that's fine for your context.

---

## 🤖 Agent execution notes

*If an autonomous agent is running this doc instead of a human, read this section first.*

You can execute almost all of this yourself. There is **one hard stop you cannot pass: Step 2
(GitHub device-flow auth).** That step requires a human to authorize in a browser — you have no
GitHub session and cannot click "Authorize" for them. Plan around it.

**Autonomy map:**

| Step | Mode | Notes |
|---|---|---|
| 1 Install + path discovery | autonomous | Run it. Capture real output of `which copilot-api` and `which node`. |
| 2 `copilot-api auth` | **HUMAN REQUIRED — block here** | See protocol below. |
| 3 Get model id | autonomous (route around the TUI) | Do **not** drive the interactive `--claude-code` picker. Use `/v1/models` instead. |
| 4 Write copilot-api plist | autonomous | Substitute the **real** absolute paths from Step 1 — never leave the example `/opt/homebrew/...` unchecked. |
| 5 Load copilot-api daemon | autonomous | Verify `:4141/v1/models` before proceeding. |
| 6 Install model-id normalizer | autonomous | Copy the script **verbatim** to `~/.copilot-api/model-normalizer.js`, write its plist with the real `node` path, load it. Verify `:4142/v1/models` proxies through. |
| 7 Redirect via `settings.json` | autonomous | Merge the `env` block into `~/.claude/settings.json` (back it up; **merge, don't overwrite**). Set `ANTHROPIC_BASE_URL` to `:4142`. The shell wrapper is optional. |
| 8 Verify | autonomous | Smoke test through `:4142`; flag tool-call fidelity for the human to eyeball. |

**Step 2 protocol (the hard stop):**
1. First check if the user already authenticated — start the daemon (Steps 4–5) and try
   `curl -s http://localhost:4141/v1/models`. If it returns a model list, auth already exists → **skip
   Step 2 entirely.** If it returns 401 / an auth error, continue below.
2. Run `copilot-api auth`. Capture the **device code and the verification URL** it prints.
3. **Surface them to the user and stop.** Say explicitly: "Open `<URL>`, enter code `<CODE>`, authorize,
   then tell me when done." Do not proceed on your own.
4. After the user confirms, verify success with `curl -s http://localhost:4141/v1/models` returning a
   model list before continuing.

**Step 3 protocol (route around the interactive picker):**
- Ensure a `copilot-api start` server is listening, then `curl -s http://localhost:4141/v1/models`.
- Parse the JSON, pick a model id (prefer a Claude model if the entitlement exposes one), and use that
  exact id for `ANTHROPIC_MODEL` / `ANTHROPIC_SMALL_FAST_MODEL` in `settings.json` (Step 7).
- **Never fabricate or guess a model id.** If `/v1/models` is unreachable, stop and report — don't invent one.
  (The Step 6 normalizer will remap a stale id anyway, but the defaults you write should still be real.)

**Per-step success criteria (gate each before moving on):**
- S1: `which copilot-api` prints a path (non-empty).
- S2: `curl -s :4141/v1/models` returns a model list (not 401).
- S4: the plist file exists and contains the **actual** `copilot-api` / `node` paths — no placeholder text.
- S5: `curl -s http://localhost:4141/v1/models` returns JSON, not "connection refused".
- S6: `curl -s http://localhost:4142/v1/models` returns the **same** model list (normalizer is up and forwarding to `:4141`).
- S7: `~/.claude/settings.json` has `env.ANTHROPIC_BASE_URL` = `http://localhost:4142` (not `:4141`) **and** the four compat flags; existing keys in the file were preserved (a `.bak` exists).
- S8: invoking `claude` produces traffic in `/tmp/copilot-api.log`, and `/tmp/copilot-api-normalize.err` shows `[normalize]` lines (proof the shim is on the path).

**Hard rules for the agent:**
- Never proceed past Step 2 without explicit human confirmation of authorization.
- Never invent a model id, a token, or an absolute path — read them from real command output.
- Back up any file before editing it (`~/.claude/settings.json`, `~/.zshrc`, an existing plist), and
  **merge** into `settings.json` — never overwrite it (it may hold the user's hooks/plugins/permissions).
- If any success criterion fails, stop and report — do not push forward on a broken step.

---

## Prerequisites

- macOS
- A GitHub account **with a Copilot subscription** (individual / business / enterprise) — hard requirement
- Node.js installed (`node -v` works)
- Claude Code installed (the "empty shell")

---

## Step 1 — Install the proxy globally

```sh
npm i -g copilot-api@latest
```

Installing globally (instead of `npx` each time) gives launchd a stable binary path to call.
**Pin to `@latest`** — older proxy builds are a common source of `400`s once Claude Code updates.
Note where it landed — you'll need the absolute path in Step 4:

```sh
which copilot-api    # e.g. /opt/homebrew/bin/copilot-api
which node           # e.g. /opt/homebrew/bin/node
```

## Step 2 — Authenticate to Copilot (device flow, one time)

```sh
copilot-api auth
```

This runs the GitHub device-code flow: it prints a code, you authorize in the browser. The token is
stored locally and reused by the daemon. (CI alternative: pass `--github-token <token>`.)

## Step 3 — Find your model id

Run the helper once to see which models your Copilot entitlement exposes and grab a model id:

```sh
copilot-api start --claude-code
```

Pick a model in the interactive prompt; it copies a command to your clipboard containing
`ANTHROPIC_MODEL=...`. Copy that model id — you'll put it in `settings.json` in Step 7. (Thanks to the
Step 6 normalizer this id doesn't have to be perfect, but use a real one from your entitlement.)

Or, once any `copilot-api start` server is up, list models directly:

```sh
curl http://localhost:4141/v1/models
```

Then `Ctrl-C` to stop this foreground run — the real one will be the launchd daemon below.

## Step 4 — Create the launchd daemon

Create `~/Library/LaunchAgents/com.copilot-api.plist`. **Replace the two absolute paths** with what
`which copilot-api` / `which node` printed in Step 1.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.copilot-api</string>

  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/copilot-api</string>
    <string>start</string>
  </array>

  <!-- launchd has a minimal PATH and can't find `node` for the proxy's shebang.
       Include node's directory here. Adjust for your install:
       - Homebrew (Apple silicon): /opt/homebrew/bin
       - Homebrew (Intel) / system: /usr/local/bin
       - nvm: add ~/.nvm/versions/node/<version>/bin -->
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>/tmp/copilot-api.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/copilot-api.err</string>
</dict>
</plist>
```

`RunAtLoad` = start on login. `KeepAlive` = restart automatically if it dies.

## Step 5 — Load the daemon

```sh
launchctl load ~/Library/LaunchAgents/com.copilot-api.plist
```

Confirm it's up:

```sh
curl http://localhost:4141/v1/models      # should return JSON, not "connection refused"
```

(On recent macOS the modern equivalents are `launchctl bootstrap gui/$(id -u) <plist>` to start and
`launchctl bootout gui/$(id -u)/com.copilot-api` to stop. `load`/`unload` still work.)

## Step 6 — Install the model-id normalizer (the "never 400 again" shim)

This is the piece that makes the setup **survive `/model` changes and Claude Code updates.** It's a tiny
reverse proxy that sits in front of copilot-api, rewrites the request's `model` id to one Copilot actually
serves, and repairs trailing-message quirks. Why it's needed rather than optional:

- Claude Code sends model ids in Anthropic spelling (`claude-opus-4-8`, dash) or with a context suffix
  (`claude-opus-4-8[1m]`). Copilot only accepts its exact dot-form ids (`claude-opus-4.8`). Result:
  `400 model_not_supported` — **even when your wrapper sets a valid id**, because Claude Code re-spells it
  on the wire. `CLAUDE_CODE_DISABLE_LEGACY_MODEL_REMAP=1` does **not** reliably stop this.
- Picking *"Opus 4.8 (1M context)"* (or any variant) in `/model` makes it worse — Copilot has no 1M
  variant at all.
- Separately, Claude Code may end a request with a `system`/assistant message (e.g. SessionStart hook
  output), which Copilot rejects with *"must end with a user message."*

The shim fixes all three. **6a.** Save this **verbatim** as `~/.copilot-api/model-normalizer.js`:

```sh
mkdir -p ~/.copilot-api
```

```js
#!/usr/bin/env node
/*
 * copilot-api model-id normalizer
 * -------------------------------
 * Claude Code (the `claude` TUI) emits Anthropic-catalog model ids such as
 *   claude-opus-4-8[1m], claude-opus-4-7, claude-sonnet-4-5, claude-3-5-haiku-...
 * GitHub Copilot (via the copilot-api proxy on :4141) only accepts the exact
 * dot-form ids it advertises, e.g. claude-opus-4.8 / claude-haiku-4.5.
 * The mismatch yields: 400 {"code":"model_not_supported"}.
 *
 * This tiny reverse proxy sits in FRONT of copilot-api. It rewrites the
 * `model` field of every chat request to a live, Copilot-supported id, then
 * transparently forwards (streaming included) to copilot-api. Anything it
 * cannot confidently map falls back to the best available Opus.
 */
const http = require("http");

const UPSTREAM_HOST = "127.0.0.1";
const UPSTREAM_PORT = 4141;          // copilot-api
const LISTEN_PORT = 4142;            // what `claude` points at

let supported = new Set();           // live set of ids copilot-api accepts
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
            const ids = JSON.parse(b).data.map((m) => m.id);
            supported = new Set(ids);
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

function defaultOpus() {
  return pick(["claude-opus-4.8", "claude-opus-4.7", "claude-opus-4.6", "claude-opus-4.5"]);
}
function defaultSonnet() {
  return pick(["claude-sonnet-4.6", "claude-sonnet-4.5"]);
}
function defaultHaiku() {
  return pick(["claude-haiku-4.5", "claude-haiku-4"]);
}

function normalize(model) {
  if (typeof model !== "string" || !model) return model;
  let m = model.trim();

  // 1. Strip context-window suffix like "[1m]".
  const base = m.replace(/\[[^\]]*\]\s*$/, "");

  // 2. Already a supported id (covers claude dot-ids, gpt-*, gemini-* exact).
  if (supported.has(base)) return base;

  // 3. Convert "claude-<family>-<major>-<minor>" -> "claude-<family>-<major>.<minor>".
  const dotted = base.replace(/^claude-(opus|sonnet|haiku)-(\d+)-(\d+)/, "claude-$1-$2.$3");
  if (supported.has(dotted)) return dotted;

  // 4. Family fallback by keyword (handles legacy claude-3-5-* and unsupported variants).
  const low = base.toLowerCase();
  if (low.includes("haiku")) return defaultHaiku() || defaultOpus() || base;
  if (low.includes("sonnet")) return defaultSonnet() || defaultOpus() || base;
  if (low.includes("opus")) return defaultOpus() || base;

  // 5. Non-claude ids we don't recognize: pass through untouched
  //    (Copilot supports many gpt-*/gemini-* exactly; if not, it errors clearly).
  if (!low.startsWith("claude")) return base;

  // 6. Unknown claude id -> best Opus.
  return defaultOpus() || base;
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", async () => {
    let body = Buffer.concat(chunks);

    // Refresh the supported-model set at most every 30s.
    if (Date.now() - lastFetch > 30000) await refreshModels();

    // Rewrite model id on JSON POST bodies that carry one.
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
        // Claude Code can violate this two ways against Copilot's Claude
        // endpoint: (a) a trailing assistant "prefill" turn, or (b) a trailing
        // `system`-role message (e.g. SessionStart hook output) — which isn't
        // even valid inside an Anthropic `messages` array. Fix both so the
        // request always succeeds.
        if (Array.isArray(j.messages) && j.messages.length > 1) {
          while (
            j.messages.length > 1 &&
            j.messages[j.messages.length - 1].role === "assistant"
          ) {
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
      } catch {
        // not JSON; forward untouched
      }
    }

    const headers = { ...req.headers };
    headers["content-length"] = Buffer.byteLength(body);
    delete headers["host"];

    const up = http.request(
      { host: UPSTREAM_HOST, port: UPSTREAM_PORT, path: req.url, method: req.method, headers },
      (ur) => {
        res.writeHead(ur.statusCode, ur.headers);
        ur.pipe(res);
      }
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
```

It has **no dependencies** (pure Node stdlib) and auto-discovers the live model list from copilot-api, so
it keeps working as Copilot's catalog changes. If your Copilot entitlement exposes different families,
adjust the `defaultOpus/Sonnet/Haiku` preference lists.

**6b.** Create `~/Library/LaunchAgents/com.copilot-api-normalize.plist` so it runs as a background daemon
too (start on login, auto-restart). **Replace the `node` path** with what `which node` printed in Step 1,
**and `YOUR_USERNAME`** with your actual home folder (`echo $HOME`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.copilot-api-normalize</string>

  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/node</string>
    <string>/Users/YOUR_USERNAME/.copilot-api/model-normalizer.js</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>/tmp/copilot-api-normalize.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/copilot-api-normalize.err</string>
</dict>
</plist>
```

**6c.** Load it and verify it forwards to copilot-api:

```sh
launchctl load ~/Library/LaunchAgents/com.copilot-api-normalize.plist
curl http://localhost:4142/v1/models      # should return the SAME list as :4141
```

If `:4142` returns the model list, the chain `claude → :4142 → :4141 → Copilot` is wired. The wrapper in
the next step points Claude Code at `:4142`, so all traffic flows through the shim.

## Step 7 — Point Claude Code at the proxy (`settings.json` — the reliable way)

Claude Code needs four things to talk to the proxy instead of Anthropic: the **base URL** (the normalizer
at `:4142`), a placeholder **auth token**, and the **compatibility flags**. The most reliable place to set
them is the `env` block of your **user settings** at `~/.claude/settings.json`. Claude Code reads this file
**itself**, so the config applies **no matter how `claude` launches** — terminal, a bare `claude` with no
shell function, an IDE/editor extension, subagents/teams, cron. A shell wrapper (the old approach) only
covers `claude` typed interactively in a shell that sourced it — which is exactly why setups that rely on
the wrapper alone "work in my terminal but 400 everywhere else." **Configure `settings.json` and you won't
hit that.**

**Merge** this into the `env` object of `~/.claude/settings.json` — **don't overwrite** the file if it
already has `env` / `hooks` / `permissions`. The safe way (backs up first, preserves everything else):

```sh
python3 - <<'PY'
import json, os, shutil
p = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
d = {}
if os.path.exists(p):
    shutil.copy(p, p + ".bak")          # backup at ~/.claude/settings.json.bak
    d = json.load(open(p))
d.setdefault("env", {}).update({
    "ANTHROPIC_BASE_URL": "http://localhost:4142",
    "ANTHROPIC_AUTH_TOKEN": "dummy",
    "ANTHROPIC_MODEL": "claude-opus-4.8",
    "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4.5",
    "CLAUDE_CODE_DISABLE_LEGACY_MODEL_REMAP": "1",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",
    "DISABLE_PROMPT_CACHING": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
})
json.dump(d, open(p, "w"), indent=2)
print("updated", p, "— backup at", p + ".bak")
PY
```

The resulting `env` block looks like this (yours will also keep whatever keys were already there):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:4142",
    "ANTHROPIC_AUTH_TOKEN": "dummy",
    "ANTHROPIC_MODEL": "claude-opus-4.8",
    "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4.5",
    "CLAUDE_CODE_DISABLE_LEGACY_MODEL_REMAP": "1",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",
    "DISABLE_PROMPT_CACHING": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
```

What each piece does:
- `ANTHROPIC_BASE_URL` → the **normalizer** (`:4142`), not copilot-api (`:4141`) — all traffic flows through
  the shim that fixes model ids.
- `ANTHROPIC_MODEL` / `ANTHROPIC_SMALL_FAST_MODEL` are sane defaults (big + the small model Claude Code uses
  for background tasks). You **don't** have to keep these in lock-step with Copilot's catalog: the Step 6
  normalizer remaps whatever id Claude Code actually sends — including `/model` picks and `[1m]` variants —
  to a live, supported id.
- `ANTHROPIC_AUTH_TOKEN=dummy` is a non-empty placeholder; the proxy authenticates to Copilot with the
  GitHub token from Step 2, not this value. (A real global `ANTHROPIC_API_KEY` for other tools is harmless —
  Claude Code routes to the proxy via these settings.)
- **The four flags are compatibility shims for a non-Anthropic backend** — leave them on:
  - `CLAUDE_CODE_DISABLE_LEGACY_MODEL_REMAP=1` — asks Claude Code to send the model id verbatim. Keep it on,
    but **don't rely on it** — newer Claude Code still re-spells `claude-opus-4.8` (dot) → `claude-opus-4-8`
    (dash) on the wire, which Copilot rejects. The **Step 6 normalizer is what actually guarantees** a valid
    id; this flag just reduces how often it has to act.
  - `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` — stops experimental beta fields the proxy can't parse.
  - `DISABLE_PROMPT_CACHING=1` — drops `cache_control` blocks (prompt caching is GA, not covered by the beta
    flag; Copilot can't cache anyway).
  - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` — drops background/telemetry calls that can 400 on their own.

These are **user-scope** settings (all projects). A project's `.claude/settings.json` `env` would override
them for that repo. **Restart any running `claude`** so it re-reads the env at session start.

### Optional — a shell wrapper

You do **not** need this once `settings.json` is set. Add it only if you want per-invocation behavior such
as **auto-resolving the newest live model** each launch (see "Keeping it from breaking again" for that
version), or you can't edit `settings.json`. Append to `~/.zshrc` (or `~/.bashrc`):

```zsh
claude() {
  ANTHROPIC_BASE_URL=http://localhost:4142 \
  ANTHROPIC_AUTH_TOKEN=dummy \
  ANTHROPIC_MODEL="claude-opus-4.8" \
  ANTHROPIC_SMALL_FAST_MODEL="claude-haiku-4.5" \
  CLAUDE_CODE_DISABLE_LEGACY_MODEL_REMAP=1 \
  CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
  DISABLE_PROMPT_CACHING=1 \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  command claude "$@"
}
```

`command claude` calls the real binary (no recursion); env is set per invocation. If you set **both**
`settings.json` and a wrapper, keep both pointing at `:4142` so they can't disagree. Reload with
`source ~/.zshrc`.

## Step 8 — Verify (don't skip)

```sh
claude
```

Then give it a **real multi-file task** (not just a one-line chat) and watch both logs:

```sh
tail -f /tmp/copilot-api.log            # copilot-api requests (200s, not 400s)
tail -f /tmp/copilot-api-normalize.err  # normalizer activity: [normalize] ... lines
```

You should see requests flowing. Claude Code is tool-heavy — file reads, edits, bash all go through
the proxy as tool calls. If a multi-file edit completes and lands correctly, the translation layer is
working. A chat reply alone doesn't prove it; tool calls are where these proxies get flaky.

> **Sanity check that the shim is on the path:** run `claude`, then look in `/tmp/copilot-api-normalize.err`
> for `[normalize] ... -> ...` lines. Seeing them confirms Claude Code's model id was being re-spelled and
> the normalizer caught it — i.e. without it you'd be getting `400`s.

---

## Operating it

| Want to… | Do this |
|---|---|
| Check the chain end-to-end | `curl http://localhost:4142/v1/models` (goes through the shim to copilot-api) |
| Check copilot-api directly | `curl http://localhost:4141/v1/models` |
| View logs | copilot-api: `tail -f /tmp/copilot-api.log` / `cat /tmp/copilot-api.err` · normalizer: `tail -f /tmp/copilot-api-normalize.err` |
| Restart copilot-api | `launchctl kickstart -k gui/$(id -u)/com.copilot-api` |
| Restart the normalizer | `launchctl kickstart -k gui/$(id -u)/com.copilot-api-normalize` (do this after editing the script) |
| Stop everything | `launchctl unload ~/Library/LaunchAgents/com.copilot-api.plist ~/Library/LaunchAgents/com.copilot-api-normalize.plist` |
| Re-auth (token expired) | `copilot-api auth`, then restart copilot-api |
| Update the proxy | `npm i -g copilot-api@latest`, then restart copilot-api |

---

## Keeping it from breaking again

This chain has **three independently-moving parts**: Claude Code (auto-updates itself), copilot-api (the
proxy), and Copilot's model catalog (ids get renamed/retired). Two pieces of this setup already absorb the
churn: the **Step 6 normalizer** handles model-id drift (spelling, retired ids, `[1m]` variants,
trailing-message quirks), and the **Step 7 `settings.json` redirect** applies in every launch context so
there's no "wrapper didn't load" gap. Once both are in place you're largely covered. The rest is hardening:

**1. (Optional) Resolve the model id at launch with a shell wrapper.**
The normalizer already prevents id-drift `400`s, so this is purely a convenience — it lets the shell pick
the best live model each launch (e.g. auto-adopt a newer model the day it appears). It's the optional
wrapper from Step 7, upgraded to query the catalog. `base` points at the normalizer (`:4142`); if you also
keep `ANTHROPIC_MODEL` in `settings.json`, this inline value wins for interactive `claude`:

```zsh
claude() {
  local base="http://localhost:4142"
  local big_pref=(claude-opus-4.8 claude-opus-4.7 claude-sonnet-4.5 gpt-4.1 gpt-4o)
  local small_pref=(claude-haiku-4.5 gpt-4o-mini gpt-4.1 gpt-4o)
  local models big="" small=""
  models="$(curl -s --max-time 3 "$base/v1/models" 2>/dev/null)"
  for m in $big_pref;   do print -r -- "$models" | grep -q "\"$m\"" && { big=$m;   break; }; done
  for m in $small_pref; do print -r -- "$models" | grep -q "\"$m\"" && { small=$m; break; }; done
  [[ -z "$big" ]] && { echo "claude: :4142 unreachable or no known model — is the daemon up?" >&2; return 1; }
  [[ -z "$small" ]] && small="$big"
  ANTHROPIC_BASE_URL="$base" \
  ANTHROPIC_AUTH_TOKEN=dummy \
  ANTHROPIC_MODEL="$big" \
  ANTHROPIC_SMALL_FAST_MODEL="$small" \
  CLAUDE_CODE_DISABLE_LEGACY_MODEL_REMAP=1 \
  CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
  DISABLE_PROMPT_CACHING=1 \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  command claude "$@"
}
```

Edit `big_pref` / `small_pref` to taste — order = priority, first one that's live wins. (Even if you pick
a model the normalizer would map differently, the shim still ensures the on-the-wire id is valid.)

**2. Decide your Claude Code update posture** — it auto-updates silently, and that's what changed the
model-id behaviour under everyone last time. Two valid choices:
- **Pin it (most stable):** disable auto-update so *you* control when the world changes. Set
  `"autoUpdates": false` in `~/.claude/settings.json` (most reliable for the native installer; the env
  vars `DISABLE_AUTOUPDATER=1` / `DISABLE_UPDATES=1` also work). Then update deliberately and re-test.
- **Let it update + rely on the flags:** keep the four compat flags on (they absorb most request-shape
  changes) and accept that a big Claude Code change can still occasionally need a new flag.

**3. Keep copilot-api current:** `npm i -g copilot-api@latest` every week or two, then
`launchctl kickstart -k gui/$(id -u)/com.copilot-api`. New proxy builds often add compatibility for
new Claude Code behaviour.

**Optional early-warning:** a tiny daily smoke test beats discovering breakage mid-task. Drop this in a
`launchd`/cron job and have it log/notify on failure. It deliberately sends a **dash-form** id through the
**normalizer** (`:4142`) so it validates the *whole* chain — id normalization included:

```sh
curl -s -m 20 http://localhost:4142/v1/messages \
  -H 'content-type: application/json' -H 'x-api-key: dummy' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-opus-4-8","max_tokens":5,"messages":[{"role":"user","content":"ping"}]}' \
  | grep -q '"type":"message"' && echo "OK" || echo "BROKEN — check /tmp/copilot-api.err and /tmp/copilot-api-normalize.err"
```

---

## Troubleshooting

- **`claude` returns `API 400` (worked before, suddenly broke) — READ THE REAL ERROR FIRST.** Don't
  guess; the rejected field decides the fix: `tail -50 /tmp/copilot-api.err`, then match. (With the Step 6
  normalizer in place, the first two below should be *self-healing* — if you still see them, the shim is
  being bypassed; jump to the "normalizer isn't on the path" item.)
  - `model_not_supported` **and your id is NOT in `/v1/models`** → stale/renamed id. The normalizer maps
    unknown ids to the best live model automatically; if it leaks through, list with
    `curl -s http://localhost:4141/v1/models` and adjust the `defaultOpus/Sonnet/Haiku` lists in the shim.
  - `model_not_supported` **but your id IS in `/v1/models`** → Claude Code re-spelled it (dot→dash) on the
    wire. **This is exactly what the normalizer fixes.** If you still hit it: confirm `ANTHROPIC_BASE_URL`
    is `:4142` (not `:4141`) **in the layer that's actually taking effect** — your `~/.claude/settings.json`
    `env` (and any shell wrapper) — and that `:4142` is up (`curl -s :4142/v1/models`). A `[normalize]` line
    in `/tmp/copilot-api-normalize.err` proves it's working. *(A raw `curl` of the dash id to `:4141` failing
    while `:4142` succeeds confirms the shim's job.)*
  - `cache_control` / `context_management` / `effort` / `input_examples` → a beta/cache field; confirm
    `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` **and** `DISABLE_PROMPT_CACHING=1` are both set.
  - `assistant message prefill` / `must end with a user message` → Copilot won't accept a request ending in
    an assistant/system message (Claude Code appends these, e.g. SessionStart hook output). **The Step 6
    normalizer repairs this** by dropping a trailing assistant turn and retagging a trailing `system`
    message to `user`. If you still see it, you're bypassing the shim (make sure `settings.json` points at
    `:4142`).
  - empty tool `description` → Copilot bug on `claude-sonnet-4.6` / `claude-opus-4.6`; switch model id.
  - Always also: update the proxy (`npm i -g copilot-api@latest` + restart). If a *session* is wedged
    mid-turn, press `ESC` twice → `/rewind` → `/compact`.
- **`400` / requests hit Anthropic instead of the proxy, even though your shell wrapper looks right →
  `claude` was launched outside that shell function.** The wrapper only applies to `claude` typed in a shell
  that sourced it; an IDE/editor extension, a non-login shell, `bash` (if you only edited `~/.zshrc`), a
  cron job, or subagents/teams all bypass it. **Fix: set the redirect in `~/.claude/settings.json` `env`**
  (Step 7) — Claude Code reads that itself, so it applies everywhere. This is the most common "it works in
  my terminal but not in X" cause.
- **`400`s came back and config looks right → the normalizer isn't on the path.** Check it's running:
  `curl -s http://localhost:4142/v1/models` (should match `:4141`) and `launchctl list | grep copilot`
  (both `com.copilot-api` and `com.copilot-api-normalize` should be listed). If `:4142` is dead, check
  `/tmp/copilot-api-normalize.err`, fix the `node` path in `com.copilot-api-normalize.plist`, then
  `launchctl kickstart -k gui/$(id -u)/com.copilot-api-normalize`. Also confirm `settings.json`’s
  `ANTHROPIC_BASE_URL` is `:4142` — pointing it at `:4141` skips the shim and will 400 on re-spelled ids.
- **Daemon won't start / `/tmp/copilot-api.err` says `node: command not found`** — launchd's PATH
  doesn't include node. Fix the `EnvironmentVariables` → `PATH` in the plist (nvm users: add your
  `~/.nvm/versions/node/<version>/bin`), then `unload` + `load`.
- **`claude` returns 401 / auth error** — Copilot token expired. `copilot-api auth` again, then
  `launchctl kickstart -k gui/$(id -u)/com.copilot-api`. This is the one recurring chore; everything
  else is set-and-forget.
- **Port `4141` already in use** — add `--port 8080` to the copilot-api plist's `ProgramArguments`, **and**
  set `UPSTREAM_PORT = 8080` in `model-normalizer.js`, then restart both. (`settings.json` points at the
  normalizer, so `ANTHROPIC_BASE_URL` doesn't change.) If port **`4142`** clashes instead, change
  `LISTEN_PORT` in the script **and** `ANTHROPIC_BASE_URL` (and any wrapper `base`) to match.
- **"model not found"** — wrong model id. List valid ones with `curl http://localhost:4141/v1/models`.
- **Tool calls flaky / edits don't apply** — translation fidelity issue. Try a different model, and
  make sure you're on the latest proxy (`npm i -g copilot-api@latest`).

---

## The honest summary

You get the real Claude Code harness with a Copilot-served brain, fully backgrounded. The two things
that aren't "forever-free": the **token needs occasional re-auth**, and it's a **reverse-engineered
proxy under GitHub's ToS** — think twice on a corporate seat.
