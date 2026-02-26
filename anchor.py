#!/usr/bin/env python3
"""
Anchor — GCloud Deploy Agent
Scans any project and generates Google Cloud Run deployment files.
"""

import os
import sys
import json
import stat
import argparse
from pathlib import Path

import litellm

# ── Config ────────────────────────────────────────────────────────────────────

DEFAULT_MODEL = "claude-sonnet-4-6"
MAX_FILE_BYTES = 60_000
MAX_TURNS = 60

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

OUTPUT_FILES = {"Dockerfile", "deploy.sh", ".gcloudignore", "DEPLOY_README.md"}


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
            # Skip noisy dirs
            if any(part in SKIP_DIRS for part in item.parts):
                continue
            if item.name.startswith(".") and item.name not in {".env", ".env.example", ".env.sample", ".gitignore"}:
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
        return f"SKIPPED: File too large ({size:,} bytes). Only reading first {MAX_FILE_BYTES:,} chars.\n\n" + \
               p.read_text(encoding="utf-8", errors="replace")[:MAX_FILE_BYTES]
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


TOOL_MAP = {
    "list_directory": list_directory,
    "read_file": read_file,
    "write_file": write_file,
}

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "list_directory",
            "description": (
                "List files and directories at a path. "
                "Use recursive=true to see the full project tree at once."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Directory path to list"},
                    "recursive": {
                        "type": "boolean",
                        "description": "If true, list all files recursively",
                        "default": False,
                    },
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
                "properties": {
                    "path": {"type": "string", "description": "Absolute path to the file"}
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": (
                "Write content to a file on disk. "
                "Use ONLY to write: Dockerfile, deploy.sh, .gcloudignore, DEPLOY_README.md."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute path to write"},
                    "content": {"type": "string", "description": "File content"},
                },
                "required": ["path", "content"],
            },
        },
    },
]


# ── System Prompt ─────────────────────────────────────────────────────────────

def build_prompt(project_path: str) -> str:
    return f"""\
You are Anchor, an expert cloud deployment agent for Google Cloud Run.

Your mission: scan the project at `{project_path}`, deeply understand it, and generate 4 deployment files.
The user must NEVER be charged by Google. Every decision you make must stay within the free tier.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 1 — SCAN EXHAUSTIVELY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Call list_directory("{project_path}", recursive=true) first to see the full tree.
2. Read EVERY file that could reveal:
   - Language / runtime (requirements.txt, pyproject.toml, package.json, go.mod, Cargo.toml, Gemfile, pom.xml, *.csproj)
   - Framework and entry point (main.py, app.py, server.js, index.js, main.go, cmd/, src/)
   - Port the app listens on (look for PORT env var, app.run(port=...), listen(:8080), etc.)
   - ALL secrets and env vars (.env, .env.example, .env.sample, os.environ, os.getenv, process.env, config files, settings files)
   - Any existing Dockerfile or docker-compose (understand the intended setup)
   - STORAGE PATTERNS — look for any of:
       * File uploads (multer, UploadFile, multipart, boto3, S3, open() for writing, fs.writeFile)
       * SQL databases (sqlite3, SQLAlchemy, psycopg2, pg, mysql, sequelize, prisma, diesel)
       * NoSQL (pymongo, mongoose, Motor, firebase-admin, Firestore)
       * Key-value / cache (redis, ioredis, aioredis, memcached)
       * ORM models (models.py, schema.prisma, migrations/)
       * Any DATABASE_URL, REDIS_URL, MONGO_URI, STORAGE_BUCKET env vars
3. Do NOT skip any file — a missed secret, wrong port, or undetected storage need breaks the deploy.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STORAGE DECISION RULES (read carefully)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Cloud Run containers have an EPHEMERAL filesystem — any files written inside the container
are lost on restart. You MUST provision the right storage based on what you detect:

┌──────────────────────┬──────────────────────────────────────────────────────┐
│ Detected pattern     │ What to do                                           │
├──────────────────────┼──────────────────────────────────────────────────────┤
│ File uploads / blobs │ Provision Cloud Storage (GCS) bucket — FREE 5GB/mo  │
│ SQLite               │ WARN: not persistent. Migrate to Firestore (free)    │
│ PostgreSQL / MySQL   │ WARN: Cloud SQL costs money. Suggest Neon free tier  │
│ Redis / cache        │ WARN: Memorystore costs money. Suggest Upstash free  │
│ MongoDB              │ WARN: Atlas free tier (external). Not on GCloud free │
│ Firestore / Firebase │ Set up Firestore native mode — FREE 1GB/50K reads   │
│ No storage detected  │ Skip storage section entirely                        │
└──────────────────────┴──────────────────────────────────────────────────────┘

FREE TIER STORAGE LIMITS TO STAY WITHIN:
- Cloud Storage (GCS): 5 GB storage, 1 GB egress/month — free
- Firestore: 1 GB storage, 50K reads/day, 20K writes/day, 20K deletes/day — free
- Secret Manager: first 6 secret versions free, then $0.06/10K access — practically free

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 2 — GENERATE 4 FILES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write all 4 files into the project directory: {project_path}/

──────────────────────────────────────────
FILE 1: {project_path}/Dockerfile
──────────────────────────────────────────
- Use the exact slim/alpine base image for the detected stack
  (python:3.11-slim, node:20-alpine, golang:1.22-alpine, ruby:3.3-slim, etc.)
- Multi-stage build where it reduces image size (Go, Node builds)
- Copy only runtime-needed files (no .env, secrets, tests, docs)
- Install only production dependencies
- Expose the correct PORT (default 8080 if unknown)
- Set ENV PORT=<detected_port>
- Use the exact correct start command for the framework

──────────────────────────────────────────
FILE 2: {project_path}/deploy.sh
──────────────────────────────────────────
Use EXACTLY this structure. Include/omit storage sections based on what you detected.

```bash
#!/bin/bash
set -euo pipefail

# ┌──────────────────────────────────────────────────────────┐
# │  ANCHOR — Google Cloud Run Deploy Script                 │
# │  100% free tier — you will not be charged               │
# └──────────────────────────────────────────────────────────┘

# ── Edit these two lines before running ───────────────────
PROJECT_ID="your-gcloud-project-id"   # run: gcloud projects list
APP_NAME="my-app"                      # lowercase letters and hyphens only
# ──────────────────────────────────────────────────────────

REGION="us-central1"
PORT=<detected_port>
IMAGE="${{REGION}}-docker.pkg.dev/${{PROJECT_ID}}/${{APP_NAME}}/${{APP_NAME}}:latest"

# ── Export your secret values before running ──────────────
# <one commented export line per secret found in the project>
# export MY_API_KEY=""
# export DATABASE_URL=""
# ──────────────────────────────────────────────────────────

# ── Preflight: verify required secrets are set ────────────
# <one block per required secret — exit early if missing>
# if [ -z "${{MY_API_KEY:-}}" ]; then
#   echo "ERROR: export MY_API_KEY before running deploy.sh"
#   exit 1
# fi

echo "🔧 Enabling Google Cloud APIs..."
gcloud services enable \\
  run.googleapis.com \\
  artifactregistry.googleapis.com \\
  cloudbuild.googleapis.com \\
  secretmanager.googleapis.com \\
  <storage_apis_if_needed> \\
  --project="$PROJECT_ID"

# ── BUDGET ALERT (protects you from unexpected charges) ───
echo "💰 Setting up $1 budget alert..."
BILLING_ACCOUNT=$(gcloud billing projects describe "$PROJECT_ID" \\
  --format="value(billingAccountName)" | sed 's/billingAccounts\///')
gcloud billing budgets create \\
  --billing-account="$BILLING_ACCOUNT" \\
  --display-name="anchor-${{APP_NAME}}-guard" \\
  --budget-amount=1USD \\
  --threshold-rule=percent=0.3 \\
  --threshold-rule=percent=0.8 \\
  --threshold-rule=percent=1.0 2>/dev/null || echo "  (budget already exists, skipping)"
# NOTE: This alerts you by email if spend approaches $1.
# Cloud Run free tier = $0 for normal usage. Alert = safety net only.

echo "📦 Creating Artifact Registry repo (skips if exists)..."
gcloud artifacts repositories create "$APP_NAME" \\
  --repository-format=docker \\
  --location="$REGION" \\
  --project="$PROJECT_ID" 2>/dev/null || true

# ── STORAGE SETUP (only if project needs it) ──────────────
# === INCLUDE THIS BLOCK only if file uploads / blob storage detected ===
echo "🗄️  Setting up Cloud Storage bucket (free: 5GB/month)..."
BUCKET="${{PROJECT_ID}}-${{APP_NAME}}-storage"
gcloud storage buckets create "gs://${{BUCKET}}" \\
  --location="$REGION" \\
  --project="$PROJECT_ID" 2>/dev/null || true
# Bucket name passed to app as env var (not a secret — not sensitive)
GCS_BUCKET_ENV="GCS_BUCKET=${{BUCKET}}"
# === END FILE STORAGE BLOCK ===

# === INCLUDE THIS BLOCK only if Firestore / NoSQL detected ===
echo "🗄️  Setting up Firestore (free: 1GB / 50K reads per day)..."
gcloud services enable firestore.googleapis.com --project="$PROJECT_ID"
gcloud firestore databases create \\
  --location="$REGION" \\
  --project="$PROJECT_ID" 2>/dev/null || true
# === END FIRESTORE BLOCK ===

# === INCLUDE THIS WARNING only if PostgreSQL / MySQL detected ===
# ⚠️  WARNING: Cloud SQL is NOT free. Your project uses a SQL database.
# Recommended FREE alternatives:
#   - Neon (PostgreSQL): https://neon.tech  — free tier, serverless
#   - Supabase: https://supabase.com        — free tier, PostgreSQL
# Set your DATABASE_URL secret to your chosen provider's connection string.
# === END SQL WARNING ===

# === INCLUDE THIS WARNING only if Redis detected ===
# ⚠️  WARNING: Google Memorystore (Redis) is NOT free.
# Recommended FREE alternative:
#   - Upstash: https://upstash.com — free tier Redis, works with Cloud Run
# Set your REDIS_URL secret to your Upstash connection string.
# === END REDIS WARNING ===

echo "🔐 Pushing secrets to Secret Manager..."
# <one block per detected secret — follow this exact pattern for each>
# echo -n "$MY_API_KEY" | gcloud secrets create MY_API_KEY \\
#   --data-file=- --project="$PROJECT_ID" 2>/dev/null || \\
#   echo -n "$MY_API_KEY" | gcloud secrets versions add MY_API_KEY \\
#   --data-file=- --project="$PROJECT_ID"

echo "🏗  Building and pushing container image via Cloud Build..."
# Cloud Build free tier: 120 build-minutes/day
gcloud builds submit . \\
  --tag="$IMAGE" \\
  --project="$PROJECT_ID"

echo "🚀 Deploying to Cloud Run (free tier)..."
gcloud run deploy "$APP_NAME" \\
  --image="$IMAGE" \\
  --platform=managed \\
  --region="$REGION" \\
  --allow-unauthenticated \\
  --min-instances=0 \\
  --max-instances=10 \\
  --memory=512Mi \\
  --cpu=1 \\
  --port="$PORT" \\
  --set-secrets="MY_SECRET=MY_SECRET:latest" \\
  --set-env-vars="GCS_BUCKET=${{BUCKET}}" \\
  --project="$PROJECT_ID"
# ↑ --set-secrets  → ALL secrets/credentials (API keys, DB passwords, tokens)
# ↑ --set-env-vars → non-sensitive config only (e.g. bucket name, region)
# ↑ --min-instances=0 is REQUIRED — this is what keeps your bill at $0

echo ""
echo "✅ Deployed! Your app is live at:"
gcloud run services describe "$APP_NAME" \\
  --region="$REGION" \\
  --project="$PROJECT_ID" \\
  --format="value(status.url)"

echo ""
echo "📊 Free tier usage dashboard:"
echo "   https://console.cloud.google.com/billing"
```

RULES for deploy.sh:
- Only include storage blocks that match what you actually detected. Remove the others.
- Every secret/credential MUST use --set-secrets. NEVER --set-env-vars for sensitive values.
- Non-sensitive config (bucket name, region, feature flags) MAY use --set-env-vars.
- --min-instances=0 is NON-NEGOTIABLE. Removing it causes idle charges.
- --max-instances=10 caps runaway scaling costs.
- --memory=512Mi and --cpu=1 stay within free tier per-request quotas.
- Budget alert must always be included — it's the user's safety net.
- Add real shell validation (if [ -z ... ]) for every required secret.

──────────────────────────────────────────
FILE 3: {project_path}/.gcloudignore
──────────────────────────────────────────
Exclude from container build:
.git, .env, .env.*, venv/, .venv/, __pycache__/, *.pyc, *.pyo,
node_modules/, dist/, build/, .next/, .nuxt/, coverage/, htmlcov/,
*.pem, *.key, *.log, *.sqlite, *.db, .DS_Store, Thumbs.db,
tests/, test/, spec/, __tests__/, docs/, *.md, Makefile,
docker-compose*, .github/, .gitlab-ci.yml, .circleci/,
and any other file not needed to run the app in production.

──────────────────────────────────────────
FILE 4: {project_path}/DEPLOY_README.md
──────────────────────────────────────────
Include ALL of the following sections:

1. **Prerequisites**
   - gcloud CLI install: `brew install google-cloud-sdk` or link to cloud.google.com/sdk
   - Required runtime version (Python X.Y, Node X, Go X, etc.) — not needed inside Docker but useful for context
   - A Google Cloud account (free — no credit card required for Cloud Run free tier)

2. **One-time setup**
   - `gcloud auth login`
   - `gcloud config set project YOUR_PROJECT_ID`
   - How to find PROJECT_ID: `gcloud projects list`

3. **Fill in deploy.sh**
   - Set PROJECT_ID (where to find it)
   - Set APP_NAME (rules: lowercase, hyphens, no spaces)

4. **Set your secrets** (specific to this project)
   - List every secret variable found and what it should contain
   - Example: `export OPENAI_API_KEY="sk-..."` then run deploy.sh

5. **Storage setup** (only if storage was detected)
   - For GCS: bucket is auto-created, use the GCS_BUCKET env var in your code
   - For Firestore: database is auto-created, use the default database
   - For SQL/Redis warnings: link to Neon / Upstash and explain how to get free connection string

6. **Run the deploy**
   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```

7. **Free tier breakdown** — what is free and what are the limits:
   - Cloud Run: 2M requests/month, 360K GB-seconds, 180K vCPU-seconds
   - Cloud Build: 120 build-minutes/day
   - Artifact Registry: 0.5 GB storage free
   - Secret Manager: 6 active secret versions free
   - Cloud Storage (if used): 5 GB, 1 GB egress/month
   - Firestore (if used): 1 GB, 50K reads/day, 20K writes/day
   - Budget alert: emails you if spend approaches $1 (should never happen)

8. **After deploy — useful commands**
   ```bash
   # View live logs
   gcloud run logs read APP_NAME --region=us-central1 --project=PROJECT_ID

   # Check service status and URL
   gcloud run services describe APP_NAME --region=us-central1 --project=PROJECT_ID

   # Redeploy after code changes
   ./deploy.sh

   # Delete everything (stop all billing)
   gcloud run services delete APP_NAME --region=us-central1 --project=PROJECT_ID
   ```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FINAL RULES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- Scan every file BEFORE writing any output file
- min-instances=0 is non-negotiable — it is what keeps the bill at $0
- Budget alert must always be in deploy.sh — no exceptions
- If project uses SQLite: add a clear warning in DEPLOY_README.md that data won't persist
- If project uses Cloud SQL / Redis / Memorystore: do NOT set them up — warn and suggest free alternatives
- Never modify any existing project file — only write the 4 output files
- Make deploy.sh runnable out-of-the-box after filling in PROJECT_ID and APP_NAME

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
    print(f"  Anchor  |  scanning: {project_path}")
    print(f"  Model   |  {model}")
    print(f"{'━'*60}\n")

    messages = [{"role": "user", "content": build_prompt(project_path)}]
    files_written: list[str] = []

    for turn in range(1, MAX_TURNS + 1):
        print(f"[{turn:02d}] Calling {model}...", end=" ", flush=True)

        response = litellm.completion(
            model=model,
            messages=messages,
            tools=TOOLS,
            tool_choice="auto",
            max_tokens=4096,
        )

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

        # No tool calls → agent finished
        if not msg.tool_calls:
            print("done (no more tools).")
            break

        print(f"{len(msg.tool_calls)} tool call(s)")

        # Execute each tool call
        for tc in msg.tool_calls:
            name = tc.function.name
            try:
                args = json.loads(tc.function.arguments)
            except (json.JSONDecodeError, TypeError):
                args = {}

            # Log what the agent is doing
            if name == "list_directory":
                rec = " (recursive)" if args.get("recursive") else ""
                print(f"     📂  list_directory: {args.get('path', '')}{rec}")
            elif name == "read_file":
                print(f"     📄  read_file: {args.get('path', '')}")
            elif name == "write_file":
                fpath = args.get("path", "")
                print(f"     ✍️   write_file: {fpath}")
                if Path(fpath).name in OUTPUT_FILES:
                    files_written.append(fpath)

            result = execute_tool(name, args)

            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": result,
            })
    else:
        print(f"\n⚠️  Reached max turns ({MAX_TURNS}). Output may be incomplete.")

    # ── Summary ──────────────────────────────────────────────────────────────
    print(f"\n{'━'*60}")
    if files_written:
        print(f"✅  Anchor complete! {len(files_written)} file(s) generated:\n")
        for f in sorted(set(files_written)):
            print(f"    {f}")
        print(f"""
Next steps:
  1. Open deploy.sh → fill in PROJECT_ID and APP_NAME
  2. Export your secret values (see DEPLOY_README.md)
  3. Run: cd {project_path} && ./deploy.sh

Full instructions: {project_path}/DEPLOY_README.md
""")
    else:
        print("⚠️  No output files were written. See agent output above for details.")
    print("━"*60 + "\n")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="anchor",
        description="Anchor — scan any project and deploy to Google Cloud Run for free",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
examples:
  python anchor.py --project ./my-fastapi-app
  python anchor.py --project ~/projects/my-node-app --model gpt-4o
  ANCHOR_MODEL=gemini/gemini-2.0-flash python anchor.py --project ./app

supported models (via LiteLLM):
  claude-sonnet-4-6         (default, recommended)
  claude-haiku-4-5          (faster, cheaper)
  gpt-4o                    (OpenAI — needs OPENAI_API_KEY)
  gemini/gemini-2.0-flash   (Google — needs GEMINI_API_KEY)
  any model supported by LiteLLM
        """,
    )
    parser.add_argument(
        "--project",
        required=True,
        metavar="PATH",
        help="Path to the project directory to scan",
    )
    parser.add_argument(
        "--model",
        default=os.getenv("ANCHOR_MODEL", DEFAULT_MODEL),
        metavar="MODEL",
        help=f"LLM model to use (default: {DEFAULT_MODEL}). Override with ANCHOR_MODEL env var.",
    )
    args = parser.parse_args()

    project_path = str(Path(args.project).resolve())
    if not Path(project_path).is_dir():
        print(f"Error: '{args.project}' is not a valid directory.")
        sys.exit(1)

    run_agent(project_path, args.model)


if __name__ == "__main__":
    main()
