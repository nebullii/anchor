# anchor CLI

Deploy, watch, and roll back Anchor projects from your terminal (or from CI, or a coding agent).
It's a single static Go binary with no runtime dependencies. It talks to Anchor's JSON API (`/api/v1`).

## Install

Requires Go 1.22+ to build.

```sh
cd cli
go build -o anchor .                    # ./anchor
# or, once this is on the default branch, install into $GOBIN:
go install github.com/nebullii/anchor/cli@latest
```

Cross-compile a release binary:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags "-s -w -X github.com/nebullii/anchor/cli/internal/cli.Version=0.1.0" \
  -o dist/anchor-linux-amd64 .
```

## Log in

1. In the Anchor web app, open **Settings → API tokens** and create a token. It starts with `anc_` and is shown once.
2. Run:

```sh
anchor login --url https://anchor.example.com   # paste the token when prompted (input is hidden)
```

The token is checked against `/api/v1/me`, then saved to `~/.config/anchor/config.json` with mode `0600`.
You can also pass it on stdin with `echo "$TOKEN" | anchor login --url ...`, or with `--token`.

Environment variables take precedence over the config file, which is handy in CI:

| Variable        | Purpose                                                                        |
|-----------------|--------------------------------------------------------------------------------|
| `ANCHOR_URL`    | Server URL (default `http://localhost:3000`)                                   |
| `ANCHOR_TOKEN`  | API token                                                                      |
| `ANCHOR_CONFIG` | Alternate config file path (otherwise `$XDG_CONFIG_HOME/anchor/config.json`)   |
| `NO_COLOR`      | Disable colored output                                                         |

`anchor logout` removes the saved token. Revoke tokens under Settings when you no longer need them.

## Choosing a project

Commands that act on a project resolve it in this order:

1. An explicit argument or `-p/--project`. This can be a slug, id, name, or `owner/repo`.
2. A `.anchor.json` file in the current directory or any parent. Create it with `anchor link my-app`:
   ```json
   { "project": "my-app" }
   ```
3. The current directory's git remotes (`origin` first), matched against each project's GitHub repository.

## Commands

```text
anchor login [--url URL] [--token anc_...]    Save and verify an API token
anchor logout                                 Forget the saved token
anchor whoami [--json]                        Show the account and deploy quota
anchor projects [--limit N] [--json]          List projects
anchor link <project>                         Write .anchor.json for this directory
anchor status [project] [--limit N] [--json]  Project details and recent deployments
anchor deploy [project] [-b BRANCH] [-f] [--json]
anchor logs <deployment-id> [-f] [--json]
anchor cancel [deployment-id] [-p project] [--json]
anchor rollback [project] [--to DEPLOYMENT_ID] [-f] [--json]
anchor secrets list [-p project] [--json]
anchor secrets set KEY=VALUE [KEY=VALUE...] [-p project]
anchor secrets set KEY [-p project]           Value is read from stdin (or a hidden prompt)
anchor secrets unset KEY [KEY...] [-p project]
anchor doctor [project] [--json]              Check setup, missing secrets, preflight findings
anchor --version
```

Flags can go anywhere on the command line. `anchor <command> --help` shows the details for each command.

### Deploy and follow

```sh
anchor deploy --follow            # deploy the project for this repo and stream logs
anchor deploy my-app -b feature/x
```

With `--follow`, the CLI polls the deployment and streams new log lines using `after_id`. It stops when the deployment finishes.

| Exit code | Meaning                                                  |
|-----------|----------------------------------------------------------|
| 0         | The deployment is live (`running`)                       |
| 1         | It failed, was cancelled, or was rolled back, or the command errored |
| 2         | Usage error                                              |
| 130       | Interrupted with Ctrl-C                                  |

When you press Ctrl-C in an interactive terminal, the CLI asks whether to cancel the deployment on the server as well. In a script, it prints the `anchor cancel <id>` command to run instead.
These exit codes make it usable as a CI gate, for example `anchor deploy -f || exit 1`.

`anchor logs 42 -f` attaches to a deployment that is already running and uses the same exit codes.

### Secrets

```sh
anchor secrets set NODE_ENV=production LOG_LEVEL=info
anchor secrets set DATABASE_URL < db-url.txt      # value from stdin, never in shell history
op read op://vault/stripe/key | anchor secrets set STRIPE_KEY
anchor secrets list
anchor secrets unset LOG_LEVEL
```

The CLI never displays secret values, and the API never returns them. New values take effect on the next deploy.

### Doctor

`anchor doctor` checks the server URL, the token, and project resolution. It then shows the repository analysis:
the detected framework, required env vars that have no secret yet, and preflight findings with file, line, and suggested fix.
It exits with code 1 if anything would block a deploy.

### JSON output

Every read command accepts `--json` and prints the API response unchanged, so you can pipe it into `jq`:

```sh
anchor status --json | jq '.deployments[0].status'
```

`logs -f --json` and `deploy -f --json` print newline-delimited JSON: one object per log line, then a final `{"deployment": ...}`.

## Development

```sh
cd cli
go vet ./...
go test -race ./...
```

The tests run every command against an in-process fake of the Anchor API (`internal/cli/fake_server_test.go`),
so they need neither a network connection nor a running Rails server.
