# Google Cloud Setup (Beginner-Friendly)

Anchor can deploy any app to Google Cloud Run, but Google requires a few one-time setup steps.

This guide is the simplest, low-jargon path if you’re new to cloud tools.

---

## 1. Create a Google Cloud account

1. Go to Google Cloud Console in your browser.
2. Sign in with your Google account.

---

## 2. Create a billing account (required by Google)

Google requires a billing account even for free-tier services.

1. In the Cloud Console, search for **Billing**.
2. Click **Create billing account**.
3. Add a payment method.

You are not charged unless you exceed free-tier limits.

---

## 3. Install the Google Cloud CLI

The Cloud CLI is the tool Anchor uses to deploy your app.

Mac:
```bash
brew install google-cloud-sdk
```

Windows:
- Download the installer from the official Google Cloud CLI page.

Linux:
- Follow the official Google Cloud CLI install guide for your distro.

---

## 4. Sign in from your terminal

```bash
gcloud auth login
```

This opens a browser window where you sign in.

---

## 5. Create a project

In the Cloud Console:
1. Click the project dropdown (top left).
2. Click **New Project**.
3. Give it a name and create it.

---

## 6. Link billing to your project

In the Cloud Console:
1. Go to **Billing**.
2. Select your billing account.
3. Link it to your new project.

---

## 7. Run Anchor

```bash
python anchor.py --project /path/to/your/app
```

Anchor will ask you for:
- Project ID
- App name
- Secrets (in a local `.env.anchor` file)

It will then deploy the app and print a live URL.

---

## Optional: Use the helper script

Anchor includes a script that checks if `gcloud` is installed and signed in:

```bash
bash scripts/setup_gcloud.sh
```

