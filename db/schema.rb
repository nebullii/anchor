# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_03_16_235712) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "deployment_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "deployment_id", null: false
    t.string "event_type", null: false
    t.string "from_status"
    t.jsonb "metadata", default: {}
    t.datetime "occurred_at", null: false
    t.string "to_status"
    t.datetime "updated_at", null: false
    t.index ["deployment_id", "occurred_at"], name: "index_deployment_events_on_deployment_id_and_occurred_at"
    t.index ["deployment_id"], name: "index_deployment_events_on_deployment_id"
    t.index ["event_type"], name: "index_deployment_events_on_event_type"
  end

  create_table "deployment_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "deployment_id", null: false
    t.string "level", default: "info", null: false
    t.datetime "logged_at", null: false
    t.text "message", null: false
    t.string "source", default: "system"
    t.datetime "updated_at", null: false
    t.index ["deployment_id", "logged_at"], name: "index_deployment_logs_on_deployment_id_and_logged_at"
    t.index ["deployment_id"], name: "index_deployment_logs_on_deployment_id"
    t.index ["level"], name: "index_deployment_logs_on_level"
    t.index ["logged_at"], name: "index_deployment_logs_on_logged_at"
  end

  create_table "deployments", force: :cascade do |t|
    t.text "ai_error_explanation"
    t.string "branch"
    t.string "cloud_build_id"
    t.string "cloud_build_log_url"
    t.string "commit_author"
    t.text "commit_message"
    t.string "commit_sha"
    t.datetime "created_at", null: false
    t.jsonb "deployment_plan"
    t.string "error_category"
    t.text "error_message"
    t.datetime "finished_at"
    t.string "image_url"
    t.bigint "project_id", null: false
    t.string "service_url"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.string "triggered_by", default: "manual"
    t.datetime "updated_at", null: false
    t.index ["cloud_build_id"], name: "index_deployments_on_cloud_build_id"
    t.index ["commit_sha"], name: "index_deployments_on_commit_sha"
    t.index ["created_at"], name: "index_deployments_on_created_at"
    t.index ["error_category"], name: "index_deployments_on_error_category"
    t.index ["project_id", "status"], name: "index_deployments_on_project_id_and_status"
    t.index ["project_id"], name: "index_deployments_on_project_id"
    t.index ["project_id"], name: "index_deployments_one_active_per_project", unique: true, where: "((status)::text <> ALL (ARRAY[('running'::character varying)::text, ('success'::character varying)::text, ('failed'::character varying)::text, ('cancelled'::character varying)::text]))"
    t.index ["status"], name: "index_deployments_on_status"
    t.index ["triggered_by"], name: "index_deployments_on_triggered_by"
  end

  create_table "projects", force: :cascade do |t|
    t.jsonb "analysis_result"
    t.string "analysis_status", default: "pending", null: false
    t.datetime "analyzed_at"
    t.boolean "auto_deploy", default: false, null: false
    t.datetime "cicd_committed_at"
    t.jsonb "cicd_files", default: []
    t.text "cicd_setup_error"
    t.string "cicd_setup_status", default: "none", null: false
    t.datetime "created_at", null: false
    t.string "framework"
    t.string "gcp_project_id", null: false
    t.text "gcp_provision_error"
    t.boolean "gcp_provisioned", default: false, null: false
    t.datetime "gcp_provisioned_at"
    t.string "gcp_region", default: "us-central1", null: false
    t.string "latest_url"
    t.string "name", null: false
    t.integer "port"
    t.string "production_branch", default: "main"
    t.bigint "repository_id", null: false
    t.string "runtime"
    t.string "service_name"
    t.string "slug", null: false
    t.string "status", default: "inactive", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "webhook_secret"
    t.index ["analysis_status"], name: "index_projects_on_analysis_status"
    t.index ["gcp_project_id"], name: "index_projects_on_gcp_project_id"
    t.index ["gcp_provisioned"], name: "index_projects_on_gcp_provisioned"
    t.index ["repository_id"], name: "index_projects_on_repository_id"
    t.index ["service_name"], name: "index_projects_on_service_name"
    t.index ["slug"], name: "index_projects_on_slug", unique: true
    t.index ["status"], name: "index_projects_on_status"
    t.index ["user_id", "name"], name: "index_projects_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_projects_on_user_id"
  end

  create_table "repositories", force: :cascade do |t|
    t.string "clone_url", null: false
    t.datetime "created_at", null: false
    t.string "default_branch", default: "main"
    t.text "description"
    t.string "full_name", null: false
    t.string "github_id", null: false
    t.string "html_url", null: false
    t.string "language"
    t.datetime "last_synced_at"
    t.string "name", null: false
    t.string "owner_login", null: false
    t.boolean "private", default: false, null: false
    t.integer "size_kb"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["full_name"], name: "index_repositories_on_full_name", unique: true
    t.index ["github_id"], name: "index_repositories_on_github_id", unique: true
    t.index ["last_synced_at"], name: "index_repositories_on_last_synced_at"
    t.index ["owner_login"], name: "index_repositories_on_owner_login"
    t.index ["user_id"], name: "index_repositories_on_user_id"
  end

  create_table "secrets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "encrypted_value", null: false
    t.string "encrypted_value_iv", null: false
    t.string "key", null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "key"], name: "index_secrets_on_project_id_and_key", unique: true
    t.index ["project_id"], name: "index_secrets_on_project_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.string "default_gcp_project_id"
    t.string "default_gcp_region", default: "us-central1"
    t.integer "deployments_this_month", default: 0, null: false
    t.integer "deployments_today", default: 0, null: false
    t.string "email"
    t.text "encrypted_gcp_service_account_key"
    t.string "encrypted_gcp_service_account_key_iv"
    t.string "encrypted_github_token", null: false
    t.string "encrypted_github_token_iv"
    t.text "encrypted_google_access_token"
    t.string "encrypted_google_access_token_iv"
    t.text "encrypted_google_refresh_token"
    t.string "encrypted_google_refresh_token_iv"
    t.string "gcp_service_account_email"
    t.string "github_id", null: false
    t.string "github_login", null: false
    t.string "google_email"
    t.datetime "google_token_expires_at"
    t.string "name"
    t.datetime "quota_reset_at"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email"
    t.index ["github_id"], name: "index_users_on_github_id", unique: true
    t.index ["github_login"], name: "index_users_on_github_login", unique: true
  end

  add_foreign_key "deployment_events", "deployments"
  add_foreign_key "deployment_logs", "deployments"
  add_foreign_key "deployments", "projects"
  add_foreign_key "projects", "repositories"
  add_foreign_key "projects", "users"
  add_foreign_key "repositories", "users"
  add_foreign_key "secrets", "projects"
end
