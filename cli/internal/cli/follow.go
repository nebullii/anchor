package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/nebullii/anchor/cli/internal/api"
)

// follow polls a deployment and streams its logs (via after_id) until it
// reaches a terminal status or ctx is cancelled.
func (a *App) follow(ctx context.Context, id int64, jsonLines bool) (api.Deployment, error) {
	var after int64
	lastStatus := ""
	for {
		// Status first, logs second: once we've seen a terminal status,
		// the drain that follows picks up every line written before it.
		dep, _, err := a.client().Deployment(ctx, id)
		if err != nil {
			return dep, err
		}
		if dep.Status != lastStatus && !jsonLines {
			fmt.Fprintf(a.Stderr, "%s %s\n", a.paint("90", "==>"), a.statusLabel(dep.Status))
			lastStatus = dep.Status
		}
		if after, err = a.drainLogs(ctx, id, after, jsonLines); err != nil {
			return dep, err
		}
		if dep.Terminal() {
			return dep, nil
		}

		select {
		case <-ctx.Done():
			return dep, ctx.Err()
		case <-time.After(a.PollInterval):
		}
	}
}

// drainLogs prints every log line after `after` and returns the new cursor.
func (a *App) drainLogs(ctx context.Context, id, after int64, jsonLines bool) (int64, error) {
	for {
		page, _, err := a.client().Logs(ctx, id, after)
		if err != nil {
			return after, err
		}
		for _, line := range page.Logs {
			a.printLog(line, jsonLines)
		}
		if len(page.Logs) == 0 || page.NextAfterID <= after {
			return after, nil
		}
		after = page.NextAfterID
	}
}

func (a *App) printLog(line api.LogLine, jsonLines bool) {
	if jsonLines {
		data, _ := json.Marshal(line)
		fmt.Fprintln(a.Stdout, string(data))
		return
	}
	stamp := line.LoggedAt.Local().Format("15:04:05")
	msg := strings.TrimRight(line.Message, "\n")
	switch line.Level {
	case "error":
		msg = a.paint("31", msg)
	case "warn":
		msg = a.paint("33", msg)
	case "debug":
		msg = a.paint("90", msg)
	}
	fmt.Fprintf(a.Stdout, "%s %s\n", a.paint("90", stamp), msg)
}

// followAndReport follows a deployment and converts the outcome to an
// exit code: 0 when it went live, 1 when it failed/was cancelled, 130 on
// Ctrl-C (after offering to cancel the server-side deployment).
func (a *App) followAndReport(ctx context.Context, dep api.Deployment, jsonLines bool) error {
	final, err := a.follow(ctx, dep.ID, jsonLines)
	if errors.Is(err, context.Canceled) {
		a.offerCancel(dep.ID)
		return exitError{ExitInterrupted}
	}
	if err != nil {
		return err
	}
	if jsonLines {
		data, _ := json.Marshal(map[string]any{"deployment": final})
		fmt.Fprintln(a.Stdout, string(data))
	} else {
		a.printOutcome(final)
	}
	if final.Succeeded() {
		return nil
	}
	return exitError{ExitFailure}
}

func (a *App) printOutcome(d api.Deployment) {
	if d.Succeeded() {
		fmt.Fprintf(a.Stdout, "\n%s Deployment #%d is live", a.paint("32", "✔"), d.ID)
		if d.ServiceURL != "" {
			fmt.Fprintf(a.Stdout, ": %s", d.ServiceURL)
		}
		fmt.Fprintln(a.Stdout)
		return
	}
	fmt.Fprintf(a.Stdout, "\n%s Deployment #%d %s\n", a.paint("31", "✘"), d.ID, d.Status)
	if d.ErrorMessage != "" {
		fmt.Fprintf(a.Stdout, "  error: %s\n", d.ErrorMessage)
	}
	if d.AIExplanation != "" {
		fmt.Fprintf(a.Stdout, "\n%s\n", d.AIExplanation)
	}
}

// offerCancel runs after Ctrl-C. Interactive users are asked whether to
// cancel the deployment on the server; scripts just get a hint.
func (a *App) offerCancel(id int64) {
	// Restore default Ctrl-C handling so a second press really exits.
	if a.stopSignals != nil {
		a.stopSignals()
	}
	fmt.Fprintln(a.Stderr)
	if !a.StdinIsTTY() {
		fmt.Fprintf(a.Stderr, "Stopped following. Deployment #%d keeps running on the server; cancel it with `anchor cancel %d`.\n", id, id)
		return
	}
	fmt.Fprintf(a.Stderr, "Cancel deployment #%d on the server too? [y/N] ", id)
	answer, _ := a.readLine()
	if !strings.HasPrefix(strings.ToLower(strings.TrimSpace(answer)), "y") {
		fmt.Fprintf(a.Stderr, "Deployment #%d keeps running. Follow it again with `anchor logs %d -f`.\n", id, id)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if _, _, err := a.client().CancelDeployment(ctx, id); err != nil {
		fmt.Fprintf(a.Stderr, "error: could not cancel deployment #%d: %v\n", id, err)
		return
	}
	fmt.Fprintf(a.Stderr, "Deployment #%d cancelled.\n", id)
}

// ------------------------------------------------------------------ //
// Input                                                                //
// ------------------------------------------------------------------ //

func (a *App) reader() *bufio.Reader {
	if a.in == nil {
		a.in = bufio.NewReader(a.Stdin)
	}
	return a.in
}

func (a *App) readLine() (string, error) {
	line, err := a.reader().ReadString('\n')
	if err != nil && line == "" {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

// readAll reads stdin to EOF, dropping one trailing newline (so
// `echo value | anchor secrets set KEY` stores "value").
func (a *App) readAll() (string, error) {
	var sb strings.Builder
	if _, err := a.reader().WriteTo(&sb); err != nil {
		return "", err
	}
	s := strings.TrimSuffix(sb.String(), "\n")
	return strings.TrimSuffix(s, "\r"), nil
}

// readHidden prompts on stderr and reads a line with terminal echo off.
func (a *App) readHidden(prompt string) (string, error) {
	fmt.Fprint(a.Stderr, prompt)
	if f, ok := a.Stdin.(*os.File); ok && isTerminal(f) {
		if err := stty(f, "-echo"); err == nil {
			defer func() {
				_ = stty(f, "echo")
				fmt.Fprintln(a.Stderr)
			}()
		}
	}
	return a.readLine()
}

func stty(tty *os.File, arg string) error {
	cmd := exec.Command("stty", arg)
	cmd.Stdin = tty
	return cmd.Run()
}
