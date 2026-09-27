# Preflight checks

`Analysis::Preflight` ([source](../app/services/analysis/preflight.rb)) is a set of static checks
that runs against a fresh checkout of your repository. The goal is to catch failures that are certain
or very likely **before** a build runs, because on Cloud Run a build costs money and minutes.

## When it runs

- **At every deploy**, inside `PrepareJob`, after framework detection and before the Dockerfile is
  generated or the build starts. Each `error` or `warning` finding becomes a log line such as
  `Preflight error [bind_localhost] ... (server.js:12)`.
- **During repository analysis**, when a project is created or re-analyzed. The findings are stored
  in `analysis_result["preflight"]` and appear in the project's analysis panel, in
  `GET /api/v1/projects/:id/analysis`, in `anchor doctor`, and in the MCP `get_analysis` tool.

## Severities

| Severity | Effect |
|---|---|
| `error` | **Blocks the deploy.** The deployment fails with `Preflight found N blocking issue(s)`, and each issue is listed with its fix. The build never starts. |
| `warning` | Logged. The deploy continues. It is very likely a problem. |
| `info` | Advice only. It isn't written to the deploy log, but it appears in the analysis. |

Each finding has the shape `{id, severity, message, file, line, fix}`. Findings are sorted by
severity, then id, file, and line. Each rule reports at most 10 findings. If a rule crashes, it is
skipped and logged, and the other rules still run.

## Rules

There are 34 rules. The ids are stable, so you can match on them in CI or in an agent.

### Can the container start and be reached?

| Id | Severity | What it catches | Typical fix |
|---|---|---|---|
| `no_app_detected` | error | No Dockerfile, Gemfile, package.json, Python manifest, go.mod, mix.exs, or index.html | Add a Dockerfile, or set the project's root directory |
| `bind_localhost` | error | Server binds to `127.0.0.1` or `localhost`. Checked in JS/TS, Python, Go, Puma config, and the Phoenix endpoint. | Listen on `0.0.0.0` |
| `port_mismatch` | error | A hard-coded listen port that differs from the container port, so the health check will fail | Read `$PORT` |
| `port_not_from_env` | warning | The server never reads `$PORT` | Read `$PORT` |
| `missing_start_script` | error | A Node app with no `start` script and no entry file | Add `"start": "node server.js"` |
| `go_no_main_package` | error | No `package main` with `func main()` | Add a main package or a Dockerfile |
| `dockerfile_expose_mismatch` | warning | `EXPOSE` doesn't match the project port | Make EXPOSE, the listen port, and the project port agree |
| `dockerfile_no_expose` | info | The Dockerfile has no `EXPOSE`, so the default port is assumed | Add `EXPOSE <port>` |
| `dockerfile_runs_as_root` | info | The final stage has no `USER` | Add a non-root user |

### Will the build succeed?

| Id | Severity | What it catches | Typical fix |
|---|---|---|---|
| `malformed_manifest` | error | A package.json, Gemfile, lockfile, go.mod, or other manifest that can't be parsed, including merge-conflict markers | Fix the syntax or regenerate the lockfile |
| `nextjs_missing_build_script` | error | A Next.js app without a `build` script | Add `"build": "next build"` |
| `go_sum_missing` | error | go.mod has requirements but go.sum is missing | `go mod tidy` and commit go.sum |
| `runtime_version_unsupported` | error | The runtime is older than the base images support (Node < 16, Ruby < 2.7, Python < 3.8, Go < 1.18) | Upgrade, or commit your own Dockerfile |
| `runtime_version_eol` | warning | The runtime is end-of-life (Node < 22, Ruby < 3.3, Python < 3.10, Go < 1.25) | Upgrade |
| `runtime_version_unrecognized` | info | A version file (e.g. `.nvmrc`) holds something that isn't a version number | Put a plain version number in it |
| `lockfile_missing` | warning | No JS lockfile, no `Gemfile.lock`, or a `Pipfile` without `Pipfile.lock` | Commit the lockfile |
| `multiple_lockfiles` | warning | More than one JS lockfile is committed | Delete the lockfiles of package managers you don't use |
| `workspace_lockfile` | warning | A monorepo app relies on a lockfile at the workspace root, outside its build context | Commit a Dockerfile that builds from the root, or give the app its own lockfile |
| `python_server_missing` | info | FastAPI without `uvicorn`, or Flask/Django without `gunicorn`, in the dependencies (and no Procfile) | Pin the server in your dependencies |
| `nextjs_not_standalone` | info | `next.config` doesn't set `output: "standalone"`, so the image is larger | Add `output: "standalone"` |

### Will it boot in production?

| Id | Severity | What it catches | Typical fix |
|---|---|---|---|
| `rails_no_production_database` | error | `config/database.yml` has no `production` section | Add a production entry that uses `DATABASE_URL` |
| `rails_sqlite_production` | warning | Production uses SQLite on an ephemeral container disk | Use a managed database through `DATABASE_URL` |
| `rails_secret_key_base_missing` | warning | Neither `SECRET_KEY_BASE` nor `RAILS_MASTER_KEY` is a project secret | Set one as a project secret |
| `django_allowed_hosts` | error | A hard-coded `ALLOWED_HOSTS` that rejects the deployed hostname with HTTP 400 | Read `ALLOWED_HOSTS` from the environment |
| `django_debug_enabled` | warning | `DEBUG = True` is hard-coded | `DEBUG = os.environ.get("DEBUG") == "1"` |
| `env_var_not_set` | warning | Code or the detected database needs an environment variable that isn't a project secret | Add it as a secret |

### Hygiene and security

| Id | Severity | What it catches | Typical fix |
|---|---|---|---|
| `rails_master_key_committed` | error | `config/master.key` or a credentials key is committed | `git rm --cached`, rotate the credentials, and set `RAILS_MASTER_KEY` as a secret |
| `committed_secrets` | error | A committed `.env` file contains secret values | Remove it, rotate the values, and use project secrets |
| `committed_env_file` | warning | A `.env` file is committed, even if it looks empty of secrets | Remove it and add it to `.gitignore` |
| `committed_dependencies` | warning | `node_modules/` or vendored dependencies are committed | Remove them and add them to `.gitignore` |
| `large_file` | warning | A single file is larger than 50 MB | Use object storage or LFS, or add it to `.dockerignore` |
| `large_repository` | warning | The checkout is larger than 1 GB | Exclude data and artifacts with `.dockerignore` |

### Monorepos

| Id | Severity | What it catches | Typical fix |
|---|---|---|---|
| `monorepo_ambiguous` | warning | Several apps were found and the chosen one may be wrong | Set the project's root directory |
| `monorepo_candidates` | info | Lists the other apps found in the repository | Create one project per app |

Test, spec, example, fixture, and docs paths are ignored when scanning source files (see
`NON_PROD_PATH`). A server bound to `localhost` in a test file doesn't block a deploy.

## Adding a rule

1. Add the id to `RULES` with its default severity and a one-line summary. The UI, API, and this page
   all use that catalogue.
2. Add a private method whose name starts with `check_`. `#call` finds and runs every `check_*`
   method automatically. Call `add(id, message, file:, line:, fix:)`. Use `app_files` (the app
   directory) or `repo_files` (the whole repo), `framework`, `metadata`, and `expected_port`.
3. Add a fixture repo under `spec/fixtures/repos/` and examples in `spec/services/analysis/preflight_spec.rb`. Cover a positive
   case, a negative case, and the test-file exclusion.
4. Add a row to this page.
