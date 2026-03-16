package checker

import (
	"os"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	CheckInterval  time.Duration   `yaml:"check_interval"`
	AlertThreshold int             `yaml:"alert_threshold"`
	ListenAddr     string          `yaml:"listen_addr"`
	LogFile        string          `yaml:"log_file"`
	BusURL         string          `yaml:"bus_url"`
	Services       []ServiceConfig `yaml:"services"`
	VersionChecks  []VersionConfig `yaml:"version_checks"`
}

type ServiceConfig struct {
	Name         string        `yaml:"name"`
	Type         string        `yaml:"type"` // http, systemd, command
	URL          string        `yaml:"url,omitempty"`
	Timeout      time.Duration `yaml:"timeout,omitempty"`
	Unit         string        `yaml:"unit,omitempty"`
	Command      []string      `yaml:"command,omitempty"`
	ExpectOutput string        `yaml:"expect_output,omitempty"`
	AutoRestart  bool          `yaml:"auto_restart,omitempty"`
}

type VersionConfig struct {
	Name      string `yaml:"name"`
	LocalRepo string `yaml:"local_repo"`
	RemoteRef string `yaml:"remote_ref"`
	MaxDrift  int    `yaml:"max_drift"`
}

func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	if cfg.CheckInterval == 0 {
		cfg.CheckInterval = 60 * time.Second
	}
	if cfg.AlertThreshold == 0 {
		cfg.AlertThreshold = 3
	}
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = ":8099"
	}
	return &cfg, nil
}
