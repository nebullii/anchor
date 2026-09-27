# The `anchor` CLI

`anchor` is a single static Go binary that talks to Anchor's [JSON API](api.md). It can deploy, follow
logs, roll back, manage secrets, and check a repo before you deploy it. Its exit codes are designed
for CI.

The source is in [`cli/`](../cli). [`cli/README.md`](../cli/README.md) covers the same ground more
briefly. This page adds example output for each command. The examples were captured against a local
Anchor with the seeded `hello-anchor` project.

## Install (build from source)

You need Go 1.22 or newer. Release binaries are not published yet.

```bash
cd cli
go build -o anchor .              # produces ./anchor
sudo mv anchor /usr/local/bin/    # optional
anchor --version
# anchor 0.1.0-dev (darwin/arm64)
```

Cross-compile a release build with a version stamped in:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags "-s -w -X github.com/nebullii/anchor/cli/internal/cli.Version=0.2.0" \
  -o dist/anchor-linux-amd64 .
```

## Authenticate

1. In the Anchor web app, go to **Settings → API tokens → Create**. The token starts with `anc_` and
   is shown only once. Anchor stores only its SHA-256 digest.
2. Log in:

```console
$ anchor login --url http://localhost:3000
Create a token at http://localhost:3000/settings, then paste it below.
Logged in to http://localhost:3000 as @demo (token "docs"). Saved to /Users/you/.config/anchor/config.json
```

The CLI verifies the token against `GET /api/v1/me` before it saves anything. The config file is
written with mode `0600`. You can also pipe the token in (`echo "$T" | anchor login --url ...`) or pass
it with `--token`.

Environment variables override the config file. This is the usual setup in CI:

| Variable | Purpose |
|---|---|
| `ANCHOR_URL` | Server URL (default `http://localhost:3000`) |
| `ANCHOR_TOKEN` | API token |
| `ANCHOR_CONFIG` | Config file path (default `$XDG_CONFIG_HOME/anchor/config.json`) |
| `NO_COLOR` | Turn off colored output |

`anchor logout` deletes the saved token. You can revoke tokens under Settings.

## How the CLI picks a project

For commands that take a project, the CLI resolves it in this order:

1. A positional argument or `-p/--project`: a slug, a numeric id, a name, or `owner/repo`.
2. `.anchor.json` in the current directory or any parent directory. `anchor link <project>` writes it.
3. The current directory's git remotes (`origin` first), matched against each project's repository.

## Commands

Flags can go anywhere on the command line. `anchor <command> --help` prints each command's flags.
Every read command also accepts `--json`, which prints the API response unchanged.

### `whoami`

```console
$ anchor whoami
@demo on http://localhost:3000 (token "docs")
Deploys today: 2/20, this month: 2/200
```

### `projects`

```console
$ anchor projects
SLUG          STATUS  FRAMEWORK  REPOSITORY                   LAST DEPLOY        URL
hello-anchor  active  docker     crccheck/docker-hello-world  #3 running 5m ago  http://localhost:50618
```

### `link`

```console
$ anchor link hello-anchor
Linked /Users/you/src/app to project hello-anchor.
```

### `status [project] [--limit N]`

```console
$ anchor status hello-anchor
hello-anchor (hello-anchor)
  status:     active
  url:        http://localhost:51444
  repository: crccheck/docker-hello-world @ master
  framework:  docker

ID  STATUS       BRANCH  COMMIT   TRIGGER   CREATED   DURATION
#6  running      master  bbed28c  rollback  just now  0s
#5  rolled_back  master  bbed28c  cli       just now  8s
#4  running      master  bbed28c  cli       just now  3s
```

The `url` line is what is actually serving traffic. Older deployments that were replaced by a newer
normal deploy keep the status `running` (see the known gaps in the [README](../README.md#status-and-known-gaps)).

### `deploy [project] [-b BRANCH] [-f]`

Without `--follow`, the command queues the deployment and returns:

```console
$ anchor deploy hello-anchor
Deployment #5 queued for hello-anchor (branch master).
Follow it with `anchor logs 5 -f`.
```

With `--follow`, it streams the logs until the deployment reaches a final status:

```console
$ anchor deploy hello-anchor --follow
Deploying hello-anchor (branch master) — deployment #4. Ctrl-C to stop following.
==> queued
11:18:10 Deployment queued — starting pipeline (provider: local_docker).
11:18:10 Analyzing repository…
==> building
...
11:18:13 Health check 1/8 passed (HTTP 200).
11:18:13 Shifting 100% of traffic to anchor-cl-hello-anchor-4...
11:18:13 Deployment complete.
11:18:13 Live at: http://localhost:51444

✔ Deployment #4 is live: http://localhost:51444
```

When the deployment fails, the CLI prints the error message and, if one exists, the AI explanation:

```text
✘ Deployment #9 failed
  error: Preflight found 1 blocking issue(s): ...
```

Errors from the API come with a hint:

```console
$ anchor deploy hello-anchor
error: A deployment is already in progress.
hint: watch it with `anchor status`, or stop it with `anchor cancel`
```

If required secrets are missing, the hint lists the `anchor secrets set KEY=...` commands to run.

**Exit codes** (the same for `deploy -f`, `logs -f`, and `rollback -f`):

| Code | Meaning |
|---|---|
| 0 | The deployment is live (`running`) |
| 1 | It failed, was cancelled, or was rolled back, or the command itself errored |
| 2 | Usage error |
| 130 | Interrupted with Ctrl-C |

If you press Ctrl-C in an interactive terminal, the CLI asks whether to cancel the deployment on the
server too. In a script, it prints the `anchor cancel <id>` command instead. To use a deploy as a CI
gate, run `anchor deploy -f || exit 1`.

### `logs <deployment-id> [-f]`

```console
$ anchor logs 6
11:18:33 Rollback requested by demo: shifting traffic to revision anchor-cl-hello-anchor-4.
11:18:33 Shifting 100% of traffic to revision anchor-cl-hello-anchor-4...
11:18:33 Stopping previous container anchor-cl-hello-anchor-5…
11:18:34 anchor-cl-hello-anchor-4 is now live.
11:18:34 Rollback complete. Revision anchor-cl-hello-anchor-4 is serving 100% of traffic.
11:18:34 Live at: http://localhost:51444
```

`-f` attaches to a deployment that is still running and polls with `after_id` every 2 seconds.

### `cancel [deployment-id] [-p project]`

With no id, the command cancels the project's in-progress deployment:

```console
$ anchor cancel -p hello-anchor
Deployment #7 cancelled.
```

Cancelling also stops the build: `gcloud builds cancel` on Cloud Run, or the `docker build` process
on Local Docker. The revision that is currently live keeps serving.

### `rollback [project] [--to DEPLOYMENT_ID] [-f]`

```console
$ anchor rollback hello-anchor --to 4 --follow
==> queued
11:18:33 Rollback requested by demo: shifting traffic to revision anchor-cl-hello-anchor-4.
11:18:33 Shifting 100% of traffic to revision anchor-cl-hello-anchor-4...
==> running
11:18:33 Stopping previous container anchor-cl-hello-anchor-5…
11:18:34 anchor-cl-hello-anchor-4 is now live.
11:18:34 Rollback complete. Revision anchor-cl-hello-anchor-4 is serving 100% of traffic.
11:18:34 Live at: http://localhost:51444

✔ Deployment #6 is live: http://localhost:51444
```

Without `--to`, the target is the newest earlier deployment that passed its health check and has a
different revision from the one that is live now. Without `-f`, the command prints
`Rollback started for hello-anchor: deployment #6. Follow it with ...`.

### `secrets list | set | unset`

```console
$ anchor secrets set GREETING=hello -p hello-anchor
Added GREETING on hello-anchor.
Secrets apply on the next deploy (`anchor deploy hello-anchor`).

$ anchor secrets list -p hello-anchor
KEY       UPDATED
GREETING  just now

$ anchor secrets unset GREETING -p hello-anchor
Removed GREETING from hello-anchor.
```

To keep a value out of your shell history, run `anchor secrets set KEY -p app` and the CLI reads the
value from stdin or a hidden prompt. For example: `op read op://vault/stripe/key | anchor secrets set STRIPE_KEY`.
The CLI never prints secret values, and the API never returns them.

### `doctor [project]`

`doctor` checks the server, the token, and project resolution. It then shows the analysis, any
required secrets that aren't set, and the [preflight findings](preflight.md):

```console
$ anchor doctor hello-anchor
• server http://localhost:3000 (from /Users/you/.config/anchor/config.json)
✔ authenticated as @demo (token "docs" from /Users/you/.config/anchor/config.json)
✔ project hello-anchor (crccheck/docker-hello-world)
✔ analysis complete (docker)
✔ no preflight findings
```

When there are findings, each one is printed with its location and a fix:

```text
Preflight findings:
  ✘ error Server binds to 127.0.0.1 ... (server.js:12)
      fix: Listen on "0.0.0.0" (or omit the host argument).
```

`doctor` exits 1 when anything would block a deploy.

### `--json`

```bash
anchor status --json | jq '.deployments[0].status'
```

`deploy -f --json` and `logs -f --json` print newline-delimited JSON: one object per log line, then a
final `{"deployment": ...}`.

## Development

```bash
cd cli
go vet ./...
go test -race ./...
```

The tests run every command against an in-process fake of the API (`internal/cli/fake_server_test.go`).
They need no network and no Rails server.
