#!/usr/bin/env python3
"""
Anchor — GCloud Deploy Agent
One command. Scans your project, asks for secrets, deploys to Cloud Run. Free.
"""

import os
import sys
import json
import stat
import time
import getpass
import argparse
import subprocess
from pathlib import Path

import litellm

# ── Config ────────────────────────────────────────────────────────────────────

DEFAULT_MODEL = "claude-sonnet-4-6"
MAX_FILE_BYTES = 60_000
MAX_TURNS = 80

SKIP_DIRS = {
    ".git", "__pycache__", "node_modules", ".venv", "venv", "env",
    "dist", "build", ".next", ".nuxt", "target", "vendor", ".tox",
    ".mypy_cache", ".pytest_cache", "coverage", "htmlcov", ".turbo",
    ".cargo", "pkg", ".serverless", "cdk.out", ".terraform",
}

SKIP_EXTENSIONS = {
    ".pyc", ".pyo", ".pyd", ".so", ".dylib", ".dll", ".exe",
    ".jpg", ".jpeg", ".png", ".gif", ".ico", ".svg", ".webp", ".avif",
    ".mp4", ".mp3", ".wav", ".ogg", ".zip", ".tar", ".gz", ".tgz",
    ".pdf", ".woff", ".woff2", ".ttf", ".eot", ".bin", ".db", ".sqlite",
}

OUTPUT_FILES = {"Dockerfile", "deploy.sh", ".gcloudignore", "DEPLOY_README.md", "deploy.yml"}


# ── Tools ─────────────────────────────────────────────────────────────────────

def list_directory(path: str, recursive: bool = False) -> str:
    p = Path(path)
    if not p.exists():
        return f"ERROR: Path does not exist: {path}"
    if not p.is_dir():
        return f"ERROR: Not a directory: {path}"

    results = []
    if recursive:
        for item in sorted(p.rglob("*")):
            if any(part in SKIP_DIRS for part in item.parts):
                continue
            if item.name.startswith(".") and item.name not in {
                ".env", ".env.example", ".env.sample", ".gitignore"
            }:
                continue
            if item.suffix in SKIP_EXTENSIONS:
                continue
            rel = item.relative_to(p)
            kind = "DIR " if item.is_dir() else "FILE"
            results.append(f"{kind}  {rel}")
    else:
        for item in sorted(p.iterdir()):
            if item.name in SKIP_DIRS:
                continue
            kind = "DIR " if item.is_dir() else "FILE"
            results.append(f"{kind}  {item.name}")

    return "\n".join(results) if results else "(empty)"


def read_file(path: str) -> str:
    p = Path(path)
    if not p.exists():
        return f"ERROR: File does not exist: {path}"
    if not p.is_file():
        return f"ERROR: Not a file: {path}"
    if p.suffix in SKIP_EXTENSIONS:
        return f"SKIPPED: Binary/media file ({p.suffix})"
    size = p.stat().st_size
    if size > MAX_FILE_BYTES:
        return (
            f"TRUNCATED: File too large ({size:,} bytes), showing first {MAX_FILE_BYTES:,} chars.\n\n"
            + p.read_text(encoding="utf-8", errors="replace")[:MAX_FILE_BYTES]
        )
    try:
        return p.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        return f"ERROR reading file: {e}"


def write_file(path: str, content: str) -> str:
    p = Path(path)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
        if p.name == "deploy.sh":
            p.chmod(p.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        return f"OK: Written {p} ({len(content):,} bytes)"
    except Exception as e:
        return f"ERROR writing file: {e}"


def run_command(command: str, interactive: bool = False) -> str:
    """
    Run a shell command.
    interactive=True  → inherits terminal stdio (for gcloud auth login, etc.)
    interactive=False → captures output and returns it to the agent
    """
    print(f"\n     $ {command}")
    try:
        if interactive:
            result = subprocess.run(command, shell=True)
            return f"Exited with code {result.returncode}"
        else:
            result = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                timeout=600,
            )
            out = result.stdout.strip()
            err = result.stderr.strip()
            combined = out
            if err:
                combined += f"\n[stderr] {err}"
            if result.returncode != 0:
                combined += f"\n[exit code] {result.returncode}"
            return combined or "(no output)"
    except subprocess.TimeoutExpired:
        return "ERROR: Command timed out after 10 minutes"
    except Exception as e:
        return f"ERROR: {e}"


def ask_user(question: str) -> str:
    """
    Prompt the user for a NON-SECRET value (project ID, app name, choices).
    NEVER use for API keys, passwords, tokens — use push_secrets instead.
    """
    print(f"\n{'─'*60}")
    print(f"  Anchor needs input:")
    try:
        value = input(f"  {question}: ")
    except (KeyboardInterrupt, EOFError):
        print("\nAborted.")
        sys.exit(1)
    print(f"{'─'*60}")
    return value.strip()


def push_secrets(env_file: str, project_id: str) -> str:
    """
    Read a .env-style file and push each key=value to GCloud Secret Manager.
    Secret VALUES never leave this function — they are NEVER sent to the LLM.
    The env file is deleted after all secrets are pushed successfully.
    Returns the --set-secrets string ready to paste into gcloud run deploy.
    """
    p = Path(env_file)
    if not p.exists():
        return f"ERROR: {env_file} not found. Create it with your secret values first."

    secrets_pushed: list[str] = []
    errors: list[str] = []

    try:
        lines = p.read_text(encoding="utf-8").splitlines()
    except Exception as e:
        return f"ERROR reading {env_file}: {e}"

    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if not key or not value:
            errors.append(f"SKIPPED {key}: empty value — fill it in and re-run")
            continue

        # Create secret — if it already exists, add a new version
        try:
            r1 = subprocess.run(
                ["gcloud", "secrets", "create", key, "--data-file=-", f"--project={project_id}"],
                input=value, capture_output=True, text=True,
            )
            if r1.returncode != 0:
                r2 = subprocess.run(
                    ["gcloud", "secrets", "versions", "add", key, "--data-file=-", f"--project={project_id}"],
                    input=value, capture_output=True, text=True,
                )
                if r2.returncode != 0:
                    errors.append(f"ERROR on {key}: {r2.stderr.strip()}")
                    continue
            secrets_pushed.append(key)
        except Exception as e:
            errors.append(f"ERROR on {key}: {e}")

    set_secrets = ",".join(f"{k}={k}:latest" for k in secrets_pushed)

    lines_out = [f"Pushed: {', '.join(secrets_pushed) if secrets_pushed else 'none'}"]
    if errors:
        lines_out.append(f"Errors: {'; '.join(errors)}")
    lines_out.append(f"File kept at: {env_file} (already in .gcloudignore and .gitignore — never committed or deployed)")
    lines_out.append(f"Use in gcloud run deploy: --set-secrets={set_secrets}")
    return "\n".join(lines_out)


TOOL_MAP = {
    "list_directory": list_directory,
    "read_file": read_file,
    "write_file": write_file,
    "run_command": run_command,
    "ask_user": ask_user,
    "push_secrets": push_secrets,
}

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "list_directory",
            "description": "List files and directories at a path. Use recursive=true to see the full project tree.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "recursive": {"type": "boolean", "default": False},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read the full contents of a file.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": (
                "Write a file to disk. Use ONLY for: "
                "Dockerfile, deploy.sh, .gcloudignore, DEPLOY_README.md, "
                ".github/workflows/deploy.yml"
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": (
                "Execute a shell command. Use for all gcloud, docker, gsutil commands. "
                "Set interactive=true ONLY for commands that need user input in the terminal "
                "(e.g. gcloud auth login). All other commands use interactive=false."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "The shell command to run"},
                    "interactive": {
                        "type": "boolean",
                        "description": "Set true only for interactive commands like gcloud auth login",
                        "default": False,
                    },
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "ask_user",
            "description": (
                "Prompt the user for a NON-SECRET value in the terminal. "
                "Use ONLY for: project ID selection, app name, yes/no choices. "
                "NEVER use for API keys, passwords, or tokens — use push_secrets for those."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "question": {"type": "string", "description": "The question to display"},
                },
                "required": ["question"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "push_secrets",
            "description": (
                "Read a .env-style file the user has filled in and push each secret to "
                "GCloud Secret Manager. Secret values NEVER pass through the LLM. "
                "The file is deleted from disk after pushing. "
                "Returns the --set-secrets string to use in gcloud run deploy."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "env_file": {
                        "type": "string",
                        "description": "Absolute path to the .env file containing key=value secrets",
                    },
                    "project_id": {
                        "type": "string",
                        "description": "GCloud project ID to push secrets into",
                    },
                },
                "required": ["env_file", "project_id"],
            },
        },
    },
]


# ── System Prompt ─────────────────────────────────────────────────────────────

def build_prompt(project_path: str) -> str:
    return f"""\
You are Anchor, a cloud deployment agent for Google Cloud Run.

Your job: scan the project at `{project_path}`, then FULLY DEPLOY IT — no manual steps left for the user.
The user must NEVER be charged. The user only provides their LLM API key. You handle everything else.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PHASE 1 — SCAN THE PROJECT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. list_directory("{project_path}", recursive=true) — see the full tree
2. Read EVERY relevant file:
   - Dependency manifests: requirements.txt, pyproject.toml, package.json, go.mod, Cargo.toml, Gemfile
   - Entry points: main.py, app.py, server.js, index.js, main.go, cmd/, src/
   - Config and secrets: .env, .env.example, .env.sample, config.py, settings.py, *.yaml, *.toml
   - Any existing Dockerfile or docker-compose
   - Storage patterns: file uploads, DB connections, cache usage (see storage rules below)
3. After scanning, you will know: language, framework, entry point, port, all secrets, storage needs.

STORAGE RULES:
┌──────────────────────┬──────────────────────────────────────────────────────┐
│ Detected             │ Action                                               │
├──────────────────────┼──────────────────────────────────────────────────────┤
│ File uploads / blobs │ Create GCS bucket (free: 5GB/month)                 │
│ SQLite               │ WARN user — not persistent on Cloud Run              │
│ PostgreSQL / MySQL   │ WARN — Cloud SQL costs money, suggest Neon free tier │
│ Redis                │ WARN — Memorystore costs money, suggest Upstash free │
│ Firestore / Firebase │ Create Firestore database (free: 1GB/50K reads/day) │
│ No storage           │ Skip storage entirely                                │
└──────────────────────┴──────────────────────────────────────────────────────┘

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PHASE 2 — GENERATE FILES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write all files before running any gcloud commands.

FILE: {project_path}/Dockerfile
- Correct slim/alpine base image for the stack
- Multi-stage build for Go/Node to minimize size
- Only copy runtime-needed files
- Expose the correct PORT, set ENV PORT=<port>
- Correct start command for the framework

FILE: {project_path}/.gcloudignore
- Exclude: .git, .env, .env.*, .env.anchor, venv/, .venv/, __pycache__/, *.pyc,
  node_modules/, dist/, build/, .next/, *.pem, *.key, *.log, *.sqlite,
  tests/, docs/, *.md, Makefile, docker-compose*, .github/, cicd-key.json

FILE: {project_path}/.github/workflows/deploy.yml
```yaml
name: Deploy to Cloud Run
on:
  push:
    branches: [main]
env:
  PROJECT_ID: ${{{{ vars.GCP_PROJECT_ID }}}}
  APP_NAME: ${{{{ vars.GCP_APP_NAME }}}}
  REGION: ${{{{ vars.GCP_REGION }}}}
  IMAGE: ${{{{ vars.GCP_REGION }}}}-docker.pkg.dev/${{{{ vars.GCP_PROJECT_ID }}}}/${{{{ vars.GCP_APP_NAME }}}}/${{{{ vars.GCP_APP_NAME }}}}:${{{{ github.sha }}}}
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: google-github-actions/auth@v2
        with:
          credentials_json: ${{{{ secrets.GCP_SA_KEY }}}}
      - uses: google-github-actions/setup-gcloud@v2
      - name: Build image
        run: gcloud builds submit . --tag="${{{{ env.IMAGE }}}}" --project="${{{{ env.PROJECT_ID }}}}"
      - name: Deploy
        run: |
          gcloud run deploy "${{{{ env.APP_NAME }}}}" \\
            --image="${{{{ env.IMAGE }}}}" --platform=managed \\
            --region="${{{{ env.REGION }}}}" --allow-unauthenticated \\
            --min-instances=0 --max-instances=10 \\
            --memory=512Mi --cpu=1 --port=<detected_port> \\
            --set-secrets="<SECRETS>" \\
            --project="${{{{ env.PROJECT_ID }}}}"
      - name: URL
        run: gcloud run services describe "${{{{ env.APP_NAME }}}}" --region="${{{{ env.REGION }}}}" --project="${{{{ env.PROJECT_ID }}}}" --format="value(status.url)"
```

FILE: {project_path}/deploy.sh
- A reusable script for future manual redeployments
- Include all the gcloud commands with PROJECT_ID and APP_NAME filled in (use the values you collected)
- Include the CI/CD setup section (service account + key generation + GitHub instructions)
- Include budget alert setup

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PHASE 3 — GCLOUD SETUP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Check gcloud is installed:
   run_command("gcloud version")
   If it fails: tell the user to install it from https://cloud.google.com/sdk/docs/install and exit.

2. Check if already authenticated:
   run_command("gcloud auth list --filter=status:ACTIVE --format=value(account)")
   - If empty → run_command("gcloud auth login", interactive=true)
   - Re-check auth after login

3. List available projects:
   run_command("gcloud projects list --format=table(projectId,name)")
   Then ask_user("Enter your Project ID from the list above (or type 'new' to create one)", secret=false)
   - If user types 'new':
     ask_user("Enter a new project ID (lowercase letters, digits, hyphens)", secret=false)
     run_command("gcloud projects create <id>")
     run_command("gcloud config set project <id>")
   - Else: run_command("gcloud config set project <chosen_id>")
   Store this as PROJECT_ID.

4. Ask for app name:
   ask_user("What should your app be called? (lowercase letters and hyphens only, e.g. my-app)", secret=false)
   Store this as APP_NAME.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PHASE 4 — PROVISION GOOGLE CLOUD
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Run these commands using the PROJECT_ID from Phase 3.

1. Enable billing (REQUIRED by Google even for free tier — no charges will occur):
   run_command("gcloud billing accounts list --format=value(ACCOUNT_ID)")
   If a billing account exists, link it:
   run_command("gcloud billing projects link PROJECT_ID --billing-account=BILLING_ACCOUNT_ID")
   If no billing account exists, tell the user:
     "Google requires a billing account to be linked even for free tier services.
      Go to https://console.cloud.google.com/billing, add a payment method (you won't be charged),
      then re-run Anchor."
   Then exit gracefully — do NOT suggest alternative platforms like Netlify or Vercel.

2. Enable APIs:
   run_command("gcloud services enable run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com --project=PROJECT_ID")
   If this fails due to billing not enabled: print the billing setup instructions above and stop. Do NOT suggest alternatives.

2. Budget alert ($1 cap — emails user if anything goes wrong):
   run_command("gcloud billing projects describe PROJECT_ID --format=value(billingAccountName)")
   Extract billing account ID, then:
   run_command("gcloud billing budgets create --billing-account=BILLING_ID --display-name=anchor-APP_NAME-guard --budget-amount=1USD --threshold-rule=percent=0.3 --threshold-rule=percent=1.0")
   If this fails (billing not enabled), print a warning but continue.

3. Create Artifact Registry repo:
   run_command("gcloud artifacts repositories create APP_NAME --repository-format=docker --location=us-central1 --project=PROJECT_ID")

4. Storage (only if detected in Phase 1):
   - GCS: run_command("gcloud storage buckets create gs://PROJECT_ID-APP_NAME-storage --location=us-central1 --project=PROJECT_ID")
   - Firestore: run_command("gcloud services enable firestore.googleapis.com --project=PROJECT_ID") then run_command("gcloud firestore databases create --location=us-central1 --project=PROJECT_ID")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PHASE 5 — COLLECT AND STORE SECRETS (safely)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Secret values must NEVER pass through the LLM. Use this exact flow:

1. Write a secrets template file at PROJECT_PATH/.env.anchor using write_file:
   - Add a comment header explaining what it is
   - One line per detected secret: KEY=
   - Example:
     # Anchor secrets — fill in values then save. This file stays local (never committed or deployed).
     OPENAI_API_KEY=
     DATABASE_URL=

2. Tell the user via ask_user:
   ask_user("Your secrets template is ready at .env.anchor — open it, fill in ALL values, save it, then press Enter")

3. After the user presses Enter, call push_secrets:
   push_secrets(env_file="PROJECT_PATH/.env.anchor", project_id="PROJECT_ID")
   This reads the file and pushes each secret directly to Secret Manager.
   Secret values never touch the LLM. The file stays on disk (it's in .gcloudignore/.gitignore).

4. Use the --set-secrets string returned by push_secrets in the Cloud Run deploy command.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PHASE 6 — BUILD AND DEPLOY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
IMAGE = "us-central1-docker.pkg.dev/PROJECT_ID/APP_NAME/APP_NAME:latest"

1. Build and push:
   run_command("gcloud builds submit PROJECT_PATH --tag=IMAGE --project=PROJECT_ID")
   This may take 2-5 minutes. That is normal.

2. Deploy to Cloud Run:
   run_command(
     "gcloud run deploy APP_NAME \
       --image=IMAGE --platform=managed --region=us-central1 \
       --allow-unauthenticated --min-instances=0 --max-instances=10 \
       --memory=512Mi --cpu=1 --port=PORT \
       --set-secrets=SET_SECRETS_STRING \
       [--set-env-vars=GCS_BUCKET=bucket_name  ← only if GCS was set up] \
       --project=PROJECT_ID"
   )

3. Get live URL:
   run_command("gcloud run services describe APP_NAME --region=us-central1 --project=PROJECT_ID --format=value(status.url)")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PHASE 7 — CI/CD SETUP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Create service account:
   run_command("gcloud iam service-accounts create anchor-cicd --display-name=Anchor CI/CD --project=PROJECT_ID")

2. Grant roles (run each separately):
   run_command("gcloud projects add-iam-policy-binding PROJECT_ID --member=serviceAccount:anchor-cicd@PROJECT_ID.iam.gserviceaccount.com --role=roles/run.admin --quiet")
   run_command("gcloud projects add-iam-policy-binding PROJECT_ID --member=serviceAccount:anchor-cicd@PROJECT_ID.iam.gserviceaccount.com --role=roles/cloudbuild.builds.builder --quiet")
   run_command("gcloud projects add-iam-policy-binding PROJECT_ID --member=serviceAccount:anchor-cicd@PROJECT_ID.iam.gserviceaccount.com --role=roles/artifactregistry.writer --quiet")
   run_command("gcloud projects add-iam-policy-binding PROJECT_ID --member=serviceAccount:anchor-cicd@PROJECT_ID.iam.gserviceaccount.com --role=roles/secretmanager.secretAccessor --quiet")
   run_command("gcloud projects add-iam-policy-binding PROJECT_ID --member=serviceAccount:anchor-cicd@PROJECT_ID.iam.gserviceaccount.com --role=roles/iam.serviceAccountUser --quiet")

3. Generate key:
   run_command("gcloud iam service-accounts keys create PROJECT_PATH/cicd-key.json --iam-account=anchor-cicd@PROJECT_ID.iam.gserviceaccount.com --project=PROJECT_ID")

4. Print final instructions to the user (this is the only manual step left):
   Print a clear box like:
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ✅  YOUR APP IS LIVE AT: https://...
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

   CI/CD: every git push to main will auto-deploy.
   To activate it, add these to your GitHub repo:

   Repo → Settings → Secrets → Actions:
     GCP_SA_KEY = <paste the contents of cicd-key.json>

   Repo → Settings → Variables → Actions:
     GCP_PROJECT_ID = PROJECT_ID
     GCP_APP_NAME   = APP_NAME
     GCP_REGION     = us-central1

   Then delete the key file:  rm PROJECT_PATH/cicd-key.json
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ABSOLUTE RULES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- NEVER skip a phase. Complete all 7 phases.
- NEVER hardcode a secret value anywhere. Always use Secret Manager.
- --min-instances=0 is NON-NEGOTIABLE. It is what keeps the bill at $0.
- --set-secrets for credentials. --set-env-vars only for non-sensitive config.
- If a command fails, read the error and try to fix it. Do not give up.
- cicd-key.json must never be committed — warn the user to delete it.
- The only thing the user provides is their LLM API key. You handle everything else.

Start scanning now.
"""


# ── Agentic Loop ──────────────────────────────────────────────────────────────

def execute_tool(name: str, args: dict) -> str:
    fn = TOOL_MAP.get(name)
    if not fn:
        return f"ERROR: Unknown tool '{name}'"
    try:
        return fn(**args)
    except TypeError as e:
        return f"ERROR: Bad arguments for {name}: {e}"


def run_agent(project_path: str, model: str) -> None:
    print(f"\n{'━'*60}")
    print(f"  Anchor  |  project: {project_path}")
    print(f"  Model   |  {model}")
    print(f"{'━'*60}\n")

    messages = [{"role": "user", "content": build_prompt(project_path)}]
    files_written: list[str] = []

    for turn in range(1, MAX_TURNS + 1):
        print(f"\n[{turn:02d}] Thinking...", end=" ", flush=True)

        # Retry on rate limit with exponential backoff
        for attempt in range(5):
            try:
                response = litellm.completion(
                    model=model,
                    messages=messages,
                    tools=TOOLS,
                    tool_choice="auto",
                    max_tokens=4096,
                )
                break
            except litellm.RateLimitError as e:
                wait = 2 ** attempt * 10  # 10s, 20s, 40s, 80s, 160s
                print(f"\n     ⏳ Rate limit hit — retrying in {wait}s...")
                time.sleep(wait)
                if attempt == 4:
                    raise e

        msg = response.choices[0].message

        # Append assistant message
        assistant_entry: dict = {"role": "assistant"}
        if msg.content:
            assistant_entry["content"] = msg.content
        if msg.tool_calls:
            assistant_entry["tool_calls"] = [
                {
                    "id": tc.id,
                    "type": "function",
                    "function": {
                        "name": tc.function.name,
                        "arguments": tc.function.arguments,
                    },
                }
                for tc in msg.tool_calls
            ]
        messages.append(assistant_entry)

        if not msg.tool_calls:
            # If agent narrated but hasn't finished all phases yet, nudge it to continue
            deploy_done = any("cicd-key.json" in f or "deploy.sh" in f for f in files_written)
            if not deploy_done:
                if msg.content:
                    print(f"\n{msg.content}")
                print(f"\n[nudge] Agent stopped early — pushing it to continue...")
                messages.append({
                    "role": "user",
                    "content": "Continue. Do not summarize or plan — use tools to execute the next phase now."
                })
                continue
            # All done
            if msg.content:
                print(f"\n{msg.content}")
            break

        print(f"{len(msg.tool_calls)} action(s)")

        for tc in msg.tool_calls:
            name = tc.function.name
            try:
                args = json.loads(tc.function.arguments)
            except (json.JSONDecodeError, TypeError):
                args = {}

            # Log action
            if name == "list_directory":
                rec = " (recursive)" if args.get("recursive") else ""
                print(f"     📂  list_directory: {args.get('path', '')}{rec}")
            elif name == "read_file":
                print(f"     📄  read_file: {args.get('path', '')}")
            elif name == "write_file":
                fpath = args.get("path", "")
                fname = Path(fpath).name
                print(f"     ✍️   write_file: {fpath}")
                if fname in OUTPUT_FILES:
                    files_written.append(fpath)
            elif name == "run_command":
                pass  # command is printed inside run_command()
            elif name == "ask_user":
                pass  # question is printed inside ask_user()
            elif name == "push_secrets":
                print(f"     🔐  push_secrets: {args.get('env_file', '')} → Secret Manager")

            result = execute_tool(name, args)

            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": result,
            })
    else:
        print(f"\n⚠️  Reached max turns ({MAX_TURNS}).")

    print(f"\n{'━'*60}\n")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="anchor",
        description="Anchor — deploy any project to Google Cloud Run for free. One command.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
examples:
  python anchor.py --project ./my-app
  python anchor.py --project ~/projects/my-api --model gpt-4o

supported models:
  claude-sonnet-4-6         (default)   needs ANTHROPIC_API_KEY
  claude-haiku-4-5          (faster)    needs ANTHROPIC_API_KEY
  gpt-4o                               needs OPENAI_API_KEY
  gemini/gemini-2.0-flash              needs GEMINI_API_KEY
        """,
    )
    parser.add_argument(
        "--project",
        required=True,
        metavar="PATH",
        help="Path to the project to deploy",
    )
    parser.add_argument(
        "--model",
        default=os.getenv("ANCHOR_MODEL", DEFAULT_MODEL),
        metavar="MODEL",
        help=f"LLM model (default: {DEFAULT_MODEL}). Override with ANCHOR_MODEL env var.",
    )
    args = parser.parse_args()

    project_path = str(Path(args.project).resolve())
    if not Path(project_path).is_dir():
        print(f"Error: '{args.project}' is not a valid directory.")
        sys.exit(1)

    run_agent(project_path, args.model)


if __name__ == "__main__":
    main()
