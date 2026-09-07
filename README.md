# Claude on Copilot — one-line installer

Run **Claude Code** (and Claude Desktop's built-in Claude Code) on **GitHub
Copilot's** models, fully in the background. Type `claude`, it just works — no
visible window, no manual start, survives reboot. Model-id quirks that normally
cause `400` errors are fixed automatically.

## Install

Paste this into a macOS Terminal and press Return:

```sh
curl -fsSL https://raw.githubusercontent.com/H1an1/copilot-claude-kit/main/install.sh | bash
```

It will walk you through everything. The **one** manual step is a quick GitHub
authorization in your browser (it shows you a code and a link). When it finishes:

```sh
claude        # in a NEW terminal window
```

That's it.

> **Don't want to pipe to bash?** Download `install.sh`, read it, then run
> `bash install.sh`. It's a single self-contained script.

## What it does

```
Claude Code ──►  normalizer @ :4142  ──►  copilot-api @ :4141  ──►  GitHub Copilot
 (the shell)     (fixes model ids,         (Anthropic-compatible        (the brain)
                  hides bad variants)       Copilot proxy)
                        ▲
            watchdog (every 90s: real 1-token completion through the chain;
                      triages offline vs wedged vs dead auth)
```

The installer:

1. Installs [`copilot-api`](https://github.com/ericc-ch/copilot-api) — a proxy
   that exposes Copilot as an Anthropic-compatible endpoint.
2. Writes a tiny **model-id normalizer** in front of it. Claude sends ids like
   `claude-opus-4-8` / `claude-opus-4-8[1m]`; Copilot only accepts `claude-opus-4.8`.
   The shim rewrites them on the fly, keeps the conversation ending in a user
   message, and hides `-1m` / `-high` variants from the model picker — so you
   never hit `400 model_not_supported`.
3. Runs both as always-on background services (launchd: start on login,
   auto-restart).
4. Adds a **watchdog** that every 90s sends a real 1-token completion through
   the whole chain — not a `GET /v1/models`, which copilot-api serves from a
   cache that never expires and so answers `200` long after the token has died.
   If that completion fails it first asks whether the machine is even online:
   offline means wait (it heals itself on reconnect), online means restart the
   wedged daemon, and only a still-broken chain on a working network gets you a
   "re-auth" notification. So a sleep/wake or VPN drop can't leave you
   re-running the installer to get `claude` working again.
5. Patches copilot-api's **token-refresh crash loop**. Upstream re-throws inside
   an async `setInterval`; on Node 24 that unhandled rejection kills the
   process. Lose the network at the wrong moment (~every 25 min) and the daemon
   dies, launchd restarts it into the same dead network, and it dies again —
   indistinguishable from an expired token. Now it backs off and retries.
6. Points Claude Code at the proxy via `~/.claude/settings.json` — which applies
   to **every** way Claude launches (terminal, IDE, Claude Desktop's Cowork mode,
   subagents), not just a shell alias.
7. Verifies the whole chain end-to-end before declaring success.

## Codex (optional — GPT-6 Astra and GPT-5.x via Copilot)

Codex uses the Responses API. Model access depends on your Copilot account. There are two
explicit setup modes because Codex Desktop and Codex CLI share
`~/.codex/config.toml`.

### Codex Desktop (one command)

Send this command to each person who wants to use their own GitHub Copilot
subscription in Codex Desktop:

```sh
curl -fsSL https://raw.githubusercontent.com/H1an1/copilot-claude-kit/main/install.sh \
  | bash -s -- --with-codex-desktop
```

It installs the proxy, asks that person to authorize **their own** GitHub
account, verifies `gpt-6-astra`, safely merges the user-level Codex configuration,
and writes a model catalog. It also probes `gpt-5.6-sol` and `gpt-5.5` and adds
those that complete a real Responses request to the Desktop model picker.
When Codex is installed, it tests a local shell call and a real approval request. It uses a Codex Responses health check and leaves
`~/.claude/settings.json` untouched. Fully quit and reopen Codex Desktop
afterward.

The original command now defaults to **GPT-6 Astra**. To choose Sol instead:

```sh
curl -fsSL https://raw.githubusercontent.com/H1an1/copilot-claude-kit/main/install.sh \
  | bash -s -- --with-codex-desktop --codex-model gpt-5.6-sol
```

`--codex-model` accepts `gpt-6-astra`, `gpt-5.6-sol`, or `gpt-5.5` in either
Codex install mode. If the selected model fails, installation stops before
changing Codex configuration; it never silently substitutes another model.
After restart, use the Desktop model picker to select another verified model.
Re-run the installer to refresh the catalog when account access changes.
The catalog retains a conservative 272k context budget for the proxy; it does
not assume Copilot exposes OpenAI's full direct-API context window.

The merge is deliberately reversible. Existing model/provider values and an
existing `copilot` provider and approval/sandbox defaults are preserved in-place,
unrelated Codex settings are left alone, and timestamped backups are written. Undo only the Desktop change:

```sh
curl -fsSL https://raw.githubusercontent.com/H1an1/copilot-claude-kit/main/install.sh \
  | bash -s -- --restore-codex-desktop
```

> This is a **global user-level switch**: Codex Desktop, Codex CLI, and IDE
> integrations using the same `~/.codex` directory will all select Copilot until
> restored. Each user must complete GitHub device authorization themselves.
> Never share GitHub or Copilot tokens.

### Codex CLI profile (does not change the global selection)

If you only want an opt-in CLI profile:

```sh
bash install.sh --with-codex     # writes a Codex profile + sets up the proxy
codex --profile copilot          # run Codex on Copilot
```

This adds a `/responses` passthrough to the local proxy (copilot-api doesn't
proxy Responses itself) and writes a self-contained Codex profile at
`~/.codex/copilot.config.toml` (`model = "gpt-6-astra"`, pointed at the proxy). Your
base `~/.codex/config.toml` is left untouched — it's a `--profile` overlay.

> ### ⚠️ Extra caution for Codex on a corporate/enterprise Copilot seat
> The Codex path talks to Copilot's **Responses** endpoint while presenting the
> `vscode-chat` integration identity. On an **enterprise** seat this widens the
> unsanctioned-usage surface beyond the Claude path. Treat it as a real
> compliance risk, not just a possible ban. Only enable it if that's acceptable
> for your context.

## Limitations

- **Context window is 200k, not 1M.** Copilot's `vscode-chat` integration (what
  the proxy uses) doesn't expose any 1M-context Claude variant — its model list
  has no `-1m` ids, and the `anthropic-beta: context-1m` header isn't honored.
  Picking "1M context" in a model picker gains nothing (the `[1m]` suffix is
  normalized away to the standard 200k model). 200k is the honest ceiling here.
- **Effort/model in Claude Desktop is controlled by the app, not the proxy.** If
  Claude Desktop is in **Auto** model mode it picks model + effort for you and
  hides the effort control; switch the model selector from *Auto* to a specific
  model to reveal the effort tiers.
- **Codex models are seat-dependent.** The selected model must pass a real
  Responses request. A model shown in OpenAI's catalog or Copilot's cached
  `/models` response is not proof your account can call it.
- **Automatic approval review is not supported by this Copilot adapter.** Use
  the manual approval mode below. Changing the chat model does not change the
  separate approval workload.


## Codex approval compatibility and self-test

Newer Codex versions can send a separate `model=codex-auto-review` request
when **Approve for me** reviews a tool action. The old proxy forwarded that id
unchanged; the reported Copilot rejection explains why ordinary chat works but
approval fails. This does not establish that GPT-6 itself caused the failure.

The installer uses the [official manual approval configuration](https://learn.chatgpt.com/docs/config-file/config-reference):

```toml
approval_policy = "on-request"
approvals_reviewer = "user"
sandbox_mode = "workspace-write"
```

Fully quit and reopen Desktop, start a new task, and select **Ask for approval**
in the permissions menu. Existing tasks, named permission profiles, managed
requirements, or `apps.<id>.approvals_reviewer` overrides can take precedence.
The doctor reports incompatible app overrides; set those reviewers to `user`
where appropriate. Organization-managed requirements must be handled by your
administrator. See [Codex sandboxing](https://learn.chatgpt.com/docs/sandboxing)
and [automatic review](https://learn.chatgpt.com/docs/sandboxing/auto-review).

The proxy returns `copilot_auto_review_unsupported` with these instructions if
an old task still requests `codex-auto-review`. It does not alias that dedicated
model to Astra/Sol, synthesize approval decisions, or disable the sandbox.

The checks distinguish three different things:

1. A completed Responses request with actual text (failed/incomplete/empty
   responses cannot pass just because they contain an `output` field).
2. The existing ordinary local-shell smoke test during installation.
3. During installation and `--verify`, a temporary app-server task requesting shell escalation. The test
   requires an actual `item/commandExecution/requestApproval` callback and
   declines it. A plain `printf` or a final text marker cannot pass this check.

The third check validates approval routing, not approval model availability or
Desktop button rendering. It uses the installed Codex binary, has a 60-second
limit, and reports **NOT verified** if the callback is missing, the binary is
absent, or the effective reviewer is incompatible. A failed installed-binary
approval test makes installation/doctor return nonzero; configuration remains
available for diagnosis. A missing binary during installation is an explicit
skip. The watchdog checks the last installed chat model, not approvals.

For a final Desktop check, select **Ask for approval** and ask it to request
approval for a read-only GET to your running local service (for example
`http://127.0.0.1:7147/`). Confirm the dialog appears, inspect the proposed
command, then approve it. A service HTTP error is separate from an approval
failure. This UI check must be done in the affected task; a CLI probe cannot
certify a task's saved permissions.

## Manage it

```sh
bash install.sh --verify      # health check (doctor)
bash install.sh --uninstall   # remove everything it created (clean revert)
bash install.sh               # re-run anytime to repair; it's idempotent
bash install.sh --restore-codex-desktop # undo only the Desktop switch
```

`--uninstall` removes the services, the normalizer and watchdog scripts, and the
keys it added to `settings.json` (backing the file up first). It leaves the
`copilot-api` npm package and your Copilot token in place; it prints the two
commands to remove those if you want a full wipe.

## Requirements

- macOS (Apple Silicon or Intel)
- A GitHub account **with a Copilot subscription**
- [Node.js](https://nodejs.org) installed (`node -v` works). If you use Homebrew:
  `brew install node`.
- Claude Code installed (`claude`)

## ⚠️ Before you use this

`copilot-api` is a **reverse-engineered** proxy. Using your Copilot entitlement
outside GitHub's official clients **violates Copilot's Terms of Service**, and on
a **corporate / enterprise seat** that's a compliance risk, not just a possible
ban. Heavy automated traffic is what tends to trip abuse detection. You're
accepting that risk knowingly — proceed only if that's fine for your context.

## Troubleshooting

**First: you probably don't need to do anything.** The watchdog runs every 90s
and self-heals a wedged daemon; a VPN drop or sleep/wake resolves on its own
once the network is back. Give it ~2 minutes before intervening. Re-running the
installer is *not* the fix for a transient outage — it never was, it just took
long enough that the watchdog healed things in the meantime.

If it's still broken, run the doctor — it pinpoints what's wrong:

```sh
bash install.sh --verify
```

Escalate in this order:

1. **Wait ~2 min.** Watchdog territory. Check what it decided:
   `tail /tmp/com.copilot-api-watchdog.log`. If it says *"waiting for the
   network"*, that's the whole answer — reconnect and it recovers.
2. **Force a restart now** if you don't want to wait:
   `launchctl kickstart -k gui/$(id -u)/com.copilot-api` (and
   `com.copilot-api-normalize`).
3. **Re-auth**, but only if you got the "copilot-api needs re-auth"
   notification, or the log says the token likely expired: `copilot-api auth`.
   A restart can't fix a dead token, and nothing else can fake this symptom now
   that offline is triaged separately.
4. **Re-run the installer** only after a macOS upgrade, or if the launchd
   plists are gone. It's idempotent and safe — just rarely the actual answer.

Specific symptoms:

- **It says "not authorized to Copilot"** → re-run `bash install.sh` and complete
  the browser step.
- **`400` errors in `claude`** → almost always the normalizer isn't on the path.
  `bash install.sh --verify` will catch it; re-running the installer repairs it.
  Logs: `/tmp/com.copilot-api.err` and `/tmp/com.copilot-api-normalize.err`.
- **Can't change model or effort in Claude Code / Claude Desktop (picker is locked)**
  → an env var is pinning the model. This installer does **not** pin `ANTHROPIC_MODEL`
  for exactly this reason; re-run `bash install.sh` to remove a stale pin, then
  restart the app (Claude Desktop: `Cmd+Q` and reopen). The model picker and effort
  control become yours again — the normalizer keeps whatever you pick valid.
- **"Node.js not found"** → install Node (`brew install node`) and re-run.
- **Token expired (401 later on)** → `copilot-api auth`. Only a genuinely expired
  token needs this; see the ladder above before assuming that's what it is.

For the full mechanism, design rationale, and a manual step-by-step (no script),
see [`SETUP-DETAILS.md`](./SETUP-DETAILS.md).

## Development checks

Requires Node.js and Python 3.11+ (Python is only used for repository tests).

```sh
bash -n install.sh
python3 -m unittest discover -s tests -v
node --test tests/normalizer.test.cjs
CCK_CODEX_INTEGRATION=1 python3 -m unittest discover -s tests -v
```

The optional integration test runs the installed Codex against a local Responses
fixture with an isolated home. It verifies the real approval RPC without using
Copilot credentials. Live account access and the Desktop UI still need testing.

## License

MIT
