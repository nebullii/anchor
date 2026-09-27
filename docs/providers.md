# Providers

A **provider** is where a project's containers are built and run. The deployment pipeline talks only
to the `Providers::Base` interface. To add a cloud, you write one class and add one registry entry.
None of the jobs change.

| Key (`projects.provider`) | Class | Status |
|---|---|---|
| `local_docker` | `Providers::LocalDocker` | Works. Free. Meant for trying Anchor and for development. |
| `gcp_cloud_run` | `Providers::GcpCloudRun` | Supported (beta). This is the default for new projects when a Google account is connected. |

Nothing else is implemented yet. AWS (ECS or App Runner), Azure Container Apps, Fly.io, and
Kubernetes are planned.

## The contract

Source: [`app/services/providers/base.rb`](../app/services/providers/base.rb).

```ruby
module Providers
  class Base
    NOOP_LOG = ->(_line) {}
    attr_reader :project, :runner

    def initialize(project, runner: CommandRunner.new)

    def name                                           # => "local_docker", must match project.provider
    def log_source                                     # => DeploymentLog#source, default "system"

    def provision!(log: NOOP_LOG)                      # idempotent one-time setup
    def build!(deployment, source_dir, log: NOOP_LOG)  # => build_ref (String)
    def build_status(deployment)                       # => Providers::BuildStatus
    def cancel_build!(deployment)
    def deploy_revision!(deployment, env:, log: NOOP_LOG)  # => Providers::Revision; must NOT shift traffic
    def promote!(deployment, log: NOOP_LOG)            # 100% traffic to deployment.revision_name; => service URL
    def rollback!(project, revision_name, log: NOOP_LOG)   # 100% traffic to an older revision; => service URL
    def delete_revision!(deployment)                   # best-effort cleanup of an unpromoted revision
  end
end
```

Every `log:` argument is a callable, `->(line) { ... }`. Lines you pass to it are streamed to the
deployment log in the browser, the CLI, and the MCP server, after going through `Security::Redactor`.

### Value objects

```ruby
Providers::BuildStatus.new(state: :pending | :success | :failure, detail: nil, log_url: nil)
#   #pending? #success? #failure? #terminal?

Providers::Revision = Data.define(:name, :url)
#   name — the provider's revision identifier (Cloud Run revision, container name)
#   url  — a URL that reaches THIS revision before it gets traffic; the health check probes it
```

### Errors

| Raise | When | What the pipeline does |
|---|---|---|
| `Providers::Error` | Permanent: bad config, failed build, missing credentials | Fails the deployment with your message |
| `Providers::TransientError` (a subclass of `Error`) | Retryable: rate limits, 5xx, network | Retries a bounded number of times, then fails the deployment |

`Providers.translate_errors { ... }` maps these onto `Deployments::DeploymentError` and
`Deployments::TransientError`, which `Deployments::BaseJob` handles.

### Optional hooks

`HealthCheckJob` calls these only if your class defines them (`respond_to?`):

```ruby
def health_check_url(deployment)      # => URL to probe instead of deployment.revision_url
def health_check_headers(deployment)  # => Hash of headers, e.g. an identity token for private services
```

`LocalDocker#health_check_url` uses the first hook to swap `localhost` for `ANCHOR_LOCAL_DOCKER_HOST`
when the worker runs inside docker compose. Neither built-in provider implements
`health_check_headers` yet.

### Where each method is called

| Method | Called from | Deployment status at that point |
|---|---|---|
| `provision!` | `PrepareJob` (every deploy, so it must be idempotent) | `analyzing` |
| `build!` | `PrepareJob`, after clone, preflight, and Dockerfile generation | `building` |
| `build_status` | `PollBuildStatusJob`, with backoff of 15s, then 30s, then 60s, up to 40 polls | `building` |
| `cancel_build!` | `Deployment#cancel!`, `ReaperJob` | any in-progress status |
| `deploy_revision!` | `DeployToCloudRunJob` | `deploying` |
| `promote!` | `HealthCheckJob` after a healthy probe | `health_check` |
| `delete_revision!` | `HealthCheckJob` after the checks run out, or on cancel during a health check | `health_check` |
| `rollback!` | `RollbackJob` | `deploying` (the rollback deployment) |

### Rules your implementation must follow

1. **Be stateless across jobs.** Each method may run on a different worker process or host. Keep
   state in the deployment row (`build_ref`, `image_url`, `revision_name`, `revision_url`) and never
   on local disk. `source_dir` is deleted as soon as `build!` returns.
2. **Keep `deploy_revision!` from shifting traffic.** The URL it returns must reach the new revision
   directly. If it returns no URL, the pipeline refuses to continue, because it can't health-check
   the revision.
3. **Make methods safe to retry.** A `TransientError` re-runs the step. For example, `LocalDocker`
   runs `docker rm -f <name>` before `docker run`.
4. **Use the runner for every command.** `runner.call(argv, env:, log:, on_spawn:, redact:)` takes an
   argv array (never a shell string) and returns `Result(output, exit_status)`. The protected helper
   `run!` raises through `classify_failure(output)`, which you can override to map output to
   `TransientError`. Pass secret values as `redact:` so they never reach `log`.
5. **Keep secret values off command lines.** `LocalDocker` passes `-e KEY` and supplies the values
   through the child process environment. `GcpCloudRun` writes a temporary YAML `--env-vars-file`.
6. **Use the project's settings:** `memory_setting` (default `"512Mi"`), `container_port`
   (`project.port`, default 3000), `project.public_access`, and `project.health_check_path` (the
   health check job reads the last one).

## Adding a provider

Say you want to add `fly_machines`:

1. **Implement the class** in `app/services/providers/fly_machines.rb`:

   ```ruby
   module Providers
     class FlyMachines < Base
       def name = "fly_machines"

       def provision!(log: NOOP_LOG)
         # verify credentials, create the app if missing — idempotent
       end

       def build!(deployment, source_dir, log: NOOP_LOG)
         # build + push; return an opaque ref and set deployment.image_url
       end

       def build_status(deployment)
         BuildStatus.new(state: :success, detail: "…")
       end

       def cancel_build!(deployment) = false

       def deploy_revision!(deployment, env:, log: NOOP_LOG)
         # start a machine with the new image but keep it out of the load balancer
         Revision.new(name: "…", url: "https://…")
       end

       def promote!(deployment, log: NOOP_LOG)  = # route traffic, return service URL
       def rollback!(project, revision_name, log: NOOP_LOG) = # route traffic back, return URL
       def delete_revision!(deployment) = # stop/destroy, best effort
     end
   end
   ```

2. **Register it** in `app/services/providers.rb`:

   ```ruby
   REGISTRY = {
     "gcp_cloud_run" => "Providers::GcpCloudRun",
     "local_docker"  => "Providers::LocalDocker",
     "fly_machines"  => "Providers::FlyMachines"
   }.freeze
   ```

   `Project` validates `provider` against `Providers::NAMES`, so this is the only allowlist.

3. **Offer it in the UI.** Add an entry to `DeployWizardController::PROVIDER_OPTIONS`.
   `Project` skips GCP-only validation and provisioning only for `local_docker`, so check
   `validates :gcp_project_id` and `after_create :enqueue_provisioning` in `app/models/project.rb`
   and make them conditional for your provider too.

4. **Log source.** If you override `log_source`, add the value to the `source` inclusion list in
   `app/models/deployment_log.rb`. The allowed values today are `system`, `cloud_build`, `cloud_run`,
   and `gcp`.

5. **Specs.** Inject `FakeCommandRunner` (`spec/support/fake_command_runner.rb`) and assert on the exact
   argv. Never run the real CLI in tests. `spec/services/providers/local_docker_spec.rb` and
   `gcp_cloud_run_spec.rb` are the templates.

   ```ruby
   runner   = FakeCommandRunner.new.stub(/deploy/, output: '{"url":"https://x"}')
   provider = Providers::FlyMachines.new(project, runner: runner)
   ```

## How the built-in providers work

### Local Docker

| Step | What happens |
|---|---|
| `provision!` | `docker version`. Fails with a clear message if the daemon is down. |
| `build!` | Synchronous `docker build -t anchor-local/<service>:<deployment_id>`. The PID is recorded so `cancel_build!` can send it SIGTERM. |
| `build_status` | `docker image inspect` |
| `deploy_revision!` | `docker run -d --name anchor-<service>-<id> -p 127.0.0.1:<free port>:<port> --memory <m> --restart unless-stopped` |
| `promote!` / `rollback!` | `docker start <target>`, then `docker stop` for every other container labelled with the project. Old containers are stopped, not removed, so a rollback can start them again. |
| `delete_revision!` | `docker rm -f` |

This provider assumes the worker and the Docker daemon are on the same host. Builds run on that host
with no sandbox.

### Google Cloud Run

| Step | What happens |
|---|---|
| `provision!` | Enables the APIs and creates the Artifact Registry repository. Skipped once `gcp_provisioned`. |
| `build!` | `gcloud builds submit --async --tag=<region>-docker.pkg.dev/...`. Returns the Cloud Build id. |
| `build_status` | `gcloud builds describe`, mapped to pending, success, or failure, with a console log URL |
| `cancel_build!` | `gcloud builds cancel` |
| `deploy_revision!` | `gcloud run deploy --no-traffic --tag=d<id> --env-vars-file=...`. Returns the tagged revision URL. |
| `promote!` / `rollback!` | `gcloud run services update-traffic --to-revisions=<rev>=100` |
| `delete_revision!` | `gcloud run revisions delete` |

Every gcloud call runs as the project owner, using a Google OAuth token or a service-account key.

Known limitations:

- The **first** deploy of a new service can't use `--no-traffic`, because Cloud Run rejects it when
  it creates a service. That revision gets traffic before the health check runs.
- App secrets are set as plain environment variables on the revision.
- Private services are probed without an identity token.
