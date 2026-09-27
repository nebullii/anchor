// Package cli implements the `anchor` command-line interface.
package cli

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"time"

	"github.com/nebullii/anchor/cli/internal/api"
)

// Version is overridden at build time: -ldflags "-X .../cli.Version=1.2.3".
var Version = "0.1.0-dev"

// Exit codes.
const (
	ExitOK          = 0
	ExitFailure     = 1
	ExitUsage       = 2
	ExitInterrupted = 130
)

// App holds everything a command needs. Tests swap the I/O, environment,
// git lookup and poll interval; main wires in the real process.
type App struct {
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer

	Getenv       func(string) string
	Dir          string
	StdinIsTTY   func() bool
	PollInterval time.Duration
	HTTPClient   *http.Client

	// SignalContext returns a context cancelled on Ctrl-C.
	SignalContext func(context.Context) (context.Context, context.CancelFunc)
	// GitRemotes overrides `git remote -v` lookup (tests).
	GitRemotes func() []string
	// ReadSecret reads a line without echo (tests override).
	ReadSecret func(prompt string) (string, error)

	cfg         Config
	cfgPath     string
	api         *api.Client
	in          *bufio.Reader
	stopSignals context.CancelFunc
}

// NewApp returns an App bound to the real process.
func NewApp() *App {
	dir, _ := os.Getwd()
	a := &App{
		Stdin:        os.Stdin,
		Stdout:       os.Stdout,
		Stderr:       os.Stderr,
		Getenv:       os.Getenv,
		Dir:          dir,
		StdinIsTTY:   func() bool { return isTerminal(os.Stdin) },
		PollInterval: 2 * time.Second,
		SignalContext: func(ctx context.Context) (context.Context, context.CancelFunc) {
			return signal.NotifyContext(ctx, os.Interrupt)
		},
	}
	a.ReadSecret = a.readHidden
	return a
}

// exitError ends the program with a code and no extra message.
type exitError struct{ code int }

func (e exitError) Error() string { return fmt.Sprintf("exit %d", e.code) }

// usageError prints the message plus a pointer to --help and exits 2.
type usageError struct{ msg string }

func (e usageError) Error() string { return e.msg }

func usagef(format string, args ...any) error { return usageError{fmt.Sprintf(format, args...)} }

type command struct {
	Name    string
	Summary string
	Usage   string
	Flags   []flagDef
	Run     func(a *App, ctx context.Context, p parsedArgs) error
}

func (a *App) commands() map[string]command {
	list := []command{
		loginCmd, logoutCmd, whoamiCmd, projectsCmd, linkCmd, deployCmd, statusCmd,
		logsCmd, cancelCmd, rollbackCmd, secretsCmd, doctorCmd, versionCmd,
	}
	m := make(map[string]command, len(list))
	for _, c := range list {
		m[c.Name] = c
	}
	return m
}

// Run executes argv (without the program name) and returns the exit code.
func (a *App) Run(argv []string) int {
	if len(argv) == 0 {
		a.printHelp()
		return ExitUsage
	}

	switch argv[0] {
	case "-h", "--help", "help":
		if len(argv) > 1 {
			if c, ok := a.commands()[argv[1]]; ok {
				a.printCommandHelp(c)
				return ExitOK
			}
		}
		a.printHelp()
		return ExitOK
	case "-v", "--version":
		argv = []string{"version"}
	}

	cmd, ok := a.commands()[argv[0]]
	if !ok {
		fmt.Fprintf(a.Stderr, "error: unknown command %q\n\n", argv[0])
		a.printHelp()
		return ExitUsage
	}

	parsed, err := parseFlags(cmd.Name, argv[1:], append(cmd.Flags, flagHelp))
	if err != nil {
		fmt.Fprintf(a.Stderr, "error: %v\n", err)
		return ExitUsage
	}
	if parsed.Bool("help") {
		a.printCommandHelp(cmd)
		return ExitOK
	}

	if cmd.Name != "version" && cmd.Name != "help" {
		if a.cfg, a.cfgPath, err = loadConfig(a.Getenv); err != nil {
			fmt.Fprintf(a.Stderr, "error: %v\n", err)
			return ExitFailure
		}
	}

	ctx, stop := a.SignalContext(context.Background())
	defer stop()
	a.stopSignals = stop

	return a.exitCode(cmd, cmd.Run(a, ctx, parsed))
}

func (a *App) exitCode(cmd command, err error) int {
	if err == nil {
		return ExitOK
	}
	var ee exitError
	if errors.As(err, &ee) {
		return ee.code
	}
	if errors.Is(err, context.Canceled) {
		fmt.Fprintln(a.Stderr, "interrupted")
		return ExitInterrupted
	}
	var ue usageError
	if errors.As(err, &ue) {
		fmt.Fprintf(a.Stderr, "error: %s\nusage: %s\n", ue.msg, cmd.Usage)
		return ExitUsage
	}
	fmt.Fprintf(a.Stderr, "error: %s\n", err)
	if hint := a.hintFor(err); hint != "" {
		fmt.Fprintf(a.Stderr, "hint: %s\n", hint)
	}
	return ExitFailure
}

// hintFor turns common API failures into a next step.
func (a *App) hintFor(err error) string {
	var connErr *api.ConnectionError
	if errors.As(err, &connErr) {
		return "is the server running? Point the CLI elsewhere with ANCHOR_URL or `anchor login --url https://...`"
	}
	var apiErr *api.Error
	if !errors.As(err, &apiErr) {
		return ""
	}
	switch apiErr.Code {
	case "unauthorized":
		return "run `anchor login` with a token from Settings → API tokens"
	case "missing_secrets":
		parts := make([]string, len(apiErr.MissingSecrets))
		for i, k := range apiErr.MissingSecrets {
			parts[i] = "anchor secrets set " + k + "=..."
		}
		return strings.Join(parts, "; ")
	case "deploy_in_progress":
		return "watch it with `anchor status`, or stop it with `anchor cancel`"
	case "quota_exceeded", "rate_limited":
		return "wait a while and try again"
	case "not_implemented":
		return "this Anchor server is older than your CLI; upgrade the server"
	}
	return ""
}

// client returns the API client; commands call requireLogin first.
func (a *App) client() *api.Client {
	if a.api == nil {
		a.api = api.New(a.cfg.URL, a.cfg.Token, "anchor-cli/"+Version)
		if a.HTTPClient != nil {
			a.api.HTTP = a.HTTPClient
		}
	}
	return a.api
}

func (a *App) requireLogin() error {
	if a.cfg.Token == "" {
		return errors.New("not logged in. Run `anchor login` (or set ANCHOR_TOKEN)")
	}
	return nil
}

// ------------------------------------------------------------------ //
// Output helpers                                                       //
// ------------------------------------------------------------------ //

// printJSON pretty-prints the server's response, preserving key order.
func (a *App) printJSON(raw []byte) error {
	var buf bytes.Buffer
	if err := json.Indent(&buf, raw, "", "  "); err != nil {
		_, err = a.Stdout.Write(raw)
		return err
	}
	buf.WriteByte('\n')
	_, err := buf.WriteTo(a.Stdout)
	return err
}

func (a *App) printValueJSON(v any) error {
	enc := json.NewEncoder(a.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func (a *App) printf(format string, args ...any) { fmt.Fprintf(a.Stdout, format, args...) }

func (a *App) colorEnabled() bool {
	if a.Getenv("NO_COLOR") != "" {
		return false
	}
	f, ok := a.Stdout.(*os.File)
	return ok && isTerminal(f)
}

func (a *App) paint(code, s string) string {
	if !a.colorEnabled() {
		return s
	}
	return "\x1b[" + code + "m" + s + "\x1b[0m"
}

func (a *App) statusLabel(status string) string {
	switch status {
	case "running", "success", "active":
		return a.paint("32", status)
	case "failed", "error":
		return a.paint("31", status)
	case "cancelled", "rolled_back", "inactive":
		return a.paint("90", status)
	default:
		return a.paint("33", status)
	}
}

func (a *App) printHelp() {
	fmt.Fprintf(a.Stdout, `anchor — deploy GitHub repos to your own cloud from the terminal

Usage: anchor <command> [arguments] [flags]

Commands:
`)
	cmds := a.commands()
	names := make([]string, 0, len(cmds))
	for n := range cmds {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		fmt.Fprintf(a.Stdout, "  %-10s %s\n", n, cmds[n].Summary)
	}
	fmt.Fprintf(a.Stdout, `
Project selection: pass a slug/id, or use -p, a %s file, or the git remote.
Environment: ANCHOR_URL and ANCHOR_TOKEN override ~/.config/anchor/config.json.
Run 'anchor <command> --help' for details.
`, LinkFile)
}

func (a *App) printCommandHelp(c command) {
	fmt.Fprintf(a.Stdout, "%s\n\nUsage: %s\n", c.Summary, c.Usage)
	if len(c.Flags) > 0 {
		fmt.Fprintln(a.Stdout, "\nFlags:")
		for _, f := range c.Flags {
			name := "--" + f.Name
			if f.Short != "" {
				name = "-" + f.Short + ", " + name
			}
			if f.Value {
				name += " <value>"
			}
			fmt.Fprintf(a.Stdout, "  %-26s %s\n", name, f.Usage)
		}
	}
}

func isTerminal(f *os.File) bool {
	info, err := f.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func relTime(t *time.Time) string {
	if t == nil || t.IsZero() {
		return "—"
	}
	d := time.Since(*t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

func orDash(s string) string {
	if strings.TrimSpace(s) == "" {
		return "—"
	}
	return s
}

func shortSHA(s string) string {
	if len(s) > 7 {
		return s[:7]
	}
	return orDash(s)
}
