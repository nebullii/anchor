# Anchor

> One command. Your app is live on Google Cloud. Free.

Anchor is an AI agent that scans any project, figures out the stack, collects your secrets safely, and fully deploys to Google Cloud Run — no manual steps, no config files to fill in.

**The only thing you provide is your LLM API key.**

---

## How it works

```
python anchor.py --project ./my-app
```

Anchor then:

1. **Scans** every file in your project (stack, entry point, port, secrets, storage needs)
2. **Generates** `Dockerfile`, `.gcloudignore`, `deploy.sh`, GitHub Actions workflow
3. **Checks gcloud** — if you're not logged in, it opens the browser for you
4. **Asks you** to pick a project and name your app (two quick prompts)
5. **Creates** a `.env.anchor` file listing every secret your app needs → you fill in the values
6. **Pushes secrets** directly to GCloud Secret Manager — values never go through the LLM
7. **Builds and deploys** your container to Cloud Run
8. **Sets up CI/CD** — every future `git push` to main auto-deploys
9. **Prints your live URL**

---

## Install

```bash
git clone https://github.com/nebullii/anchor
cd anchor
pip install -r requirements.txt
```

Set your LLM API key (pick one):

```bash
export ANTHROPIC_API_KEY="sk-ant-..."   # Claude — default, recommended
export OPENAI_API_KEY="sk-..."          # GPT-4o
export GEMINI_API_KEY="..."             # Gemini
```

---

## Run

```bash
python anchor.py --project /path/to/your/app
```

That's it. Anchor handles the rest interactively.

**Example session:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Anchor  |  project: /Users/you/my-app
  Model   |  claude-sonnet-4-6
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[01] Thinking... 2 action(s)
     📂  list_directory: /Users/you/my-app (recursive)
     📄  read_file: requirements.txt
     📄  read_file: main.py
     📄  read_file: .env.example
     ✍️   write_file: Dockerfile
     ✍️   write_file: .gcloudignore
     ✍️   write_file: .github/workflows/deploy.yml
     ✍️   write_file: deploy.sh
     $ gcloud auth list ...
     $ gcloud projects list ...

──────────────────────────────────────────
  Anchor needs input:
  Enter your Project ID from the list above: my-project-123
──────────────────────────────────────────

  Anchor needs input:
  What should your app be called? (e.g. my-app): my-fastapi-app
──────────────────────────────────────────

     ✍️   write_file: .env.anchor

──────────────────────────────────────────
  Anchor needs input:
  Secrets template ready at .env.anchor — open it, fill in values, save, then press Enter:
──────────────────────────────────────────

     🔐  push_secrets: .env.anchor → Secret Manager
     $ gcloud builds submit ...
     $ gcloud run deploy ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  YOUR APP IS LIVE AT: https://my-fastapi-app-abc123-uc.a.run.app

CI/CD is set up. Every git push to main will auto-deploy.
Add these to GitHub → Settings → Secrets and Variables → Actions:
  Secret:   GCP_SA_KEY     = <contents of cicd-key.json>
  Variable: GCP_PROJECT_ID = my-project-123
  Variable: GCP_APP_NAME   = my-fastapi-app
  Variable: GCP_REGION     = us-central1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## About secrets

Anchor writes a `.env.anchor` file listing every secret your app needs:

```
# Anchor secrets — fill in values then save.
# This file stays local (never committed or deployed).
OPENAI_API_KEY=
DATABASE_URL=
```

You fill in the values. Anchor reads the file and pushes each secret **directly to GCloud Secret Manager** — the values never go through the LLM. The file stays on your machine (it's in `.gcloudignore` and `.gitignore`).

---

## What's free

| Service | Free limit |
|---------|-----------|
| Cloud Run | 2M requests/month, scales to zero |
| Cloud Build | 120 build-minutes/day |
| Artifact Registry | 0.5 GB |
| Secret Manager | 6 active secret versions |
| Cloud Storage (if needed) | 5 GB + 1 GB egress/month |
| Firestore (if needed) | 1 GB + 50K reads/day |

Anchor always sets `--min-instances=0` (scale to zero = no idle cost) and adds a $1 budget alert as a safety net.

---

## Change the AI model

```bash
# GPT-4o
python anchor.py --project ./my-app --model gpt-4o

# Gemini
python anchor.py --project ./my-app --model gemini/gemini-2.0-flash

# Faster/cheaper Claude
python anchor.py --project ./my-app --model claude-haiku-4-5

# Set a default
export ANCHOR_MODEL=gpt-4o
```

---

## Prerequisites

- Python 3.10+
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) — `brew install google-cloud-sdk`
- A Google Cloud account (free tier, no credit card required)
- One LLM API key
