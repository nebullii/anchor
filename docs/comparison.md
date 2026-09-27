# How Anchor compares

Anchor sits in a crowded space: tools that deploy your code into a cloud account you own
("bring your own cloud", or BYOC) or onto servers you run. This page explains where Anchor differs
and where it is behind.

> **About the other tools.** They are described only at the level of their public positioning, and
> they change quickly. This page reflects our understanding **as of 2026-09**. Check each project's own
> documentation before you decide. If something here is wrong, please open an issue or PR.

## At a glance

| | What it is (public positioning) | Where workloads run |
|---|---|---|
| **Anchor** | Open-source (MIT) control plane: GitHub repo → health-gated release, with a CLI and MCP server | Google Cloud Run in your GCP project, or local Docker |
| **Defang** | CLI-first tool that deploys Docker Compose projects to your cloud account, with AI-assisted workflows | Your AWS / GCP / DigitalOcean account (and a hosted playground) |
| **Qovery** | DevOps automation platform / internal developer platform | Kubernetes clusters in your AWS / GCP / Azure / Scaleway account |
| **Porter** | PaaS experience on your own cloud | Kubernetes clusters in your cloud account |
| **Flightcontrol** | PaaS-style deployments into your AWS account | AWS services (e.g. ECS/Fargate) in your account |
| **Northflank (BYOC)** | Developer platform whose control plane can run workloads in your cloud | Kubernetes in your cloud account, or Northflank's cloud |
| **Coolify** | Open-source, self-hostable PaaS (Heroku/Netlify-style) | Your own servers over SSH + Docker |
| **`gcloud run deploy --source`** | Google's own source-to-Cloud Run command | Cloud Run in your GCP project |

## Where Anchor is different

- **Releases are health-gated by default.** Every Cloud Run deploy after the first creates a
  `--no-traffic` revision with a tagged URL. Anchor probes that URL with backoff (8 attempts over
  150 s) and shifts traffic only if the checks pass. If they fail, the revision is deleted and the old
  one keeps serving. Plain `gcloud run deploy --source` sends traffic to the new revision right away
  unless you script `--no-traffic`, tags, and `update-traffic` yourself.
- **Rollback is one command.** `anchor rollback` (or a button, or an MCP tool) moves traffic back to an
  earlier healthy revision without rebuilding. It is recorded as its own deployment, and the one it
  replaces is marked `rolled_back`.
- **Preflight runs before the build.** 34 static rules ([docs/preflight.md](preflight.md)) catch
  certain failures such as binding to localhost, a hard-coded port, a missing go.sum, a committed
  master key, or Django `ALLOWED_HOSTS`. On a cloud provider, that means a doomed deploy never costs a
  Cloud Build run.
- **Coding agents can drive it.** The MCP server has 11 tools with read-only and destructive
  annotations. An agent can read the analysis, set secrets, deploy with `wait: true`, read the log
  tail and the failure category, and roll back. The CLI's exit codes work as a CI gate. Other tools
  in this list also advertise CLI or AI integrations; see their docs.
- **Open source and small.** It is one Rails app, one Sidekiq worker, Postgres, and Redis. You can
  read the whole deployment pipeline in `app/jobs/deployments/`.
- **Runs on Cloud Run, not Kubernetes.** You don't have a cluster to provision, upgrade, or pay for
  when idle. Your apps scale to zero on Cloud Run. The trade-off is that you get only what Cloud Run
  offers.
- **A free local path.** The Local Docker provider runs the same pipeline on a laptop, so you can
  evaluate Anchor without a cloud account.

## Where Anchor is behind

Be clear about these before you pick Anchor:

- **One real cloud.** Only Google Cloud Run is supported. AWS, Azure, and Kubernetes are not
  implemented. Most tools above support several clouds.
- **No managed databases or add-ons.** You bring your own `DATABASE_URL` and Redis. Northflank, Qovery,
  Porter, Coolify, and others provision databases for you.
- **No preview environments.** Anchor has no per-PR environments. Several of the tools above
  advertise them.
- **No custom domains or TLS management.** You get the Cloud Run `*.run.app` URL.
- **No Docker Compose or multi-service apps.** Each project is one container from one repo, or one
  directory of a monorepo.
- **Limited configuration.** Memory, health check path, and public or private access exist in the
  data model and are returned by the API, but can't be changed from the UI or API yet. There are no scaling controls, and there is no
  support for jobs or workers inside your app.
- **No teams, RBAC, or token scopes.** It is single-user, and API tokens have full account access.
- **Security gaps.** App secrets reach Cloud Run as plain env vars rather than Secret Manager, and
  user OAuth tokens still use AES-CBC. See the [README](../README.md#status-and-known-gaps).
- **Beta.** There is no hosted offering, no SLA, and a small team.

## When to use what

- If you want a **health-gated, agent-friendly release pipeline onto Cloud Run** and are willing to read
  and extend a small codebase, try Anchor.
- If you need **multi-cloud, databases, preview environments, or Kubernetes**, look at Qovery,
  Porter, Northflank, or Flightcontrol (AWS).
- If you have **Docker Compose projects** and want them in your own cloud, Defang is built around Compose.
- If you want an **open-source PaaS on your own VMs**, look at Coolify.
- If you need **one Cloud Run service and a single command**, `gcloud run deploy --source .` may be
  all you need. Anchor's value on top of it is the health gate, rollback, preflight checks, the
  UI and log streaming, and the API, CLI, and MCP server.
