package checker

import (
	"os"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	CheckInterval  time.Duration    `yaml:"check_interval"`
	AlertThreshold int              `yaml:"alert_threshold"`
	ListenAddr     string           `yaml:"listen_addr"`
	LogFile        string           `yaml:"log_file"`
	BusURL         string           `yaml:"bus_url"`
	NatsURL        string           `yaml:"nats_url"`
	LLMBridgeURL   string           `yaml:"llm_bridge_url"`
	Services       []ServiceConfig  `yaml:"services"`
	Resources      []ResourceConfig `yaml:"resources"`
	VersionChecks  []VersionConfig  `yaml:"version_checks"`
}

type ServiceConfig struct {
	Name            string        `yaml:"name"`
	Type            string        `yaml:"type"` // http, systemd, command
	URL             string        `yaml:"url,omitempty"`
	Timeout         time.Duration `yaml:"timeout,omitempty"`
	Unit            string        `yaml:"unit,omitempty"`
	SystemUnit      bool          `yaml:"system_unit,omitempty"` // systemctl runs without --user when true
	Command         []string      `yaml:"command,omitempty"`
	ExpectOutput    string        `yaml:"expect_output,omitempty"`
	AutoRestart     bool          `yaml:"auto_restart,omitempty"`
	RecoveryCommand []string      `yaml:"recovery_command,omitempty"` // run on AlertThreshold consecutive failures
	RecoveryTimeout time.Duration `yaml:"recovery_timeout,omitempty"` // defaults to 90s
}

type ResourceConfig struct {
	Name      string  `yaml:"name"`
	Type      string  `yaml:"type"` // disk, memory
	Path      string  `yaml:"path,omitempty"`
	Threshold float64 `yaml:"threshold"` // percent usage to alert at
	CCAgent   bool    `yaml:"cc_agent"`  // spawn CC agent on alert
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
