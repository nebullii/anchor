package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func assertContains(t *testing.T, haystack, needle string) {
	t.Helper()
	if !strings.Contains(haystack, needle) {
		t.Fatalf("expected output to contain %q, got:\n%s", needle, haystack)
	}
}

func assertExit(t *testing.T, ta *testApp, got, want int) {
	t.Helper()
	if got != want {
		t.Fatalf("exit code = %d, want %d\nstdout:\n%s\nstderr:\n%s", got, want, ta.out, ta.errOut)
	}
}

// ------------------------------------------------------------------ //
// Basics                                                               //
// ------------------------------------------------------------------ //

func TestVersion(t *testing.T) {
	ta := newTestApp(t, nil)
	assertExit(t, ta, ta.run("--version"), 0)
	assertContains(t, ta.out.String(), "anchor "+Version)
}

func TestHelpAndUnknownCommand(t *testing.T) {
	ta := newTestApp(t, nil)
	assertExit(t, ta, ta.run("--help"), 0)
	assertContains(t, ta.out.String(), "deploy")

	ta = newTestApp(t, nil)
	assertExit(t, ta, ta.run("deploi"), ExitUsage)
	assertContains(t, ta.errOut.String(), `unknown command "deploi"`)

	ta = newTestApp(t, nil)
	assertExit(t, ta, ta.run("deploy", "--help"), 0)
	assertContains(t, ta.out.String(), "--follow")
}

func TestUnknownFlagIsUsageError(t *testing.T) {
	ta := newTestApp(t, newFakeAnchor(t))
	assertExit(t, ta, ta.run("projects", "--bogus"), ExitUsage)
	assertContains(t, ta.errOut.String(), "unknown flag --bogus")
}

func TestNotLoggedIn(t *testing.T) {
	ta := newTestApp(t, nil)
	assertExit(t, ta, ta.run("projects"), ExitFailure)
	assertContains(t, ta.errOut.String(), "not logged in")
}

func TestConnectionErrorHint(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	f.srv.Close()
	assertExit(t, ta, ta.run("projects"), ExitFailure)
	assertContains(t, ta.errOut.String(), "could not reach Anchor")
	assertContains(t, ta.errOut.String(), "ANCHOR_URL")
}

func TestUnauthorizedHint(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	ta.env["ANCHOR_TOKEN"] = "anc_revoked"
	assertExit(t, ta, ta.run("projects"), ExitFailure)
	assertContains(t, ta.errOut.String(), "invalid or has been revoked")
	assertContains(t, ta.errOut.String(), "anchor login")
}

// ------------------------------------------------------------------ //
// Login / config                                                       //
// ------------------------------------------------------------------ //

func TestLoginSavesConfigWith0600(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	delete(ta.env, "ANCHOR_TOKEN")
	delete(ta.env, "ANCHOR_URL")
	ta.Stdin = strings.NewReader(testToken + "\n")

	assertExit(t, ta, ta.run("login", "--url", f.srv.URL+"/"), 0)
	assertContains(t, ta.out.String(), "as @octo")

	path := filepath.Join(ta.env["HOME"], ".config", "anchor", "config.json")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("config perms = %o, want 600", perm)
	}
	var saved Config
	data, _ := os.ReadFile(path)
	_ = json.Unmarshal(data, &saved)
	if saved.Token != testToken || saved.URL != f.srv.URL {
		t.Fatalf("saved config = %+v", saved)
	}

	// The saved token is used on the next run.
	ta2 := newTestApp(t, nil)
	ta2.env["HOME"] = ta.env["HOME"]
	assertExit(t, ta2, ta2.run("whoami"), 0)
	assertContains(t, ta2.out.String(), "@octo")

	// logout drops the token but keeps the URL.
	assertExit(t, ta2, ta2.run("logout"), 0)
	data, _ = os.ReadFile(path)
	saved = Config{}
	_ = json.Unmarshal(data, &saved)
	if saved.Token != "" || saved.URL != f.srv.URL {
		t.Fatalf("after logout config = %+v", saved)
	}
}

func TestLoginRejectsInvalidToken(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	delete(ta.env, "ANCHOR_TOKEN")

	assertExit(t, ta, ta.run("login", "--token", "anc_wrong"), ExitFailure)
	assertContains(t, ta.errOut.String(), "revoked")
	if _, err := os.Stat(filepath.Join(ta.env["HOME"], ".config", "anchor", "config.json")); err == nil {
		t.Fatal("config should not be written for a rejected token")
	}

	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("login", "--token", "ghp_notanchor"), ExitFailure)
	assertContains(t, ta.errOut.String(), `start with "anc_"`)
}

func TestEnvOverridesConfigFile(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	path := filepath.Join(ta.env["HOME"], ".config", "anchor", "config.json")
	if err := saveConfig(path, Config{URL: "http://127.0.0.1:1", Token: "anc_fromfile"}); err != nil {
		t.Fatal(err)
	}
	assertExit(t, ta, ta.run("whoami"), 0)
	if got := f.auth[len(f.auth)-1]; got != "Bearer "+testToken {
		t.Fatalf("Authorization = %q, want env token", got)
	}
}

// ------------------------------------------------------------------ //
// Projects / status                                                    //
// ------------------------------------------------------------------ //

func TestProjectsTableAndJSON(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("projects"), 0)
	assertContains(t, ta.out.String(), "my-app")
	assertContains(t, ta.out.String(), "acme/web")

	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("projects", "--json", "--limit", "5"), 0)
	var out struct {
		Projects []map[string]any `json:"projects"`
	}
	if err := json.Unmarshal(ta.out.Bytes(), &out); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, ta.out)
	}
	if len(out.Projects) != 2 || out.Projects[0]["slug"] != "my-app" {
		t.Fatalf("unexpected projects: %+v", out.Projects)
	}
	if !f.saw("GET /api/v1/projects?limit=5") {
		t.Fatalf("limit not sent: %v", f.requests)
	}
}

func TestStatusJSON(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("status", "my-app", "--json"), 0)
	var out map[string]any
	if err := json.Unmarshal(ta.out.Bytes(), &out); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if out["project"].(map[string]any)["slug"] != "my-app" || len(out["deployments"].([]any)) != 1 {
		t.Fatalf("unexpected status JSON: %v", out)
	}
}

// ------------------------------------------------------------------ //
// Project resolution                                                   //
// ------------------------------------------------------------------ //

func TestResolveFromLinkFileInParentDir(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	if err := os.WriteFile(filepath.Join(ta.Dir, LinkFile), []byte(`{"project":"docs"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	sub := filepath.Join(ta.Dir, "app", "models")
	_ = os.MkdirAll(sub, 0o755)
	ta.Dir = sub

	assertExit(t, ta, ta.run("status"), 0)
	assertContains(t, ta.out.String(), "Docs (docs)")
}

func TestLinkWritesFile(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("link", "My App"), 0) // resolved by name fallback
	data, _ := os.ReadFile(filepath.Join(ta.Dir, LinkFile))
	assertContains(t, string(data), `"project": "my-app"`)
}

func TestResolveFromGitRemote(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	ta.GitRemotes = func() []string { return []string{"ACME/Web"} }
	assertExit(t, ta, ta.run("status"), 0)
	assertContains(t, ta.out.String(), "My App (my-app)")
}

func TestResolveErrors(t *testing.T) {
	f := newFakeAnchor(t)

	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("status"), ExitFailure)
	assertContains(t, ta.errOut.String(), "no project given")

	ta = newTestApp(t, f)
	ta.GitRemotes = func() []string { return []string{"someone/else"} }
	assertExit(t, ta, ta.run("status"), ExitFailure)
	assertContains(t, ta.errOut.String(), "no Anchor project is connected to someone/else")

	f.projects = append(f.projects, f.projects[0])
	f.projects[2].ID, f.projects[2].Slug = 3, "my-app-staging"
	ta = newTestApp(t, f)
	ta.GitRemotes = func() []string { return []string{"acme/web"} }
	assertExit(t, ta, ta.run("status"), ExitFailure)
	assertContains(t, ta.errOut.String(), "my-app, my-app-staging")

	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("status", "nope"), ExitFailure)
	assertContains(t, ta.errOut.String(), `project "nope" not found`)
}

func TestParseGitRemote(t *testing.T) {
	cases := map[string]string{
		"https://github.com/acme/web.git":                    "acme/web",
		"https://github.com/acme/web":                        "acme/web",
		"https://x-access-token:abc@github.com/acme/web.git": "acme/web",
		"git@github.com:acme/web.git":                        "acme/web",
		"ssh://git@github.com/acme/web.git":                  "acme/web",
		"github.com:acme/web":                                "acme/web",
		"/local/path/repo":                                   "",
		"https://github.com/acme":                            "",
	}
	for in, want := range cases {
		if got := parseGitRemote(in); got != want {
			t.Errorf("parseGitRemote(%q) = %q, want %q", in, got, want)
		}
	}

	remotes := "upstream\tgit@github.com:acme/upstream.git (fetch)\norigin\thttps://github.com/me/web.git (fetch)\norigin\thttps://github.com/me/web.git (push)\n"
	got := reposFromRemoteList(remotes)
	if strings.Join(got, ",") != "me/web,acme/upstream" {
		t.Fatalf("reposFromRemoteList = %v", got)
	}
}

// ------------------------------------------------------------------ //
// Deploy / follow                                                      //
// ------------------------------------------------------------------ //

func TestDeployWithoutFollow(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("deploy", "my-app", "-b", "feature/x"), 0)
	assertContains(t, ta.out.String(), "Deployment #42 queued for my-app (branch feature/x)")
	if f.body("POST /api/v1/projects/1/deployments")["branch"] != "feature/x" {
		t.Fatalf("branch not sent: %v", f.bodies)
	}
}

func TestDeployFollowStreamsLogsAndExitsZero(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("deploy", "my-app", "--follow"), 0)

	out := ta.out.String()
	last := -1
	for _, line := range []string{"Cloning acme/web", "Building image", "Step 1/5", "Pushing image", "Deploying revision", "Health check passed"} {
		idx := strings.Index(out, line)
		if idx < 0 || idx < last {
			t.Fatalf("log %q missing or out of order:\n%s", line, out)
		}
		if strings.Count(out, line) != 1 {
			t.Fatalf("log %q printed %d times", line, strings.Count(out, line))
		}
		last = idx
	}
	assertContains(t, out, "Deployment #42 is live: https://my-app.example.run.app")
	assertContains(t, ta.errOut.String(), "building")
}

func TestDeployFollowFailureExitsOne(t *testing.T) {
	f := newFakeAnchor(t)
	f.statuses = []string{"queued", "building", "failed"}
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("deploy", "--follow", "-p", "my-app"), ExitFailure)
	assertContains(t, ta.out.String(), "Build failed: missing Gemfile.lock")
	assertContains(t, ta.out.String(), "Commit your Gemfile.lock.")
}

func TestDeployFollowCtrlCNonInteractive(t *testing.T) {
	f := newFakeAnchor(t)
	f.statuses = []string{"queued", "building"} // never finishes
	ta := newTestApp(t, f)
	f.onLogs = func(tick int) {
		if tick >= 2 {
			ta.interrupt()
		}
	}
	assertExit(t, ta, ta.run("deploy", "my-app", "-f"), ExitInterrupted)
	assertContains(t, ta.errOut.String(), "anchor cancel 42")
	if f.saw("POST /api/v1/deployments/42/cancel") {
		t.Fatal("must not cancel without confirmation")
	}
}

func TestDeployFollowCtrlCInteractiveCancels(t *testing.T) {
	f := newFakeAnchor(t)
	f.statuses = []string{"queued", "building"}
	ta := newTestApp(t, f)
	ta.StdinIsTTY = func() bool { return true }
	ta.Stdin = strings.NewReader("y\n")
	f.onLogs = func(tick int) { ta.interrupt() }

	assertExit(t, ta, ta.run("deploy", "my-app", "-f"), ExitInterrupted)
	assertContains(t, ta.errOut.String(), "Cancel deployment #42 on the server too?")
	assertContains(t, ta.errOut.String(), "Deployment #42 cancelled.")
	if !f.saw("POST /api/v1/deployments/42/cancel") {
		t.Fatalf("cancel not requested: %v", f.requests)
	}
}

func TestDeployMissingSecretsHint(t *testing.T) {
	f := newFakeAnchor(t)
	f.createError = &apiErr{422, `{"error":{"code":"missing_secrets","message":"Missing required secrets: DATABASE_URL.","missing_secrets":["DATABASE_URL"]}}`}
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("deploy", "my-app"), ExitFailure)
	assertContains(t, ta.errOut.String(), "Missing required secrets: DATABASE_URL.")
	assertContains(t, ta.errOut.String(), "anchor secrets set DATABASE_URL=...")
}

func TestDeployRateLimitedPlainErrorBody(t *testing.T) {
	f := newFakeAnchor(t)
	f.createError = &apiErr{429, `{"error":"Too many requests. Please slow down.","retry_after":300}`}
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("deploy", "my-app"), ExitFailure)
	assertContains(t, ta.errOut.String(), "Too many requests")
	assertContains(t, ta.errOut.String(), "wait a while")
}

// ------------------------------------------------------------------ //
// Logs / cancel / rollback                                             //
// ------------------------------------------------------------------ //

func TestLogsJSONPagesThroughEverything(t *testing.T) {
	f := newFakeAnchor(t)
	f.tick = 10 // everything visible
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("logs", "42", "--json"), 0)
	var out struct {
		Logs        []map[string]any `json:"logs"`
		NextAfterID int64            `json:"next_after_id"`
	}
	if err := json.Unmarshal(ta.out.Bytes(), &out); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, ta.out)
	}
	if len(out.Logs) != 6 || out.NextAfterID != 105 {
		t.Fatalf("got %d logs, next %d", len(out.Logs), out.NextAfterID)
	}
	if !f.saw("GET /api/v1/deployments/42/logs?after_id=101") {
		t.Fatalf("expected after_id paging, saw %v", f.requests)
	}
}

func TestLogsFollowNDJSON(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("logs", "#42", "-f", "--json"), 0)
	lines := strings.Split(strings.TrimSpace(ta.out.String()), "\n")
	if len(lines) != 7 { // 6 logs + final deployment
		t.Fatalf("expected 7 NDJSON lines, got %d:\n%s", len(lines), ta.out)
	}
	for _, l := range lines {
		if !json.Valid([]byte(l)) {
			t.Fatalf("invalid NDJSON line %q", l)
		}
	}
}

func TestLogsBadID(t *testing.T) {
	ta := newTestApp(t, newFakeAnchor(t))
	assertExit(t, ta, ta.run("logs", "abc"), ExitUsage)
}

func TestCancelByIDAndLatest(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("cancel", "42"), 0)
	assertContains(t, ta.out.String(), "Deployment #42 cancelled.")

	latest := f.currentDeployment()
	f.projects[0].LatestDeployment = &latest
	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("cancel", "-p", "my-app"), 0)

	latest.Status = "running"
	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("cancel", "-p", "my-app"), ExitFailure)
	assertContains(t, ta.errOut.String(), "no deployment in progress for my-app")
}

func TestRollback(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("rollback", "my-app", "--to", "7"), 0)
	assertContains(t, ta.out.String(), "Rollback started for my-app")
	if f.body("POST /api/v1/projects/1/rollback")["deployment_id"] != float64(7) {
		t.Fatalf("deployment_id not sent: %v", f.bodies)
	}

	f.rollbackStatus = 501
	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("rollback", "my-app"), ExitFailure)
	assertContains(t, ta.errOut.String(), "rollback is not available")
}

// ------------------------------------------------------------------ //
// Secrets                                                              //
// ------------------------------------------------------------------ //

func TestSecretsSetFromArgsAndStdin(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("secrets", "set", "A=1", "B=x=y", "-p", "my-app"), 0)
	assertContains(t, ta.out.String(), "Added A on my-app.")
	if f.body("PUT /api/v1/projects/1/secrets/B")["value"] != "x=y" {
		t.Fatalf("value with '=' mangled: %v", f.bodies)
	}

	ta = newTestApp(t, f)
	ta.Stdin = strings.NewReader("s3cret-from-stdin\n")
	assertExit(t, ta, ta.run("secrets", "set", "API_KEY", "-p", "my-app"), 0)
	if got := f.body("PUT /api/v1/projects/1/secrets/API_KEY")["value"]; got != "s3cret-from-stdin" {
		t.Fatalf("stdin value = %q", got)
	}
	if strings.Contains(ta.out.String(), "s3cret") {
		t.Fatal("secret value must not be echoed")
	}

	ta = newTestApp(t, f)
	ta.Stdin = strings.NewReader("again\n")
	assertExit(t, ta, ta.run("secrets", "set", "API_KEY", "-p", "my-app"), 0)
	assertContains(t, ta.out.String(), "Updated API_KEY")

	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("secrets", "set", "X", "Y", "-p", "my-app"), ExitUsage)
}

func TestSecretsListAndUnset(t *testing.T) {
	f := newFakeAnchor(t)
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("secrets", "set", "API_KEY=1", "-p", "my-app"), 0)

	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("secrets", "list", "-p", "my-app", "--json"), 0)
	assertContains(t, ta.out.String(), `"key": "API_KEY"`)

	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("secrets", "unset", "API_KEY", "-p", "my-app"), 0)
	assertContains(t, ta.out.String(), "Removed API_KEY")

	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("secrets", "unset", "API_KEY", "-p", "my-app"), ExitFailure)
	assertContains(t, ta.errOut.String(), "API_KEY: Resource not found.")

	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("secrets"), ExitUsage)
}

// ------------------------------------------------------------------ //
// Doctor                                                               //
// ------------------------------------------------------------------ //

func TestDoctorReportsPreflightAndMissingSecrets(t *testing.T) {
	f := newFakeAnchor(t)
	f.analysis[1] = map[string]any{
		"status": "complete", "framework": "rails",
		"preflight": []map[string]any{
			{"id": "port", "severity": "error", "message": "App does not listen on $PORT", "file": "config/puma.rb", "line": 12, "fix": "Use ENV['PORT']"},
			{"id": "lock", "severity": "warning", "message": "No lockfile"},
		},
		"result": map[string]any{"detected_env_vars": []map[string]any{{"key": "DATABASE_URL", "required": true}, {"key": "OPTIONAL", "required": false}}},
	}
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("doctor", "my-app"), ExitFailure)
	out := ta.out.String()
	assertContains(t, out, "authenticated as @octo")
	assertContains(t, out, "App does not listen on $PORT (config/puma.rb:12)")
	assertContains(t, out, "fix: Use ENV['PORT']")
	assertContains(t, out, "missing required secret DATABASE_URL")
	if strings.Contains(out, "OPTIONAL") {
		t.Fatal("optional vars are not missing secrets")
	}

	ta = newTestApp(t, f)
	assertExit(t, ta, ta.run("doctor", "my-app", "--json"), ExitFailure)
	var report map[string]any
	if err := json.Unmarshal(ta.out.Bytes(), &report); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, ta.out)
	}
	if report["ok"] != false {
		t.Fatalf("expected ok=false: %v", report)
	}
}

func TestDoctorCleanProject(t *testing.T) {
	f := newFakeAnchor(t)
	f.analysis[1] = map[string]any{"status": "complete", "framework": "rails", "preflight": []any{}, "result": map[string]any{}}
	ta := newTestApp(t, f)
	assertExit(t, ta, ta.run("doctor", "my-app"), 0)
	assertContains(t, ta.out.String(), "no preflight findings")
}
