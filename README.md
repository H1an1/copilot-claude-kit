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
4. Points Claude Code at the proxy via `~/.claude/settings.json` — which applies
   to **every** way Claude launches (terminal, IDE, Claude Desktop's Cowork mode,
   subagents), not just a shell alias.
5. Verifies the whole chain end-to-end before declaring success.

## Codex (optional — gpt-5.x via Copilot)

You can also run **OpenAI Codex CLI** on Copilot's models. Codex uses the
Responses API, which Copilot serves for `gpt-5.x` (including `gpt-5.5`). The
installer can wire it up:

```sh
bash install.sh --with-codex     # writes a Codex profile + sets up the proxy
codex --profile copilot          # run Codex on Copilot
```

This adds a `/responses` passthrough to the local proxy (copilot-api doesn't
proxy Responses itself) and writes a self-contained Codex profile at
`~/.codex/copilot.config.toml` (`model = "gpt-5.5"`, pointed at the proxy). Your
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
- **Codex flagship `gpt-5.3-codex` may be gated.** Copilot's `vscode-chat`
  integration serves `gpt-5.5`/`gpt-5.4` over Responses; some codex-tuned ids are
  restricted to other integrations and may return `model_not_supported`. Edit
  `model` in `~/.codex/copilot.config.toml` to one that works for your seat.

## Manage it

```sh
bash install.sh --verify      # health check (doctor)
bash install.sh --uninstall   # remove everything it created (clean revert)
bash install.sh               # re-run anytime to repair; it's idempotent
```

`--uninstall` removes the services, the normalizer, and the keys it added to
`settings.json` (backing the file up first). It leaves the `copilot-api` npm
package and your Copilot token in place; it prints the two commands to remove
those if you want a full wipe.

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

Run the doctor first — it pinpoints what's wrong:

```sh
bash install.sh --verify
```

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
- **Token expired (401 later on)** → re-run `bash install.sh` to re-authorize.

For the full mechanism, design rationale, and a manual step-by-step (no script),
see [`SETUP-DETAILS.md`](./SETUP-DETAILS.md).

## License

MIT
