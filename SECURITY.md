# Security Policy

Anchor stores credentials that can deploy code into other people's cloud
accounts: GitHub OAuth tokens, Google OAuth tokens, GCP service-account keys,
and application secrets. We take reports about any of these seriously.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security problems.**

Report privately via GitHub: **Security → Report a vulnerability** on this
repository (private vulnerability reporting). This creates a draft advisory
that only the maintainers can see.

Please include:

- what an attacker can do (the impact) and what they need first (the preconditions);
- steps to reproduce, a proof of concept, or a failing test;
- the affected version / commit and any configuration it depends on;
- whether you believe the issue is already being exploited.

If the issue involves a live credential, don't use it beyond what's needed to
show it works, and tell us so we can revoke it.

## What to expect

| Step | Target |
|---|---|
| Acknowledgement | within 3 business days |
| Initial assessment and severity | within 7 days |
| Fix for critical / high issues | within 30 days, sooner if exploited |
| Public advisory | when a fix is available, coordinated with you |

We credit reporters in the advisory unless you ask us not to. We won't take
legal action against good-faith research that follows this policy.

## Scope

In scope:

- this repository: the Rails app, background jobs, API, CLI and MCP server;
- the way Anchor stores, uses and passes on GitHub / Google / GCP credentials
  and project secrets;
- the deployment pipeline Anchor runs on a user's behalf, including files it
  generates or commits to user repositories.

Out of scope:

- applications that users deploy *with* Anchor (report those to their owners);
- vulnerabilities in GitHub, Google Cloud or other third parties (report
  upstream; tell us if Anchor makes them worse);
- denial of service by volume, social engineering, and physical attacks;
- findings from automated scanners with no demonstrated impact;
- missing hardening headers on non-HTML responses, unless you can show impact.

Safe harbour: don't access data that isn't yours, don't degrade the service for
others, and give us reasonable time to fix before disclosing.

## Supported versions

Anchor ships from `main`. Security fixes land on `main`; self-hosters should
track it. There are no long-term support branches.

## For operators (self-hosting)

- Generate a strong `ENCRYPTION_KEY` and, preferably, dedicated
  `ACTIVE_RECORD_ENCRYPTION_*` keys (`bin/rails db:encryption:init`). Losing
  them makes stored credentials unrecoverable; leaking them exposes them all.
- Set `APP_HOSTS` so Host-header attacks can't poison OAuth or webhook URLs.
- Leave `ANCHOR_ALLOW_GLOBAL_WEBHOOK_SECRET` unset. Each project has its own
  webhook secret; the global one is only for migrating old hooks.
- Run `bin/brakeman` and `bundle exec bundle-audit check --update` in CI and
  keep dependencies patched.
- Read [docs/threat-model.md](docs/threat-model.md) for the trust boundaries
  and the known gaps.
