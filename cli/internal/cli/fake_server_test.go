package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nebullii/anchor/cli/internal/api"
)

const testToken = "anc_testtoken"

// fakeAnchor is an in-memory stand-in for the Rails API, implementing the
// /api/v1 contract closely enough to drive every CLI command.
type fakeAnchor struct {
	t   *testing.T
	srv *httptest.Server

	mu       sync.Mutex
	requests []string          // "METHOD /path?query"
	bodies   map[string]string // last JSON body per "METHOD /path"
	auth     []string          // Authorization headers seen

	projects []api.Project
	secrets  map[int64][]api.Secret
	analysis map[int64]map[string]any

	// Deployment #42 advances one tick per GET /deployments/42.
	statuses []string
	logs     []tickLog
	tick     int
	pageSize int

	// Hooks and canned failures.
	onLogs         func(tick int)
	createError    *apiErr
	rollbackStatus int
}

type tickLog struct {
	tick int
	line api.LogLine
}

type apiErr struct {
	status int
	body   string
}

func newFakeAnchor(t *testing.T) *fakeAnchor {
	f := &fakeAnchor{
		t:        t,
		bodies:   map[string]string{},
		secrets:  map[int64][]api.Secret{},
		analysis: map[int64]map[string]any{},
		pageSize: 2,
		statuses: []string{"queued", "building", "deploying", "running"},
		projects: []api.Project{
			{ID: 1, Name: "My App", Slug: "my-app", Status: "active", Framework: "rails", Repository: "acme/web", ProductionBranch: "main", URL: "https://my-app.example.run.app"},
			{ID: 2, Name: "Docs", Slug: "docs", Status: "inactive", Repository: "acme/docs", ProductionBranch: "main"},
		},
	}
	now := time.Now()
	for i, msg := range []string{"Cloning acme/web", "Building image", "Step 1/5", "Pushing image", "Deploying revision", "Health check passed"} {
		f.logs = append(f.logs, tickLog{tick: i / 2, line: api.LogLine{ID: int64(100 + i), Message: msg, Level: "info", Source: "system", LoggedAt: now}})
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/me", f.me)
	mux.HandleFunc("GET /api/v1/projects", f.listProjects)
	mux.HandleFunc("GET /api/v1/projects/{id}", f.showProject)
	mux.HandleFunc("GET /api/v1/projects/{id}/analysis", f.showAnalysis)
	mux.HandleFunc("GET /api/v1/projects/{id}/deployments", f.listDeployments)
	mux.HandleFunc("POST /api/v1/projects/{id}/deployments", f.createDeployment)
	mux.HandleFunc("POST /api/v1/projects/{id}/rollback", f.rollback)
	mux.HandleFunc("GET /api/v1/projects/{id}/secrets", f.listSecrets)
	mux.HandleFunc("PUT /api/v1/projects/{id}/secrets/{key}", f.putSecret)
	mux.HandleFunc("DELETE /api/v1/projects/{id}/secrets/{key}", f.deleteSecret)
	mux.HandleFunc("GET /api/v1/deployments/{id}", f.showDeployment)
	mux.HandleFunc("GET /api/v1/deployments/{id}/logs", f.deploymentLogs)
	mux.HandleFunc("POST /api/v1/deployments/{id}/cancel", f.cancel)

	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		r.Body = io.NopCloser(bytes.NewReader(body))
		f.mu.Lock()
		f.requests = append(f.requests, r.Method+" "+r.URL.RequestURI())
		f.auth = append(f.auth, r.Header.Get("Authorization"))
		if len(body) > 0 {
			f.bodies[r.Method+" "+r.URL.Path] = string(body)
		}
		f.mu.Unlock()

		if r.Header.Get("Authorization") != "Bearer "+testToken {
			writeErr(w, 401, "unauthorized", "API token is invalid or has been revoked.")
			return
		}
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeAnchor) saw(req string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, r := range f.requests {
		if r == req {
			return true
		}
	}
	return false
}

func (f *fakeAnchor) body(req string) map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out map[string]any
	_ = json.Unmarshal([]byte(f.bodies[req]), &out)
	return out
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"code": code, "message": msg}})
}

func (f *fakeAnchor) project(r *http.Request) (api.Project, bool) {
	ref := r.PathValue("id")
	for _, p := range f.projects {
		if strconv.FormatInt(p.ID, 10) == ref || p.Slug == ref {
			return p, true
		}
	}
	return api.Project{}, false
}

func (f *fakeAnchor) currentDeployment() api.Deployment {
	status := f.statuses[min(f.tick, len(f.statuses)-1)]
	d := api.Deployment{ID: 42, ProjectID: 1, Status: status, Branch: "main", TriggeredBy: "cli", CreatedAt: time.Now()}
	if status == "running" {
		d.ServiceURL = "https://my-app.example.run.app"
	}
	if status == "failed" {
		d.ErrorMessage = "Build failed: missing Gemfile.lock"
		d.AIExplanation = "Commit your Gemfile.lock."
	}
	return d
}

func (f *fakeAnchor) me(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{
		"user":  map[string]any{"id": 7, "github_login": "octo", "quota": map[string]any{"deployments_today": 1, "daily_limit": 20}},
		"token": map[string]any{"id": 3, "name": "laptop"},
	})
}

func (f *fakeAnchor) listProjects(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"projects": f.projects})
}

func (f *fakeAnchor) showProject(w http.ResponseWriter, r *http.Request) {
	p, ok := f.project(r)
	if !ok {
		writeErr(w, 404, "not_found", "Resource not found.")
		return
	}
	writeJSON(w, 200, map[string]any{"project": p})
}

func (f *fakeAnchor) showAnalysis(w http.ResponseWriter, r *http.Request) {
	p, _ := f.project(r)
	a := f.analysis[p.ID]
	if a == nil {
		a = map[string]any{"status": "pending", "preflight": []any{}, "result": map[string]any{}}
	}
	writeJSON(w, 200, map[string]any{"analysis": a})
}

func (f *fakeAnchor) listDeployments(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	writeJSON(w, 200, map[string]any{"deployments": []api.Deployment{f.currentDeployment()}})
}

func (f *fakeAnchor) createDeployment(w http.ResponseWriter, r *http.Request) {
	if f.createError != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(f.createError.status)
		_, _ = w.Write([]byte(f.createError.body))
		return
	}
	var body struct{ Branch string }
	_ = json.NewDecoder(r.Body).Decode(&body)
	f.mu.Lock()
	d := f.currentDeployment()
	f.mu.Unlock()
	if body.Branch != "" {
		d.Branch = body.Branch
	}
	writeJSON(w, 202, map[string]any{"deployment": d})
}

func (f *fakeAnchor) rollback(w http.ResponseWriter, r *http.Request) {
	if f.rollbackStatus == 501 {
		writeErr(w, 501, "not_implemented", "Rollback is not available on this server yet.")
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	writeJSON(w, 202, map[string]any{"deployment": f.currentDeployment()})
}

func (f *fakeAnchor) listSecrets(w http.ResponseWriter, r *http.Request) {
	p, _ := f.project(r)
	s := f.secrets[p.ID]
	if s == nil {
		s = []api.Secret{}
	}
	writeJSON(w, 200, map[string]any{"secrets": s})
}

func (f *fakeAnchor) putSecret(w http.ResponseWriter, r *http.Request) {
	p, _ := f.project(r)
	key := r.PathValue("key")
	for _, s := range f.secrets[p.ID] {
		if s.Key == key {
			writeJSON(w, 200, map[string]any{"secret": s})
			return
		}
	}
	s := api.Secret{Key: key, CreatedAt: time.Now(), UpdatedAt: time.Now()}
	f.secrets[p.ID] = append(f.secrets[p.ID], s)
	writeJSON(w, 201, map[string]any{"secret": s})
}

func (f *fakeAnchor) deleteSecret(w http.ResponseWriter, r *http.Request) {
	p, _ := f.project(r)
	key := r.PathValue("key")
	for i, s := range f.secrets[p.ID] {
		if s.Key == key {
			f.secrets[p.ID] = append(f.secrets[p.ID][:i], f.secrets[p.ID][i+1:]...)
			w.WriteHeader(204)
			return
		}
	}
	writeErr(w, 404, "not_found", "Resource not found.")
}

func (f *fakeAnchor) showDeployment(w http.ResponseWriter, r *http.Request) {
	if r.PathValue("id") != "42" {
		writeErr(w, 404, "not_found", "Resource not found.")
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	d := f.currentDeployment()
	f.tick++
	writeJSON(w, 200, map[string]any{"deployment": d})
}

func (f *fakeAnchor) deploymentLogs(w http.ResponseWriter, r *http.Request) {
	after, _ := strconv.ParseInt(r.URL.Query().Get("after_id"), 10, 64)
	f.mu.Lock()
	visibleTick := f.tick - 1 // logs up to the status the client last saw
	var page []api.LogLine
	for _, l := range f.logs {
		if l.tick <= visibleTick && l.line.ID > after && len(page) < f.pageSize {
			page = append(page, l.line)
		}
	}
	hook := f.onLogs
	tick := f.tick
	f.mu.Unlock()

	next := after
	if len(page) > 0 {
		next = page[len(page)-1].ID
	}
	if page == nil {
		page = []api.LogLine{}
	}
	writeJSON(w, 200, map[string]any{"logs": page, "next_after_id": next})
	if hook != nil {
		hook(tick)
	}
}

func (f *fakeAnchor) cancel(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	d := f.currentDeployment()
	d.Status = "cancelled"
	writeJSON(w, 200, map[string]any{"deployment": d})
}

// ------------------------------------------------------------------ //
// Test app                                                             //
// ------------------------------------------------------------------ //

type testApp struct {
	*App
	out, errOut *bytes.Buffer
	env         map[string]string
	interrupt   context.CancelFunc
}

func newTestApp(t *testing.T, f *fakeAnchor) *testApp {
	t.Helper()
	ta := &testApp{out: &bytes.Buffer{}, errOut: &bytes.Buffer{}}
	ta.env = map[string]string{"HOME": t.TempDir(), "NO_COLOR": "1"}
	if f != nil {
		ta.env["ANCHOR_URL"] = f.srv.URL
		ta.env["ANCHOR_TOKEN"] = testToken
	}
	ta.App = &App{
		Stdin:        strings.NewReader(""),
		Stdout:       ta.out,
		Stderr:       ta.errOut,
		Getenv:       func(k string) string { return ta.env[k] },
		Dir:          t.TempDir(),
		StdinIsTTY:   func() bool { return false },
		PollInterval: time.Millisecond,
		GitRemotes:   func() []string { return nil },
		SignalContext: func(ctx context.Context) (context.Context, context.CancelFunc) {
			ctx, cancel := context.WithCancel(ctx)
			ta.interrupt = cancel
			return ctx, cancel
		},
	}
	ta.ReadSecret = func(string) (string, error) { return ta.readLine() }
	return ta
}

func (ta *testApp) run(args ...string) int {
	return ta.Run(args)
}
