# Anchor

> Point it at any project. Get a live URL on Google Cloud. Free.

Anchor is an AI agent that scans your project, figures out your stack, detects all your secrets, and writes everything needed to deploy to Google Cloud Run — a `Dockerfile`, a `deploy.sh` script, and step-by-step instructions tailored to your app.

**You will not be charged.** Anchor enforces Google Cloud's free tier and adds a budget alert as a safety net.

---

## What Anchor generates

After running Anchor on your project, you get 5 new files inside your project folder:

| File | What it is |
|------|-----------|
| `Dockerfile` | Packages your app into a container |
| `deploy.sh` | Runs the first deploy + sets up CI/CD from your terminal |
| `.gcloudignore` | Tells Google what NOT to upload (secrets, venvs, etc.) |
| `.github/workflows/deploy.yml` | Auto-deploys every time you push to `main` |
| `DEPLOY_README.md` | Step-by-step instructions specific to your project |

---

## Before you start — install these once

### 1. Python 3.10 or newer
Check if you have it:
```bash
python3 --version
```
If not, download from [python.org](https://www.python.org/downloads/)

---

### 2. Google Cloud CLI (`gcloud`)

**Mac:**
```bash
brew install google-cloud-sdk
```

**Windows / Linux:** Download the installer at [cloud.google.com/sdk/docs/install](https://cloud.google.com/sdk/docs/install)

After installing, run this once:
```bash
gcloud init
```
It will open a browser, ask you to sign in with your Google account, and create or select a project.

---

### 3. A free Google Cloud account

Go to [console.cloud.google.com](https://console.cloud.google.com) and sign in with any Google account.

Create a new project (top-left dropdown → "New Project"). Give it any name.

Your **Project ID** is shown under the project name — it looks like `my-app-123456`. You'll need this later.

> No credit card required for Cloud Run free tier usage.

---

### 4. An AI API key (pick one)

Anchor uses an AI model to read and understand your project. Pick any one:

| Provider | Get your key | Environment variable |
|----------|-------------|---------------------|
| **Anthropic Claude** (default, recommended) | [console.anthropic.com](https://console.anthropic.com) | `ANTHROPIC_API_KEY` |
| OpenAI GPT-4o | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) | `OPENAI_API_KEY` |
| Google Gemini | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | `GEMINI_API_KEY` |

---

## Setup

```bash
# Clone or download Anchor
cd anchor

# Install the one dependency
pip install -r requirements.txt

# Set your API key (paste your actual key)
export ANTHROPIC_API_KEY="sk-ant-..."
```

---

## Run Anchor on your project

```bash
python anchor.py --project /path/to/your/project
```

**Examples:**
```bash
python anchor.py --project ./my-fastapi-app
python anchor.py --project ~/projects/my-node-app
python anchor.py --project /Users/yourname/hackathon/backend
```

Anchor will print what it's doing as it scans:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Anchor  |  scanning: /path/to/your/project
  Model   |  claude-sonnet-4-6
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[01] Calling claude-sonnet-4-6... 2 tool call(s)
     📂  list_directory: /path/to/your/project (recursive)
     📄  read_file: /path/to/your/project/requirements.txt
     📄  read_file: /path/to/your/project/main.py
     📄  read_file: /path/to/your/project/.env.example
     ✍️   write_file: /path/to/your/project/Dockerfile
     ✍️   write_file: /path/to/your/project/deploy.sh
     ...

✅  Anchor complete! 4 file(s) generated.
```

---

## Deploy your app

Once Anchor finishes, open the generated `deploy.sh` in your project:

```bash
cd your-project
open deploy.sh   # or use any text editor
```

**Fill in these 2 lines at the top:**
```bash
PROJECT_ID="your-gcloud-project-id"   # ← paste your Project ID here
APP_NAME="my-app"                      # ← pick any name (lowercase, hyphens only)
```

> Find your Project ID: run `gcloud projects list` in your terminal, or check [console.cloud.google.com](https://console.cloud.google.com) top-left dropdown.

**Set your secrets** (if your app uses API keys, DB passwords, etc.):

The `deploy.sh` file will have commented lines like this near the top:
```bash
# export OPENAI_API_KEY=""
# export DATABASE_URL=""
```

Uncomment them and fill in your values:
```bash
export OPENAI_API_KEY="sk-..."
export DATABASE_URL="postgres://..."
```

**Run the deploy:**
```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. Enable the required Google Cloud services
2. Set up a $1 budget alert (emails you if something goes wrong — should never fire)
3. Upload your secrets securely to Secret Manager
4. Build your container in the cloud
5. Deploy to Cloud Run
6. Print your live URL

The whole thing takes about 3–5 minutes.

---

## After deploying

### Set up CI/CD (auto-deploy on push)

After `./deploy.sh` finishes, it prints instructions to connect GitHub Actions:

1. It generates a `cicd-key.json` service account key — copy its contents
2. Go to your GitHub repo → **Settings → Secrets and variables → Actions**
3. Add a **secret**: `GCP_SA_KEY` = paste the full contents of `cicd-key.json`
4. Add **variables**: `GCP_PROJECT_ID`, `GCP_APP_NAME`, `GCP_REGION`
5. Delete the key file: `rm cicd-key.json`

From now on, every `git push` to `main` auto-deploys via `.github/workflows/deploy.yml`.

---

### Useful commands

```bash
# See your live URL
gcloud run services describe APP_NAME --region=us-central1 --project=PROJECT_ID --format="value(status.url)"

# Watch live logs
gcloud run logs read APP_NAME --region=us-central1 --project=PROJECT_ID

# Manual redeploy (CI/CD handles this automatically after setup)
./deploy.sh

# Take it down completely
gcloud run services delete APP_NAME --region=us-central1 --project=PROJECT_ID
```

---

## Using a different AI model

By default Anchor uses Claude. To switch:

```bash
# Use GPT-4o (needs OPENAI_API_KEY)
python anchor.py --project ./my-app --model gpt-4o

# Use Gemini (needs GEMINI_API_KEY)
python anchor.py --project ./my-app --model gemini/gemini-2.0-flash

# Use a cheaper/faster Claude model
python anchor.py --project ./my-app --model claude-haiku-4-5

# Set a default model so you don't have to type it every time
export ANCHOR_MODEL=gpt-4o
python anchor.py --project ./my-app
```

---

## What's free and what are the limits

Anchor deploys to Google Cloud Run, which has a permanent free tier (not a trial):

| Service | Free limit |
|---------|-----------|
| Cloud Run requests | 2 million / month |
| Cloud Run compute | 360,000 GB-seconds / month |
| Cloud Build | 120 build-minutes / day |
| Artifact Registry | 0.5 GB storage |
| Secret Manager | 6 active secret versions |
| Cloud Storage (if your app needs file storage) | 5 GB + 1 GB egress / month |
| Firestore (if your app needs a database) | 1 GB + 50,000 reads/day |

Most apps at hackathon / side-project scale stay well within these limits.

The `deploy.sh` includes a **$1 budget alert** — Google will email you before any charges occur. In normal free-tier usage, this alert never fires.

---

## What if my app uses a database?

Anchor detects what your app needs and handles it:

- **File uploads** → Anchor creates a free Cloud Storage bucket automatically
- **NoSQL / document store** → Anchor creates a free Firestore database automatically
- **PostgreSQL or MySQL** → Anchor warns you (Cloud SQL is not free) and recommends [Neon](https://neon.tech) — a free serverless Postgres that works with Cloud Run
- **Redis** → Anchor warns you (Google Memorystore is not free) and recommends [Upstash](https://upstash.com) — a free Redis that works with Cloud Run
- **SQLite** → Anchor warns you that SQLite files are lost on restart in Cloud Run, and suggests migrating to Firestore

---

## Troubleshooting

**`gcloud: command not found`**
The gcloud CLI isn't installed or isn't in your PATH. Follow the install steps above and restart your terminal.

**`ERROR: (gcloud.run.deploy) PERMISSION_DENIED`**
Run `gcloud auth login` and make sure you're using the account that owns the project.

**`ERROR: Project ID not found`**
Replace `"your-gcloud-project-id"` in `deploy.sh` with your actual project ID. Run `gcloud projects list` to find it.

**`ERROR: export MY_SECRET before running`**
You need to `export` your secret values in your terminal before running `deploy.sh`. See the "Set your secrets" step above.

**`deploy.sh: Permission denied`**
Run `chmod +x deploy.sh` first, then `./deploy.sh`.

**The deploy succeeds but my app crashes**
Check the logs: `gcloud run logs read APP_NAME --region=us-central1 --project=PROJECT_ID`
Most common causes: wrong start command, missing env var, wrong port.

---

## Full example: deploying a FastAPI app

```
my-api/
  main.py
  requirements.txt
  .env
```

```bash
# Step 1: Run Anchor
export ANTHROPIC_API_KEY="sk-ant-..."
python anchor.py --project ./my-api

# Step 2: Edit deploy.sh
#   PROJECT_ID="my-project-123456"
#   APP_NAME="my-api"
#   export OPENAI_API_KEY="sk-..."   ← if your app uses it

# Step 3: Deploy
cd my-api
chmod +x deploy.sh
./deploy.sh

# Output:
# ✅ Deployed! Your app is live at:
# https://my-api-abc123-uc.a.run.app
```

---

## Requirements

- Python 3.10+
- `pip install -r requirements.txt` (just installs `litellm`)
- gcloud CLI installed and authenticated
- One AI API key (Anthropic, OpenAI, or Google)
