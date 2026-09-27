package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/nebullii/anchor/cli/internal/api"
)

// LinkFile pins a directory to a project: {"project": "my-app"}.
const LinkFile = ".anchor.json"

type linkFile struct {
	Project string `json:"project"`
}

// resolveProject finds the project a command should act on, in order:
//  1. the explicit argument / --project flag (slug, id, name or owner/repo)
//  2. .anchor.json in the current directory or any parent
//  3. the git remotes of the current directory, matched against each
//     project's repository full_name
func (a *App) resolveProject(ctx context.Context, explicit string) (api.Project, error) {
	if explicit != "" {
		return a.lookupProject(ctx, explicit)
	}

	if ref, path, err := findLinkFile(a.Dir); err != nil {
		return api.Project{}, err
	} else if ref != "" {
		p, err := a.lookupProject(ctx, ref)
		if err != nil && api.IsCode(err, "not_found") {
			return p, fmt.Errorf("%s points at project %q, which was not found in your account", path, ref)
		}
		return p, err
	}

	repos := a.gitRepos()
	if len(repos) == 0 {
		return api.Project{}, errors.New("no project given. Pass a project (e.g. `anchor deploy my-app`), " +
			"run `anchor link my-app` to create " + LinkFile + ", or run inside a git repo connected to Anchor")
	}

	projects, _, err := a.client().Projects(ctx, 100)
	if err != nil {
		return api.Project{}, err
	}
	var matches []api.Project
	for _, p := range projects {
		for _, repo := range repos {
			if strings.EqualFold(p.Repository, repo) {
				matches = append(matches, p)
				break
			}
		}
	}
	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return api.Project{}, fmt.Errorf("no Anchor project is connected to %s. "+
			"Pass a project explicitly or run `anchor projects` to list yours", strings.Join(repos, ", "))
	default:
		slugs := make([]string, len(matches))
		for i, m := range matches {
			slugs[i] = m.Slug
		}
		return api.Project{}, fmt.Errorf("several projects deploy %s (%s). Pick one with `-p <slug>` or `anchor link <slug>`",
			matches[0].Repository, strings.Join(slugs, ", "))
	}
}

// lookupProject tries the API's id/slug lookup, then falls back to
// matching by name or repository across the project list.
func (a *App) lookupProject(ctx context.Context, ref string) (api.Project, error) {
	p, _, err := a.client().Project(ctx, ref)
	if err == nil || !api.IsCode(err, "not_found") {
		return p, err
	}

	projects, _, listErr := a.client().Projects(ctx, 100)
	if listErr != nil {
		return api.Project{}, listErr
	}
	for _, candidate := range projects {
		if strings.EqualFold(candidate.Name, ref) || strings.EqualFold(candidate.Repository, ref) {
			return candidate, nil
		}
	}
	return api.Project{}, &api.Error{Status: 404, Code: "not_found",
		Message: fmt.Sprintf("project %q not found. Run `anchor projects` to see your projects", ref)}
}

// findLinkFile walks up from dir looking for .anchor.json.
func findLinkFile(dir string) (ref, path string, err error) {
	for d := dir; ; d = filepath.Dir(d) {
		candidate := filepath.Join(d, LinkFile)
		data, readErr := os.ReadFile(candidate)
		if readErr == nil {
			var lf linkFile
			if err := json.Unmarshal(data, &lf); err != nil {
				return "", candidate, fmt.Errorf("%s is not valid JSON: %w", candidate, err)
			}
			if strings.TrimSpace(lf.Project) == "" {
				return "", candidate, fmt.Errorf(`%s has no "project" key`, candidate)
			}
			return strings.TrimSpace(lf.Project), candidate, nil
		}
		if parent := filepath.Dir(d); parent == d {
			return "", "", nil
		}
	}
}

// gitRepos returns "owner/repo" for each remote of the working directory,
// origin first. Returns nil outside a git repo or without git installed.
func (a *App) gitRepos() []string {
	if a.GitRemotes != nil {
		return a.GitRemotes()
	}
	out, err := exec.Command("git", "-C", a.Dir, "remote", "-v").Output()
	if err != nil {
		return nil
	}
	return reposFromRemoteList(string(out))
}

func reposFromRemoteList(out string) []string {
	var origin, others []string
	seen := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		repo := parseGitRemote(fields[1])
		if repo == "" || seen[repo] {
			continue
		}
		seen[repo] = true
		if fields[0] == "origin" {
			origin = append(origin, repo)
		} else {
			others = append(others, repo)
		}
	}
	return append(origin, others...)
}

var scpLikeRemote = regexp.MustCompile(`^(?:[^@/]+@)?[^:/]+:(.+)$`)

// parseGitRemote turns any common GitHub remote URL into "owner/repo":
//
//	https://github.com/owner/repo.git
//	https://x-access-token:TOKEN@github.com/owner/repo
//	git@github.com:owner/repo.git
//	ssh://git@github.com/owner/repo.git
func parseGitRemote(remote string) string {
	remote = strings.TrimSpace(remote)
	var path string
	if strings.Contains(remote, "://") {
		u, err := url.Parse(remote)
		if err != nil {
			return ""
		}
		path = u.Path
	} else if m := scpLikeRemote.FindStringSubmatch(remote); m != nil {
		path = m[1]
	} else {
		return ""
	}

	path = strings.TrimSuffix(strings.Trim(path, "/"), ".git")
	parts := strings.Split(path, "/")
	if len(parts) < 2 || parts[len(parts)-2] == "" || parts[len(parts)-1] == "" {
		return ""
	}
	return parts[len(parts)-2] + "/" + parts[len(parts)-1]
}
