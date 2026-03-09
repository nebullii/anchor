# Anchor – Development Guide for Claude

This document defines the mission, architecture, and development rules for the Anchor project.

Claude must read and follow this file before generating any code.

---

# Mission

Google Cloud provides extremely powerful infrastructure with generous free tiers, including:

- Cloud Run
- Cloud Build
- Artifact Registry
- Cloud Storage
- Secret Manager

However, deploying applications on Google Cloud is unnecessarily complex.

Developers must manually configure multiple services and understand infrastructure details.

Anchor exists to remove this friction.

Anchor converts a GitHub repository into a working Google Cloud deployment automatically.

The user experience should be:

Connect GitHub → Analyze repository → Configure environment variables → Deploy.

Anchor orchestrates Google Cloud services so developers can deploy applications without learning the entire GCP ecosystem.

Anchor does NOT replace Google Cloud.

Anchor makes Google Cloud simple.

---

# Core Product Workflow

Deployment flow:

1. User signs in with GitHub
2. User connects their Google Cloud account
3. User selects a repository
4. Anchor analyzes the repository
5. Anchor generates infrastructure configuration
6. User provides required environment variables
7. Anchor builds and deploys the application

Anchor automatically performs:

- framework detection
- Dockerfile generation
- dependency detection
- environment variable detection
- database detection
- CI/CD pipeline creation
- container image build
- artifact storage
- Cloud Run deployment
- log streaming

The final result is a running application URL from Cloud Run.

---

# Technology Stack

Anchor is intentionally built as a Rails monolith.

Claude must NOT suggest rewriting the application to React, Next.js, or microservices.

Backend:

Ruby on Rails  
PostgreSQL  

Frontend:

Hotwire (Turbo + Stimulus)  
TailwindCSS  

Background Jobs:

Sidekiq  
Redis  

Cloud Infrastructure:

Google Cloud Run  
Cloud Build  
Artifact Registry  
Secret Manager  
Cloud Storage  

Realtime Logs:

ActionCable  

Authentication:

GitHub OAuth

---

# Architecture Principles

Anchor must remain:

Simple  
Developer-focused  
Product-driven  
Operationally reliable  

Rules:

1. Prefer Rails conventions.
2. Avoid unnecessary abstractions.
3. Keep the system as a Rails monolith.
4. Use Sidekiq for long-running jobs.
5. Use ActionCable for streaming logs.
6. Business logic should live in service objects.
7. Infrastructure orchestration should remain simple.

---

# Supported Frameworks

Anchor must detect and support the following project types:

Rails  
FastAPI  
Flask  
Node.js  
Static sites  
Docker-based repositories  

Detection signals include:

Gemfile  
package.json  
requirements.txt  
Dockerfile  
framework configuration files  

Claude should improve framework detection logic when necessary.

---

# Repository Analysis (AI System)

Anchor includes an AI-powered repository analysis engine.

The AI system is responsible for:

- analyzing repository structure
- detecting frameworks
- detecting runtime
- detecting application port
- detecting required dependencies
- detecting required environment variables
- detecting database usage
- generating Dockerfile
- suggesting deployment fixes

The analysis engine must read the entire repository before deployment.

---

# Dockerfile Generation

If a repository does not include a Dockerfile, Anchor must generate one automatically.

Dockerfile generation should be based on:

- detected framework
- runtime requirements
- dependency manager
- application port

Claude should design Dockerfile templates for each supported framework.

---

# CI/CD Pipeline

Anchor must always create a CI/CD pipeline automatically.

CI/CD is implemented using:

Google Cloud Build

Deployment pipeline:

1. Clone repository
2. Generate Dockerfile if needed
3. Build container using Cloud Build
4. Push image to Artifact Registry
5. Deploy service to Cloud Run

Claude must never replace Cloud Build with a custom CI/CD system.

---

# Deployment Target

Anchor currently supports only:

Google Cloud Run

Claude must not introduce Kubernetes or other deployment targets.

Cloud Run is sufficient for:

backend APIs  
AI services  
web applications  

---

# Google Cloud Resource Management

Anchor automatically creates required resources in the user's Google Cloud project.

Resources include:

Artifact Registry repositories  
Cloud Run services  
Secret Manager secrets  
Cloud Storage buckets  

Claude should design resource provisioning logic that is idempotent and safe.

---

# Database Detection and Setup

Anchor should detect database usage in the repository.

Examples:

PostgreSQL  
MySQL  
SQLite  

When detected, Anchor should automatically provision a compatible managed database in Google Cloud.

Examples:

Cloud SQL PostgreSQL  
Cloud SQL MySQL  

The connection string should be injected via Secret Manager.

---

# Secrets Management

Environment variables must always be stored in:

Google Secret Manager

Users must manually confirm and provide values before deployment.

Secrets should never be stored directly in the Anchor database.

---

# Environment Variable Detection

The analysis engine should detect environment variables used in the repository.

Examples:

DATABASE_URL  
REDIS_URL  
OPENAI_API_KEY  
STRIPE_SECRET_KEY  

Anchor should prompt the user to supply values before deployment.

---

# Port Detection

Cloud Run requires services to listen on PORT=8080.

Anchor must detect application ports automatically.

Examples:

Rails → 3000  
FastAPI → 8000  
Node → 3000  

Docker configuration should map the detected port to Cloud Run requirements.

---

# Storage Support

Anchor should support attaching Google Cloud Storage buckets to applications.

If the repository requires file storage, Anchor should create a bucket and expose its configuration through environment variables.

---

# Logging

Anchor must provide live deployment logs.

Logs should include:

Cloud Build logs  
deployment status  
Cloud Run service status  

Logs should stream in real time using ActionCable.

The UI must show:

build progress  
resource creation  
deployment completion  

---

# User Interface Requirements

Anchor UI should include:

Dashboard  
Project page  
Deployment history  
Deployment logs  
Environment variable management  

UX principles:

Minimal  
Professional  
Fast  

Hotwire should be used for interactive updates.

Avoid heavy frontend frameworks.

---

# Deployment States

Deployments should include the following states:

pending  
analyzing  
building  
deploying  
succeeded  
failed  

Deployment state should be persisted in the database.

---

# Development Rules

Claude must:

Follow Rails conventions  
Keep controllers thin  
Use service objects for infrastructure orchestration  
Use Sidekiq for background jobs  
Write clear migrations  

Avoid:

microservices  
unnecessary abstraction layers  
complex frameworks  

---

# AI Responsibilities

AI plays a central role in Anchor.

The AI system must perform:

repository analysis  
Dockerfile generation  
dependency detection  
environment variable detection  
database detection  
deployment troubleshooting  

AI should assist developers in deploying applications successfully.

---

# Execution Workflow for Claude

When implementing features Claude must:

1. Check this CLAUDE.md file
2. Ensure the feature aligns with product mission
3. Propose minimal architecture
4. Follow Rails conventions
5. Generate production-ready code

Claude should prioritize:

simplicity  
developer experience  
fast iteration  

---

# Product Goal

Anchor should become:

The easiest way to deploy applications to Google Cloud.

Every architectural decision must support this goal.