package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/nebullii/anchor/cli/internal/api"
)

// ------------------------------------------------------------------ //
// Auth                                                                 //
// ------------------------------------------------------------------ //

var loginCmd = command{
	Name:    "login",
	Summary: "Save an API token (create one under Settings → API tokens)",
	Usage:   "anchor login [--url https://anchor.example.com] [--token anc_...]",
	Flags: []flagDef{
		{Name: "url", Value: true, Usage: "Anchor server URL (default: saved URL or " + DefaultURL + ")"},
		{Name: "token", Value: true, Usage: "token to save (default: prompt, or read from stdin)"},
	},
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		if u := strings.TrimRight(p.String("url"), "/"); u != "" {
			if !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
				return usagef("--url must start with http:// or https://")
			}
			a.cfg.URL = u
		}

		token := strings.TrimSpace(p.String("token"))
		if token == "" {
			var err error
			if a.StdinIsTTY() {
				fmt.Fprintf(a.Stderr, "Create a token at %s/settings, then paste it below.\n", a.cfg.URL)
				token, err = a.ReadSecret("API token: ")
			} else {
				token, err = a.readLine()
			}
			if err != nil && token == "" {
				return errors.New("no token provided")
			}
			token = strings.TrimSpace(token)
		}
		if !strings.HasPrefix(token, "anc_") {
			return errors.New(`that doesn't look like an Anchor token (they start with "anc_")`)
		}

		a.cfg.Token = token
		me, _, err := a.client().Me(ctx)
		if err != nil {
			return err
		}

		// Persist only what came from the user, not env overrides.
		if err := saveConfig(a.cfgPath, Config{URL: a.cfg.URL, Token: token}); err != nil {
			return fmt.Errorf("could not save config: %w", err)
		}
		a.printf("Logged in to %s as @%s (token %q). Saved to %s\n", a.cfg.URL, me.User.GithubLogin, me.Token.Name, a.cfgPath)
		return nil
	},
}

var logoutCmd = command{
	Name:    "logout",
	Summary: "Forget the saved API token",
	Usage:   "anchor logout",
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		// Read the file directly (not env overrides) and drop the token.
		var saved Config
		if data, err := os.ReadFile(a.cfgPath); err == nil {
			_ = json.Unmarshal(data, &saved)
			if err := saveConfig(a.cfgPath, Config{URL: saved.URL}); err != nil {
				return err
			}
		}
		if a.Getenv("ANCHOR_TOKEN") != "" {
			fmt.Fprintln(a.Stderr, "note: ANCHOR_TOKEN is still set in your environment")
		}
		a.printf("Logged out. Revoke the token under Settings → API tokens if it may have leaked.\n")
		return nil
	},
}

var whoamiCmd = command{
	Name:    "whoami",
	Summary: "Show the account the token belongs to",
	Usage:   "anchor whoami [--json]",
	Flags:   []flagDef{flagJSON},
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		if err := a.requireLogin(); err != nil {
			return err
		}
		me, raw, err := a.client().Me(ctx)
		if err != nil {
			return err
		}
		if p.Bool("json") {
			return a.printJSON(raw)
		}
		q := me.User.Quota
		a.printf("@%s on %s (token %q)\nDeploys today: %d/%d, this month: %d/%d\n",
			me.User.GithubLogin, a.cfg.URL, me.Token.Name,
			q.DeploymentsToday, q.DailyLimit, q.DeploymentsThisMonth, q.MonthlyLimit)
		return nil
	},
}

// ------------------------------------------------------------------ //
// Projects                                                             //
// ------------------------------------------------------------------ //

var projectsCmd = command{
	Name:    "projects",
	Summary: "List your projects",
	Usage:   "anchor projects [--limit N] [--json]",
	Flags:   []flagDef{flagJSON, {Name: "limit", Value: true, Usage: "max projects to list (default 50)"}},
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		if err := a.requireLogin(); err != nil {
			return err
		}
		limit, err := p.Int("limit")
		if err != nil {
			return usageError{err.Error()}
		}
		projects, raw, err := a.client().Projects(ctx, int(limit))
		if err != nil {
			return err
		}
		if p.Bool("json") {
			return a.printJSON(raw)
		}
		if len(projects) == 0 {
			a.printf("No projects yet. Create one in the Anchor web app.\n")
			return nil
		}
		tw := tabwriter.NewWriter(a.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(tw, "SLUG\tSTATUS\tFRAMEWORK\tREPOSITORY\tLAST DEPLOY\tURL")
		for _, pr := range projects {
			last := "—"
			if d := pr.LatestDeployment; d != nil {
				last = fmt.Sprintf("#%d %s %s", d.ID, d.Status, relTime(&d.CreatedAt))
			}
			fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\n", pr.Slug, pr.Status, orDash(pr.Framework),
				orDash(pr.Repository), last, orDash(pr.URL))
		}
		return tw.Flush()
	},
}

var linkCmd = command{
	Name:    "link",
	Summary: "Pin this directory to a project (writes " + LinkFile + ")",
	Usage:   "anchor link <project>",
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		if err := a.requireLogin(); err != nil {
			return err
		}
		if p.Arg(0) == "" {
			return usagef("which project? e.g. `anchor link my-app`")
		}
		project, err := a.lookupProject(ctx, p.Arg(0))
		if err != nil {
			return err
		}
		data, _ := json.MarshalIndent(linkFile{Project: project.Slug}, "", "  ")
		path := filepath.Join(a.Dir, LinkFile)
		if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
			return err
		}
		a.printf("Linked %s to project %s.\n", a.Dir, project.Slug)
		return nil
	},
}

var statusCmd = command{
	Name:    "status",
	Summary: "Show a project and its recent deployments",
	Usage:   "anchor status [project] [--limit N] [--json]",
	Flags:   []flagDef{flagJSON, flagProject, {Name: "limit", Value: true, Usage: "deployments to show (default 5)"}},
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		if err := a.requireLogin(); err != nil {
			return err
		}
		limit, err := p.Int("limit")
		if err != nil {
			return usageError{err.Error()}
		}
		if limit == 0 {
			limit = 5
		}
		project, err := a.resolveProject(ctx, firstNonEmpty(p.Arg(0), p.String("project")))
		if err != nil {
			return err
		}
		deployments, rawDeps, err := a.client().Deployments(ctx, project.ID, int(limit))
		if err != nil {
			return err
		}
		if p.Bool("json") {
			var deps struct {
				Deployments json.RawMessage `json:"deployments"`
			}
			_ = json.Unmarshal(rawDeps, &deps)
			return a.printValueJSON(map[string]any{"project": project, "deployments": deps.Deployments})
		}

		a.printf("%s (%s)\n", project.Name, project.Slug)
		a.printf("  status:     %s\n", a.statusLabel(project.Status))
		a.printf("  url:        %s\n", orDash(project.URL))
		a.printf("  repository: %s @ %s\n", orDash(project.Repository), orDash(project.ProductionBranch))
		if project.Framework != "" {
			a.printf("  framework:  %s\n", project.Framework)
		}
		if len(deployments) == 0 {
			a.printf("\nNo deployments yet. Run `anchor deploy %s`.\n", project.Slug)
			return nil
		}
		a.printf("\n")
		tw := tabwriter.NewWriter(a.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(tw, "ID\tSTATUS\tBRANCH\tCOMMIT\tTRIGGER\tCREATED\tDURATION")
		for _, d := range deployments {
			fmt.Fprintf(tw, "#%d\t%s\t%s\t%s\t%s\t%s\t%s\n", d.ID, d.Status, orDash(d.Branch), shortSHA(d.CommitSHA),
				orDash(d.TriggeredBy), relTime(&d.CreatedAt), duration(d))
		}
		if err := tw.Flush(); err != nil {
			return err
		}
		if latest := deployments[0]; latest.Status == "failed" && latest.ErrorMessage != "" {
			a.printf("\nLatest deployment failed: %s\n", latest.ErrorMessage)
		}
		return nil
	},
}

// ------------------------------------------------------------------ //
// Deployments                                                          //
// ------------------------------------------------------------------ //

var deployCmd = command{
	Name:    "deploy",
	Summary: "Start a deployment (and optionally stream its logs)",
	Usage:   "anchor deploy [project] [--branch main] [--follow] [--json]",
	Flags: []flagDef{
		flagProject,
		{Name: "branch", Short: "b", Value: true, Usage: "branch to deploy (default: project's production branch)"},
		{Name: "follow", Short: "f", Usage: "stream logs until the deployment finishes; exit 1 if it fails"},
		flagJSON,
	},
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		if err := a.requireLogin(); err != nil {
			return err
		}
		project, err := a.resolveProject(ctx, firstNonEmpty(p.Arg(0), p.String("project")))
		if err != nil {
			return err
		}
		dep, raw, err := a.client().CreateDeployment(ctx, project.ID, p.String("branch"))
		if err != nil {
			return err
		}
		jsonOut := p.Bool("json")
		if !p.Bool("follow") {
			if jsonOut {
				return a.printJSON(raw)
			}
			a.printf("Deployment #%d queued for %s (branch %s).\n", dep.ID, project.Slug, orDash(dep.Branch))
			a.printf("Follow it with `anchor logs %d -f`.\n", dep.ID)
			return nil
		}
		if !jsonOut {
			fmt.Fprintf(a.Stderr, "Deploying %s (branch %s) — deployment #%d. Ctrl-C to stop following.\n",
				project.Slug, orDash(dep.Branch), dep.ID)
		}
		return a.followAndReport(ctx, dep, jsonOut)
	},
}

var logsCmd = command{
	Name:    "logs",
	Summary: "Print a deployment's logs",
	Usage:   "anchor logs <deployment-id> [-f] [--json]",
	Flags: []flagDef{
		{Name: "follow", Short: "f", Usage: "keep streaming until the deployment finishes"},
		flagJSON,
	},
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		if err := a.requireLogin(); err != nil {
			return err
		}
		id, err := deploymentID(p.Arg(0))
		if err != nil {
			return err
		}
		if p.Bool("follow") {
			dep, _, err := a.client().Deployment(ctx, id)
			if err != nil {
				return err
			}
			return a.followAndReport(ctx, dep, p.Bool("json"))
		}
		if p.Bool("json") {
			var all []api.LogLine
			var after int64
			for {
				page, _, err := a.client().Logs(ctx, id, after)
				if err != nil {
					return err
				}
				all = append(all, page.Logs...)
				if len(page.Logs) == 0 || page.NextAfterID <= after {
					break
				}
				after = page.NextAfterID
			}
			if all == nil {
				all = []api.LogLine{}
			}
			return a.printValueJSON(map[string]any{"logs": all, "next_after_id": after})
		}
		_, err = a.drainLogs(ctx, id, 0, false)
		return err
	},
}

var cancelCmd = command{
	Name:    "cancel",
	Summary: "Cancel an in-progress deployment",
	Usage:   "anchor cancel [deployment-id] [-p project] [--json]",
	Flags:   []flagDef{flagProject, flagJSON},
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		if err := a.requireLogin(); err != nil {
			return err
		}
		var id int64
		if p.Arg(0) != "" {
			var err error
			if id, err = deploymentID(p.Arg(0)); err != nil {
				return err
			}
		} else {
			project, err := a.resolveProject(ctx, p.String("project"))
			if err != nil {
				return err
			}
			latest := project.LatestDeployment
			if latest == nil || latest.Terminal() {
				return fmt.Errorf("no deployment in progress for %s", project.Slug)
			}
			id = latest.ID
		}
		dep, raw, err := a.client().CancelDeployment(ctx, id)
		if err != nil {
			return err
		}
		if p.Bool("json") {
			return a.printJSON(raw)
		}
		a.printf("Deployment #%d %s.\n", dep.ID, dep.Status)
		return nil
	},
}

var rollbackCmd = command{
	Name:    "rollback",
	Summary: "Roll back to the previous (or a given) successful deployment",
	Usage:   "anchor rollback [project] [--to DEPLOYMENT_ID] [--follow] [--json]",
	Flags: []flagDef{
		flagProject,
		{Name: "to", Value: true, Usage: "deployment id to roll back to (default: previous successful)"},
		{Name: "follow", Short: "f", Usage: "stream progress until the rollback finishes"},
		flagJSON,
	},
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		if err := a.requireLogin(); err != nil {
			return err
		}
		to, err := p.Int("to")
		if err != nil {
			return usageError{err.Error()}
		}
		project, err := a.resolveProject(ctx, firstNonEmpty(p.Arg(0), p.String("project")))
		if err != nil {
			return err
		}
		dep, raw, err := a.client().Rollback(ctx, project.ID, to)
		if err != nil {
			if api.IsCode(err, "not_implemented") {
				return errors.New("rollback is not available on this Anchor server yet")
			}
			return err
		}
		if p.Bool("follow") {
			return a.followAndReport(ctx, dep, p.Bool("json"))
		}
		if p.Bool("json") {
			return a.printJSON(raw)
		}
		a.printf("Rollback started for %s: deployment #%d. Follow it with `anchor logs %d -f`.\n", project.Slug, dep.ID, dep.ID)
		return nil
	},
}

// ------------------------------------------------------------------ //
// Secrets                                                              //
// ------------------------------------------------------------------ //

var secretsCmd = command{
	Name:    "secrets",
	Summary: "List, set or unset a project's secrets (env vars)",
	Usage: "anchor secrets list [-p project] [--json]\n" +
		"       anchor secrets set KEY=VALUE [KEY=VALUE...] [-p project]\n" +
		"       anchor secrets set KEY [-p project]   (value read from stdin)\n" +
		"       anchor secrets unset KEY [KEY...] [-p project]",
	Flags: []flagDef{flagProject, flagJSON},
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		sub := p.Arg(0)
		switch sub {
		case "list", "ls", "set", "unset", "rm":
		case "":
			return usagef("missing subcommand (list, set or unset)")
		default:
			return usagef("unknown subcommand %q (expected list, set or unset)", sub)
		}
		if err := a.requireLogin(); err != nil {
			return err
		}
		project, err := a.resolveProject(ctx, p.String("project"))
		if err != nil {
			return err
		}
		args := p.args[1:]

		switch sub {
		case "list", "ls":
			secrets, raw, err := a.client().Secrets(ctx, project.ID)
			if err != nil {
				return err
			}
			if p.Bool("json") {
				return a.printJSON(raw)
			}
			if len(secrets) == 0 {
				a.printf("No secrets for %s. Add one with `anchor secrets set KEY=value`.\n", project.Slug)
				return nil
			}
			tw := tabwriter.NewWriter(a.Stdout, 0, 4, 2, ' ', 0)
			fmt.Fprintln(tw, "KEY\tUPDATED")
			for _, s := range secrets {
				fmt.Fprintf(tw, "%s\t%s\n", s.Key, relTime(&s.UpdatedAt))
			}
			return tw.Flush()

		case "set":
			if len(args) == 0 {
				return usagef("nothing to set, e.g. `anchor secrets set DATABASE_URL=postgres://...`")
			}
			pairs, err := a.secretPairs(args)
			if err != nil {
				return err
			}
			for _, kv := range pairs {
				created, err := a.client().SetSecret(ctx, project.ID, kv[0], kv[1])
				if err != nil {
					return fmt.Errorf("%s: %w", kv[0], err)
				}
				verb := "Updated"
				if created {
					verb = "Added"
				}
				a.printf("%s %s on %s.\n", verb, kv[0], project.Slug)
			}
			a.printf("Secrets apply on the next deploy (`anchor deploy %s`).\n", project.Slug)
			return nil

		default: // unset, rm
			if len(args) == 0 {
				return usagef("which key? e.g. `anchor secrets unset API_KEY`")
			}
			for _, key := range args {
				if err := a.client().UnsetSecret(ctx, project.ID, key); err != nil {
					return fmt.Errorf("%s: %w", key, err)
				}
				a.printf("Removed %s from %s.\n", key, project.Slug)
			}
			return nil
		}
	},
}

// secretPairs parses KEY=VALUE args. A bare KEY (or KEY=-) reads the value
// from stdin so it never lands in shell history; only one such key is allowed.
func (a *App) secretPairs(args []string) ([][2]string, error) {
	fromStdin := 0
	for _, arg := range args {
		key, value, hasValue := strings.Cut(arg, "=")
		if key == "" {
			return nil, usagef("invalid argument %q, expected KEY=VALUE", arg)
		}
		if !hasValue || value == "-" {
			fromStdin++
		}
	}
	if fromStdin > 1 {
		return nil, usagef("only one secret can be read from stdin at a time")
	}

	var pairs [][2]string
	for _, arg := range args {
		key, value, hasValue := strings.Cut(arg, "=")
		if !hasValue || value == "-" {
			var err error
			if a.StdinIsTTY() {
				value, err = a.ReadSecret(fmt.Sprintf("Value for %s: ", key))
			} else {
				value, err = a.readAll()
			}
			if err != nil {
				return nil, fmt.Errorf("reading value for %s: %w", key, err)
			}
			if value == "" {
				return nil, fmt.Errorf("empty value for %s", key)
			}
		}
		pairs = append(pairs, [2]string{key, value})
	}
	return pairs, nil
}

// ------------------------------------------------------------------ //
// Doctor                                                               //
// ------------------------------------------------------------------ //

var doctorCmd = command{
	Name:    "doctor",
	Summary: "Check CLI setup and show a project's analysis/preflight findings",
	Usage:   "anchor doctor [project] [--json]",
	Flags:   []flagDef{flagProject, flagJSON},
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		jsonOut := p.Bool("json")
		ok := func(format string, args ...any) {
			if !jsonOut {
				a.printf("%s %s\n", a.paint("32", "✔"), fmt.Sprintf(format, args...))
			}
		}

		if !jsonOut {
			a.printf("%s server %s (from %s)\n", a.paint("90", "•"), a.cfg.URL, a.cfg.URLSource)
		}
		if err := a.requireLogin(); err != nil {
			return err
		}
		me, _, err := a.client().Me(ctx)
		if err != nil {
			return err
		}
		ok("authenticated as @%s (token %q from %s)", me.User.GithubLogin, me.Token.Name, a.cfg.TokenSource)

		project, err := a.resolveProject(ctx, firstNonEmpty(p.Arg(0), p.String("project")))
		if err != nil {
			return err
		}
		ok("project %s (%s)", project.Slug, orDash(project.Repository))

		analysis, rawAnalysis, err := a.client().Analysis(ctx, project.ID)
		if err != nil {
			return err
		}
		secrets, _, err := a.client().Secrets(ctx, project.ID)
		if err != nil {
			return err
		}
		missing := missingSecrets(analysis.Result, secrets)

		errorsFound := len(missing) > 0
		for _, f := range analysis.Preflight {
			if f.Severity == "error" {
				errorsFound = true
			}
		}

		if jsonOut {
			var an any
			_ = json.Unmarshal(rawAnalysis, &an)
			if err := a.printValueJSON(map[string]any{
				"server": a.cfg.URL, "user": me.User.GithubLogin, "project": project,
				"analysis": an, "missing_secrets": missing, "ok": !errorsFound,
			}); err != nil {
				return err
			}
		} else {
			a.printDoctorFindings(project, analysis, missing)
		}
		if errorsFound {
			return exitError{ExitFailure}
		}
		return nil
	},
}

func (a *App) printDoctorFindings(project api.Project, analysis api.Analysis, missing []string) {
	switch analysis.Status {
	case "complete":
		detail := ""
		if analysis.Framework != "" {
			detail = " (" + analysis.Framework + ")"
		}
		a.printf("%s analysis complete%s\n", a.paint("32", "✔"), detail)
	case "", "pending":
		a.printf("%s repository not analysed yet — open the project in Anchor or deploy once\n", a.paint("33", "!"))
	default:
		a.printf("%s analysis %s\n", a.paint("33", "!"), analysis.Status)
	}

	for _, key := range missing {
		a.printf("%s missing required secret %s — `anchor secrets set %s=...`\n", a.paint("31", "✘"), key, key)
	}

	if len(analysis.Preflight) == 0 {
		if analysis.Status == "complete" {
			a.printf("%s no preflight findings\n", a.paint("32", "✔"))
		}
		return
	}
	a.printf("\nPreflight findings:\n")
	for _, f := range analysis.Preflight {
		mark := map[string]string{"error": a.paint("31", "✘ error"), "warning": a.paint("33", "! warning")}[f.Severity]
		if mark == "" {
			mark = a.paint("90", "• "+f.Severity)
		}
		loc := ""
		if f.File != "" {
			loc = " (" + f.File
			if f.Line > 0 {
				loc += ":" + strconv.Itoa(f.Line)
			}
			loc += ")"
		}
		a.printf("  %s %s%s\n", mark, f.Message, loc)
		if f.Fix != "" {
			a.printf("      fix: %s\n", f.Fix)
		}
	}
}

// missingSecrets compares the analysis' required env vars with the
// secrets that exist, mirroring Project#missing_required_secrets.
func missingSecrets(result json.RawMessage, secrets []api.Secret) []string {
	var parsed struct {
		DetectedEnvVars []struct {
			Key      string `json:"key"`
			Required bool   `json:"required"`
		} `json:"detected_env_vars"`
	}
	_ = json.Unmarshal(result, &parsed)
	have := map[string]bool{}
	for _, s := range secrets {
		have[s.Key] = true
	}
	missing := []string{}
	for _, v := range parsed.DetectedEnvVars {
		if v.Required && !have[v.Key] {
			missing = append(missing, v.Key)
		}
	}
	return missing
}

// ------------------------------------------------------------------ //
// Misc                                                                 //
// ------------------------------------------------------------------ //

var versionCmd = command{
	Name:    "version",
	Summary: "Print the CLI version",
	Usage:   "anchor --version",
	Run: func(a *App, ctx context.Context, p parsedArgs) error {
		a.printf("anchor %s (%s/%s)\n", Version, runtime.GOOS, runtime.GOARCH)
		return nil
	},
}

func deploymentID(arg string) (int64, error) {
	if arg == "" {
		return 0, usagef("missing deployment id (see `anchor status`)")
	}
	id, err := strconv.ParseInt(strings.TrimPrefix(arg, "#"), 10, 64)
	if err != nil || id <= 0 {
		return 0, usagef("%q is not a deployment id", arg)
	}
	return id, nil
}

func duration(d api.Deployment) string {
	if d.StartedAt == nil || d.FinishedAt == nil {
		return "—"
	}
	secs := int(d.FinishedAt.Sub(*d.StartedAt).Seconds())
	if secs >= 60 {
		return fmt.Sprintf("%dm %ds", secs/60, secs%60)
	}
	return fmt.Sprintf("%ds", secs)
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
