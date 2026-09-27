package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// DefaultURL is used when neither the config file nor ANCHOR_URL set one.
const DefaultURL = "http://localhost:3000"

// Config is persisted at ~/.config/anchor/config.json (mode 0600).
// ANCHOR_URL and ANCHOR_TOKEN override the file.
type Config struct {
	URL   string `json:"url"`
	Token string `json:"token,omitempty"`

	// Where each value came from, for `anchor doctor`. Not persisted.
	URLSource   string `json:"-"`
	TokenSource string `json:"-"`
}

// configPath resolves ANCHOR_CONFIG, then $XDG_CONFIG_HOME, then ~/.config.
func configPath(getenv func(string) string) (string, error) {
	if p := getenv("ANCHOR_CONFIG"); p != "" {
		return p, nil
	}
	if xdg := getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "anchor", "config.json"), nil
	}
	home := getenv("HOME")
	if home == "" {
		var err error
		if home, err = os.UserHomeDir(); err != nil {
			return "", fmt.Errorf("cannot locate home directory: %w", err)
		}
	}
	return filepath.Join(home, ".config", "anchor", "config.json"), nil
}

// loadConfig reads the file (missing is fine) and applies env overrides.
func loadConfig(getenv func(string) string) (Config, string, error) {
	path, err := configPath(getenv)
	if err != nil {
		return Config{}, "", err
	}

	var cfg Config
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(data, &cfg); err != nil {
			return Config{}, path, fmt.Errorf("config file %s is not valid JSON: %w", path, err)
		}
		if cfg.URL != "" {
			cfg.URLSource = path
		}
		if cfg.Token != "" {
			cfg.TokenSource = path
		}
	case errors.Is(err, fs.ErrNotExist):
		// First run — nothing to load.
	default:
		return Config{}, path, err
	}

	if v := strings.TrimSpace(getenv("ANCHOR_URL")); v != "" {
		cfg.URL, cfg.URLSource = v, "ANCHOR_URL"
	}
	if v := strings.TrimSpace(getenv("ANCHOR_TOKEN")); v != "" {
		cfg.Token, cfg.TokenSource = v, "ANCHOR_TOKEN"
	}
	if cfg.URL == "" {
		cfg.URL, cfg.URLSource = DefaultURL, "default"
	}
	cfg.URL = strings.TrimRight(cfg.URL, "/")
	return cfg, path, nil
}

// saveConfig writes atomically with 0600 permissions (directory 0700).
func saveConfig(path string, cfg Config) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".config-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}
