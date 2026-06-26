// Package config loads Function URLs for the harness from flags or a JSON file.
package config

import (
	"encoding/json"
	"fmt"
	"os"
)

// URLConfig holds provisioner Function URLs keyed by region.
type URLConfig struct {
	USE1URL string `json:"use1_url"` // us-east-1
	USW2URL string `json:"usw2_url"` // us-west-2
}

const defaultConfigPath = "urls.json"

// Load returns a URLConfig from the given flag values (if non-empty) falling
// back to a JSON file at configPath (default "urls.json" in CWD).
func Load(use1Flag, usw2Flag, configPath string) (*URLConfig, error) {
	if configPath == "" {
		configPath = defaultConfigPath
	}

	cfg := &URLConfig{
		USE1URL: use1Flag,
		USW2URL: usw2Flag,
	}

	// If either URL is missing, try loading from file.
	if cfg.USE1URL == "" || cfg.USW2URL == "" {
		data, err := os.ReadFile(configPath)
		if err == nil {
			var fileCfg URLConfig
			if jsonErr := json.Unmarshal(data, &fileCfg); jsonErr == nil {
				if cfg.USE1URL == "" {
					cfg.USE1URL = fileCfg.USE1URL
				}
				if cfg.USW2URL == "" {
					cfg.USW2URL = fileCfg.USW2URL
				}
			}
		}
	}

	return cfg, nil
}

// URLForRegion returns the Function URL for the given region string.
func (c *URLConfig) URLForRegion(region string) (string, error) {
	switch region {
	case "us-east-1":
		if c.USE1URL == "" {
			return "", fmt.Errorf("no URL configured for us-east-1 (use --use1-url or urls.json)")
		}
		return c.USE1URL, nil
	case "us-west-2":
		if c.USW2URL == "" {
			return "", fmt.Errorf("no URL configured for us-west-2 (use --usw2-url or urls.json)")
		}
		return c.USW2URL, nil
	default:
		return "", fmt.Errorf("unknown region %q", region)
	}
}

// Save writes the config to a JSON file so URLs are persisted for subsequent runs.
func Save(path string, cfg *URLConfig) error {
	if path == "" {
		path = defaultConfigPath
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}
