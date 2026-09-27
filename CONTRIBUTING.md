# Contributing to Anchor

Thanks for helping. This page covers local setup, running the tests, the conventions we follow, and
the two most common kinds of contribution: adding a provider and adding a preflight rule.

## Setup

```bash
git clone https://github.com/nebullii/anchor.git && cd anchor
bin/setup            # tools check, .env, gems, CSS, DB + seeds, then starts bin/dev
```

If you prefer containers, run `docker compose up`. [docs/quickstart.md](docs/quickstart.md) covers
both paths. You never need a cloud account or an AI key to develop: the Local Docker provider and the
dev login (`ANCHOR_DEV_LOGIN=1`) cover the whole flow.

## Running the tests

| Component | Command | Notes |
|---|---|---|
| Rails app | `bundle exec rspec` | Also `make test` |
| Lint | `bundle exec rubocop` | Also `make lint` |
| Security | `bundle exec brakeman --no-pager -q -w3` and `bundle-audit check --update` | Also `make security` |
| Everything CI runs for Rails | `make ci` | |
| CLI (Go 1.22+) | `cd cli && go vet ./... && go test -race ./...` | Runs against an in-process fake API |
| MCP server (Node 18.17+) | `cd mcp && npm test` | `node --test`, no dependencies to install |
| End-to-end | `script/e2e_local.sh` | Real web + worker + Docker + CLI through deploy, failed release, rollback, preflight, cancel and webhook. About 2 minutes. Needs Docker, Go and Node; uses its own database (`anchor_e2e`) |
| Migration safety | `ruby script/check_migrations.rb` | Fails on migrations that drop or rename things the running code still uses |

### Migrations must be backward compatible

Deploys migrate first and shift traffic second, so for a few minutes the old code runs against the new
schema. Never drop or rename a column the running code uses in the same deploy that stops using it.
Use two deploys ("expand/contract"): first add the new column and stop reading the old one, then remove
the old one in a later deploy and mark that migration with a `# anchor:contract` comment. CI enforces this.

The Rails suite has about 1,000 examples. It uses WebMock and a fake command runner, so it **never**
calls GitHub, GCP, OpenAI, Anthropic, `gcloud`, or `docker`. Keep it that way: stub HTTP with WebMock
and inject `FakeCommandRunner` into providers.

Some view specs need the Tailwind build. If you skipped `bin/setup`, run `bin/rails tailwindcss:build`
once.

### One test database per worktree

`config/database.yml` points the test environment at `anchor_test`. If you work in several git
worktrees, or run suites in parallel, give each one its own database so they don't clobber each other:

```bash
export DATABASE_URL=postgres://localhost/anchor_test_$(basename "$PWD") RAILS_ENV=test
bin/rails db:create db:schema:load     # once, and again after pulling new migrations
bundle exec rspec
```

Set `DATABASE_URL` in your shell or per command, **not** in `.env`. dotenv loads `.env` in the test
environment too, so a `DATABASE_URL` there would point rspec at your development database.

### Things that cost money

`bin/rails anchor:ai_eval` runs the AI error-explainer eval set against a real model and is billed to
your key. Never run it in CI. The deploy workflows in `.github/workflows/deploy-*.yml` only run on
pushes to `main` and `staging`, and CI checks that they never trigger on pull requests.

## Conventions

- **Commits:** a short, single-line message with a type prefix, for example `fix: bounded retries in
  PollBuildStatusJob` or `docs: api reference`. Use `feat:`, `fix:`, `docs:`, `chore:`, `style:`, or
  `test:`. Don't add a body unless the change really needs one.
- **Branches:** one branch per fix or feature. Open PRs against `main`.
- **Specs:** every behavior change needs one. Pipeline jobs, the state machine, providers, and the API
  all have specs to copy from under `spec/jobs`, `spec/models`, `spec/services/providers`, and
  `spec/requests/api`.
- **Style:** service objects with a comment block that explains *why*, and argv arrays for every
  subprocess (never shell strings). Pass secrets through `redact:` and never interpolate them into
  log lines.
- **API shapes** live in `app/controllers/api/v1/serialization.rb`. The CLI and the MCP server depend
  on those exact keys, so if you change one, update `cli/internal/api`, `mcp/src`, and
  [docs/api.md](docs/api.md) in the same PR.
- **Docs:** `docs/` is gitignored except for top-level `docs/*.md` and `docs/screenshots/`. Put new
  pages at `docs/<name>.md`.

## Adding a provider

Read [docs/providers.md](docs/providers.md) first. In short:

1. Subclass `Providers::Base` in `app/services/providers/<name>.rb` and implement `provision!`,
   `build!`, `build_status`, `cancel_build!`, `deploy_revision!` (with **no traffic**, and returning a
   `Providers::Revision` with a URL you can probe), `promote!`, `rollback!`, and `delete_revision!`.
2. Add it to `Providers::REGISTRY` in `app/services/providers.rb`.
3. Add it to `DeployWizardController::PROVIDER_OPTIONS`, and make the GCP-only validation and
   provisioning in `app/models/project.rb` conditional for your provider.
4. Write specs with `FakeCommandRunner` that assert on the exact argv. See
   `spec/services/providers/local_docker_spec.rb`.

## Adding a preflight rule

Read [docs/preflight.md](docs/preflight.md#adding-a-rule). In short:

1. Add the id, severity, and summary to `Analysis::Preflight::RULES`.
2. Add a private `check_<something>` method that calls `add(id, message, file:, line:, fix:)`. It is
   picked up automatically.
3. Add a fixture under `spec/fixtures/repos/` and examples in `spec/services/analysis/preflight_spec.rb`.
4. Use `error` only when the deploy is **certain** to fail, because errors block deploys. Use
   `warning` when it very likely will.

## Security issues

Please don't open public issues for vulnerabilities. See [SECURITY.md](SECURITY.md).
