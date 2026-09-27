# Quickstart

This guide runs Anchor on your machine and deploys a sample app to your local Docker daemon. You don't
need a cloud account, a GitHub OAuth app, or an AI key.

There are two ways to run it:

- [Path A: `bin/setup`](#path-a-binsetup). Ruby, Postgres, and Redis run on your machine. This is the
  fastest path once gems are installed.
- [Path B: `docker compose`](#path-b-docker-compose). Only Docker is needed on the host.

Both paths seed a demo user and a demo project called `hello-anchor`. The project deploys
[crccheck/docker-hello-world](https://github.com/crccheck/docker-hello-world), a tiny public repo with
a busybox web server, using the **Local Docker** provider. The clone needs internet access to GitHub.

## Path A: `bin/setup`

Prerequisites:

| Tool | Version | Notes |
|---|---|---|
| Ruby | 3.4.4 (see `.ruby-version`) | rbenv, mise, or asdf |
| PostgreSQL | 16+ | Must be running. `bin/setup` checks with `pg_isready`. |
| Redis | 7+ | Must be running. `bin/setup` checks with `redis-cli ping`. |
| Docker | any recent | Docker Desktop, OrbStack, or colima. Needed for deploys but not to boot the app. |
| Go | 1.22+ | Only needed to build the CLI |

```bash
git clone https://github.com/nebullii/anchor.git && cd anchor
bin/setup
```

`bin/setup` is idempotent, so you can run it again at any time. It goes through these steps:

1. Checks Ruby, Postgres, Redis, and Docker. For anything missing it prints the exact fix.
2. Copies `.env.example` to `.env` if needed and generates a development `ENCRYPTION_KEY`.
3. Runs `bundle install` if needed and builds the Tailwind CSS.
4. Runs `bin/rails db:prepare` and `bin/rails db:seed`.
5. Starts `bin/dev`, which runs the web server on :3000, the Sidekiq worker, and the CSS watcher.

With gems already installed, it takes about 6 seconds. A cold `bundle install` takes about 75
seconds. Useful flags:

```bash
bin/setup --skip-server   # everything except starting bin/dev
bin/setup --reset         # drop and recreate the development database first
```

The `Makefile` has the same commands as shortcuts: `make setup`, `make dev`, `make test`, `make reset`.

## Path B: `docker compose`

```bash
git clone https://github.com/nebullii/anchor.git && cd anchor
docker compose up          # or: make up
```

The first run builds the development image, which takes about 4 minutes. After that, the stack
starts Postgres on host port 5433 and Redis on 6380, so they don't collide with local installs.
It also starts `web` on :3000, which runs `db:prepare`, `db:seed`, and the CSS build first, and a
`worker` running Sidekiq.

The web and worker containers mount `/var/run/docker.sock`. Apps you deploy therefore run as sibling
containers on the host daemon, and the worker health-checks them through `host.docker.internal`
(`ANCHOR_LOCAL_DOCKER_HOST`).

> Tested on Docker Desktop for macOS. Local Docker binds deployed apps to `127.0.0.1` on the host, and
> on Linux `host.docker.internal` resolves to the bridge gateway instead. If health checks time out
> under compose on Linux, use Path A.

Run `docker compose down -v` to reset everything, including the database volume.

## Deploy the demo project

### From the browser

1. Open http://localhost:3000 and click **Continue as demo user**. This dev-only login is enabled by
   `ANCHOR_DEV_LOGIN=1`, and it is ignored outside the development environment.
2. Open **hello-anchor** and press **Deploy**.
3. The page streams the logs live. The deployment moves through `analyzing`, `building`,
   `deploying`, `health_check`, and `running`, and the app appears on a random `http://localhost:<port>`.

### From the CLI

1. In the web app, open **Settings → API tokens**, create a token, and copy it. It starts with `anc_`
   and is shown only once.
2. Build the CLI and log in:

   ```bash
   cd cli && go build -o anchor . && cd ..
   ./cli/anchor login --url http://localhost:3000     # paste the token (input is hidden)
   ```

3. Deploy and follow:

   ```bash
   ./cli/anchor deploy hello-anchor --follow
   ```

   ```text
   Deploying hello-anchor (branch master) — deployment #4. Ctrl-C to stop following.
   ==> queued
   11:18:10 Deployment queued — starting pipeline (provider: local_docker).
   11:18:10 Analyzing repository…
   ==> building
   11:18:10 Using local Docker 29.0.1 (no cloud account needed).
   11:18:10 Cloning crccheck/docker-hello-world @ master...
   11:18:11 Cloned at bbed28cb: feat(ci): add publish workflow (#22)
   11:18:11 Detecting framework...
   11:18:11 Using cached analysis: docker / docker on port 8000.
   11:18:11 Existing Dockerfile found — skipping generation.
   11:18:11 Building anchor-local/cl-hello-anchor:4 with local Docker…
   ...
   11:18:12 Built anchor-local/cl-hello-anchor:4.
   ==> running
   11:18:12 Build succeeded.
   11:18:12 Creating new revision of cl-hello-anchor (no traffic yet)...
   11:18:13 Revision anchor-cl-hello-anchor-4 created at http://localhost:51444.
   11:18:13 Health check 1/8 passed (HTTP 200).
   11:18:13 Shifting 100% of traffic to anchor-cl-hello-anchor-4...
   11:18:13 anchor-cl-hello-anchor-4 is now live.
   11:18:13 Deployment complete.
   11:18:13 Live at: http://localhost:51444

   ✔ Deployment #4 is live: http://localhost:51444
   ```

   The `==>` lines are status changes. The CLI polls every couple of seconds, so a fast deploy can
   jump from `building` straight to `running` between polls.

4. Try a rollback. Deploy again, then:

   ```bash
   ./cli/anchor rollback hello-anchor --follow
   ```

   ```text
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

   Nothing was rebuilt. The Local Docker provider stops the newer container and restarts the older
   one. `anchor status hello-anchor` now shows deployment #5 as `rolled_back`.

## Deploy your own repository

The demo project is seeded directly into the database. To deploy your own repos from the UI, Anchor
has to list them from GitHub, so you need a GitHub OAuth app:

1. Create one at https://github.com/settings/developers with the callback URL
   `http://localhost:3000/auth/github/callback`.
2. Put `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` in `.env`, then restart `bin/dev`.
3. Sign in with GitHub, go to **Projects → Deploy new app** (the `/wizard` flow), pick a repo, and choose **Local Docker** or
   **Google Cloud Run** as the provider.

For Cloud Run, connect a Google account or a service-account key under **Settings**. See
[SETUP_GCLOUD.md](../SETUP_GCLOUD.md). Cloud Run is the paid path.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `bin/setup` stops with `FAIL postgres ...` or `FAIL redis ...` | Run the `fix:` command it prints, or use `docker compose up`. |
| Deploy fails with `Docker daemon is not reachable` | Start Docker Desktop, OrbStack, or colima, then deploy again. |
| Deploy sits in `queued` | The Sidekiq worker isn't running. `bin/dev` starts it, or run `bundle exec sidekiq -C config/sidekiq.yml` yourself. `/readyz` reports `sidekiq.processes`. |
| Deploy fails with `Preflight found N blocking issue(s)` | Read the `Preflight error [...]` log lines, or run `anchor doctor`. See [preflight.md](preflight.md). |
| Health check fails | The app has to listen on `0.0.0.0:$PORT` and answer the health check path with a status below 500. |
| Health endpoints | `curl localhost:3000/healthz` checks liveness. `curl localhost:3000/readyz` checks the database, Redis, Sidekiq, and queue latency. |
