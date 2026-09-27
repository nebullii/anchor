// Package api is a small client for Anchor's JSON API (/api/v1).
//
// Every method returns the decoded value plus the raw response body so
// callers can print the server's JSON verbatim for --json output.
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Client talks to one Anchor server with one API token.
type Client struct {
	BaseURL   string
	Token     string
	UserAgent string
	HTTP      *http.Client
}

// New returns a client with sane timeouts.
func New(baseURL, token, userAgent string) *Client {
	return &Client{
		BaseURL:   strings.TrimRight(baseURL, "/"),
		Token:     token,
		UserAgent: userAgent,
		HTTP:      &http.Client{Timeout: 30 * time.Second},
	}
}

// Error is a structured API error: {"error":{"code","message"}}.
type Error struct {
	Status         int
	Code           string
	Message        string
	MissingSecrets []string
}

func (e *Error) Error() string {
	if e.Message != "" {
		return e.Message
	}
	return fmt.Sprintf("request failed with HTTP %d", e.Status)
}

// ConnectionError means the server could not be reached at all.
type ConnectionError struct {
	URL string
	Err error
}

func (e *ConnectionError) Error() string {
	return fmt.Sprintf("could not reach Anchor at %s: %v", e.URL, e.Err)
}

func (e *ConnectionError) Unwrap() error { return e.Err }

// IsCode reports whether err is an API error with the given code.
func IsCode(err error, code string) bool {
	var apiErr *Error
	return errors.As(err, &apiErr) && apiErr.Code == code
}

// ------------------------------------------------------------------ //
// Types                                                                //
// ------------------------------------------------------------------ //

type Quota struct {
	DeploymentsToday     int `json:"deployments_today"`
	DeploymentsThisMonth int `json:"deployments_this_month"`
	DailyLimit           int `json:"daily_limit"`
	MonthlyLimit         int `json:"monthly_limit"`
}

type User struct {
	ID          int64  `json:"id"`
	GithubLogin string `json:"github_login"`
	Name        string `json:"name"`
	Email       string `json:"email"`
	Quota       Quota  `json:"quota"`
}

type Me struct {
	User  User `json:"user"`
	Token struct {
		ID   int64  `json:"id"`
		Name string `json:"name"`
	} `json:"token"`
}

type Deployment struct {
	ID            int64      `json:"id"`
	ProjectID     int64      `json:"project_id"`
	Status        string     `json:"status"`
	TriggeredBy   string     `json:"triggered_by"`
	Branch        string     `json:"branch"`
	CommitSHA     string     `json:"commit_sha"`
	CommitMessage string     `json:"commit_message"`
	ServiceURL    string     `json:"service_url"`
	RevisionName  string     `json:"revision_name"`
	ErrorMessage  string     `json:"error_message"`
	ErrorCategory string     `json:"error_category"`
	AIExplanation string     `json:"ai_explanation"`
	StartedAt     *time.Time `json:"started_at"`
	FinishedAt    *time.Time `json:"finished_at"`
	CreatedAt     time.Time  `json:"created_at"`
}

// Terminal statuses end a deployment; Succeeded says whether it went live.
var terminalStatuses = map[string]bool{
	"running": true, "success": true, "failed": true, "cancelled": true, "rolled_back": true,
}

func (d Deployment) Terminal() bool  { return terminalStatuses[d.Status] }
func (d Deployment) Succeeded() bool { return d.Status == "running" || d.Status == "success" }

type Project struct {
	ID               int64       `json:"id"`
	Name             string      `json:"name"`
	Slug             string      `json:"slug"`
	Status           string      `json:"status"`
	Framework        string      `json:"framework"`
	Repository       string      `json:"repository"`
	ProductionBranch string      `json:"production_branch"`
	URL              string      `json:"url"`
	Provider         string      `json:"provider"`
	Region           string      `json:"region"`
	AnalysisStatus   string      `json:"analysis_status"`
	LatestDeployment *Deployment `json:"latest_deployment"`
}

type LogLine struct {
	ID       int64     `json:"id"`
	Message  string    `json:"message"`
	Level    string    `json:"level"`
	Source   string    `json:"source"`
	LoggedAt time.Time `json:"logged_at"`
}

type LogsPage struct {
	Logs        []LogLine `json:"logs"`
	NextAfterID int64     `json:"next_after_id"`
}

type Secret struct {
	Key       string    `json:"key"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type Finding struct {
	ID       string `json:"id"`
	Severity string `json:"severity"`
	Message  string `json:"message"`
	File     string `json:"file"`
	Line     int    `json:"line"`
	Fix      string `json:"fix"`
}

type Analysis struct {
	Status     string          `json:"status"`
	AnalyzedAt *time.Time      `json:"analyzed_at"`
	Framework  string          `json:"framework"`
	Preflight  []Finding       `json:"preflight"`
	Result     json.RawMessage `json:"result"`
}

// ------------------------------------------------------------------ //
// Endpoints                                                            //
// ------------------------------------------------------------------ //

func (c *Client) Me(ctx context.Context) (Me, []byte, error) {
	var out Me
	raw, err := c.do(ctx, http.MethodGet, "/api/v1/me", nil, &out)
	return out, raw, err
}

func (c *Client) Projects(ctx context.Context, limit int) ([]Project, []byte, error) {
	var out struct {
		Projects []Project `json:"projects"`
	}
	raw, err := c.do(ctx, http.MethodGet, "/api/v1/projects"+limitQuery(limit), nil, &out)
	return out.Projects, raw, err
}

// Project fetches by numeric id or slug.
func (c *Client) Project(ctx context.Context, idOrSlug string) (Project, []byte, error) {
	var out struct {
		Project Project `json:"project"`
	}
	raw, err := c.do(ctx, http.MethodGet, "/api/v1/projects/"+url.PathEscape(idOrSlug), nil, &out)
	return out.Project, raw, err
}

func (c *Client) Analysis(ctx context.Context, projectID int64) (Analysis, []byte, error) {
	var out struct {
		Analysis Analysis `json:"analysis"`
	}
	raw, err := c.do(ctx, http.MethodGet, fmt.Sprintf("/api/v1/projects/%d/analysis", projectID), nil, &out)
	return out.Analysis, raw, err
}

func (c *Client) Deployments(ctx context.Context, projectID int64, limit int) ([]Deployment, []byte, error) {
	var out struct {
		Deployments []Deployment `json:"deployments"`
	}
	raw, err := c.do(ctx, http.MethodGet, fmt.Sprintf("/api/v1/projects/%d/deployments%s", projectID, limitQuery(limit)), nil, &out)
	return out.Deployments, raw, err
}

func (c *Client) CreateDeployment(ctx context.Context, projectID int64, branch string) (Deployment, []byte, error) {
	body := map[string]string{}
	if branch != "" {
		body["branch"] = branch
	}
	return c.deploymentCall(ctx, http.MethodPost, fmt.Sprintf("/api/v1/projects/%d/deployments", projectID), body)
}

func (c *Client) Deployment(ctx context.Context, id int64) (Deployment, []byte, error) {
	return c.deploymentCall(ctx, http.MethodGet, fmt.Sprintf("/api/v1/deployments/%d", id), nil)
}

func (c *Client) CancelDeployment(ctx context.Context, id int64) (Deployment, []byte, error) {
	return c.deploymentCall(ctx, http.MethodPost, fmt.Sprintf("/api/v1/deployments/%d/cancel", id), nil)
}

// Rollback targets deploymentID, or the previous good deployment when 0.
func (c *Client) Rollback(ctx context.Context, projectID, deploymentID int64) (Deployment, []byte, error) {
	body := map[string]int64{}
	if deploymentID > 0 {
		body["deployment_id"] = deploymentID
	}
	return c.deploymentCall(ctx, http.MethodPost, fmt.Sprintf("/api/v1/projects/%d/rollback", projectID), body)
}

func (c *Client) Logs(ctx context.Context, deploymentID, afterID int64) (LogsPage, []byte, error) {
	var out LogsPage
	path := fmt.Sprintf("/api/v1/deployments/%d/logs", deploymentID)
	if afterID > 0 {
		path += "?after_id=" + strconv.FormatInt(afterID, 10)
	}
	raw, err := c.do(ctx, http.MethodGet, path, nil, &out)
	return out, raw, err
}

func (c *Client) Secrets(ctx context.Context, projectID int64) ([]Secret, []byte, error) {
	var out struct {
		Secrets []Secret `json:"secrets"`
	}
	raw, err := c.do(ctx, http.MethodGet, fmt.Sprintf("/api/v1/projects/%d/secrets", projectID), nil, &out)
	return out.Secrets, raw, err
}

// SetSecret creates or replaces a secret. created is true on HTTP 201.
func (c *Client) SetSecret(ctx context.Context, projectID int64, key, value string) (created bool, err error) {
	path := fmt.Sprintf("/api/v1/projects/%d/secrets/%s", projectID, url.PathEscape(key))
	status, _, err := c.doStatus(ctx, http.MethodPut, path, map[string]string{"value": value}, nil)
	return status == http.StatusCreated, err
}

func (c *Client) UnsetSecret(ctx context.Context, projectID int64, key string) error {
	path := fmt.Sprintf("/api/v1/projects/%d/secrets/%s", projectID, url.PathEscape(key))
	_, err := c.do(ctx, http.MethodDelete, path, nil, nil)
	return err
}

// ------------------------------------------------------------------ //
// Transport                                                            //
// ------------------------------------------------------------------ //

func (c *Client) deploymentCall(ctx context.Context, method, path string, body any) (Deployment, []byte, error) {
	var out struct {
		Deployment Deployment `json:"deployment"`
	}
	raw, err := c.do(ctx, method, path, body, &out)
	return out.Deployment, raw, err
}

func (c *Client) do(ctx context.Context, method, path string, body, out any) ([]byte, error) {
	_, raw, err := c.doStatus(ctx, method, path, body, out)
	return raw, err
}

func (c *Client) doStatus(ctx context.Context, method, path string, body, out any) (int, []byte, error) {
	var reader io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
		reader = bytes.NewReader(buf)
	}

	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, reader)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	if c.UserAgent != "" {
		req.Header.Set("User-Agent", c.UserAgent)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return 0, nil, ctx.Err()
		}
		var netErr net.Error
		var urlErr *url.Error
		if errors.As(err, &netErr) || errors.As(err, &urlErr) {
			return 0, nil, &ConnectionError{URL: c.BaseURL, Err: unwrapURLError(err)}
		}
		return 0, nil, err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return resp.StatusCode, nil, err
	}

	if resp.StatusCode >= 400 {
		return resp.StatusCode, raw, decodeError(resp.StatusCode, raw)
	}
	if out != nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, out); err != nil {
			return resp.StatusCode, raw, fmt.Errorf("unexpected response from server (HTTP %d): %w", resp.StatusCode, err)
		}
	}
	return resp.StatusCode, raw, nil
}

func decodeError(status int, raw []byte) error {
	var envelope struct {
		Error json.RawMessage `json:"error"`
	}
	apiErr := &Error{Status: status}
	if json.Unmarshal(raw, &envelope) == nil && len(envelope.Error) > 0 {
		var structured struct {
			Code           string   `json:"code"`
			Message        string   `json:"message"`
			MissingSecrets []string `json:"missing_secrets"`
		}
		if json.Unmarshal(envelope.Error, &structured) == nil {
			apiErr.Code, apiErr.Message, apiErr.MissingSecrets = structured.Code, structured.Message, structured.MissingSecrets
		} else {
			// e.g. the rate limiter's {"error": "Too many requests..."}
			var msg string
			_ = json.Unmarshal(envelope.Error, &msg)
			apiErr.Message = msg
		}
	}
	if apiErr.Code == "" {
		switch status {
		case http.StatusUnauthorized:
			apiErr.Code = "unauthorized"
		case http.StatusNotFound:
			apiErr.Code = "not_found"
		case http.StatusTooManyRequests:
			apiErr.Code = "rate_limited"
		default:
			apiErr.Code = "http_" + strconv.Itoa(status)
		}
	}
	return apiErr
}

func unwrapURLError(err error) error {
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		return urlErr.Err
	}
	return err
}

func limitQuery(limit int) string {
	if limit <= 0 {
		return ""
	}
	return "?limit=" + strconv.Itoa(limit)
}
