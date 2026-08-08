# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| latest tagged release (0.1.x) | ✅ |
| `main` (`--HEAD` installs) | ✅ |
| anything older | ❌ — upgrade first |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately via GitHub's vulnerability reporting:
**[github.com/NineFiveB/YBar/security/advisories/new](https://github.com/NineFiveB/YBar/security/advisories/new)**

Include what you can: affected version (`ybar --version` or commit), a
reproduction, and your assessment of impact. You'll get an acknowledgment
within a few days — this is a solo-maintained project, so triage is
best-effort, but confirmed vulnerabilities take priority over all other
work. Fixes ship as a new tagged release with credit to the reporter in the
advisory (unless you prefer otherwise). There is no bug bounty.

## Scope — what counts as a vulnerability here

YBar runs entirely as the logged-in user with no elevated privileges, no
network services, and no private API usage. The interesting surfaces are:

- **The IPC socket** (`/tmp/ybar_$USER.socket`): anything that lets a
  *different* local user drive the daemon or execute code through it.
- **Config-adjacent execution**: the daemon runs user-authored Lua and
  shell handlers by design — that is not a vulnerability. Escalation
  *beyond* what the config author wrote (e.g. injection through externally
  controlled data such as window titles, SSIDs, or media metadata reaching
  a shell unescaped) **is** in scope.
- **Rendering of untrusted strings**: crashes or memory unsafety triggered
  by hostile text (titles, network names) reaching the glyph/render path.
- **The Homebrew formula / release pipeline**: anything that could make
  `brew install ybar` deliver something other than the tagged source.

Out of scope: issues requiring the attacker to already control the user's
config file or session (they can already run arbitrary code as that user),
and denial-of-service against your own bar.
