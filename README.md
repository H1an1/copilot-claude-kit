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
- **"Node.js not found"** → install Node (`brew install node`) and re-run.
- **Token expired (401 later on)** → re-run `bash install.sh` to re-authorize.

For the full mechanism, design rationale, and a manual step-by-step (no script),
see [`SETUP-DETAILS.md`](./SETUP-DETAILS.md).

## License

MIT
