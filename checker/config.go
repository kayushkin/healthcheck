package checker

import (
	"fmt"
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
	// MachineHealth turns on the checks of every machine connected to the
	// bridge at LLMBridgeURL, and of the machines on its connected servers.
	// Absent means off.
	MachineHealth *MachineHealthConfig `yaml:"machine_health"`

	// LLMBridgeServiceToken is what healthcheck sends llm-bridge-server as
	// X-LLM-Bridge-Service-Token. It comes from the environment variable
	// named by llmBridgeServiceTokenEnvironmentVariable, never from the YAML,
	// because config.yaml is tracked in git.
	LLMBridgeServiceToken string `yaml:"-"`
}

// llmBridgeServiceTokenEnvironmentVariable is the variable llm-bridge-server
// itself reads its service token from, and the one every other service here
// that calls it uses.
const llmBridgeServiceTokenEnvironmentVariable = "LLMBRIDGE_SERVICE_TOKEN"

// MachineHealthConfig sets the lines the machine checks alert at.
type MachineHealthConfig struct {
	// DriveUsageThresholdPercent: a drive at or above this share used alerts.
	DriveUsageThresholdPercent float64 `yaml:"drive_usage_threshold_percent"`
	// BatteryLowChargeThresholdPercent: a battery at or below this charge
	// alerts, but only while it is discharging.
	BatteryLowChargeThresholdPercent float64 `yaml:"battery_low_charge_threshold_percent"`
	// StaleAfter is how old a machine's newest sample may be before the
	// machine counts as no longer reporting.
	StaleAfter time.Duration `yaml:"stale_after"`
	// RequestTimeout bounds each call to llm-bridge-server.
	RequestTimeout time.Duration `yaml:"request_timeout"`
	// AlwaysOnMachines are the machines whose silence alerts. Any other
	// machine that stops reporting shows as unknown on the status page and
	// alerts nothing, because a laptop that is shut is not a fault.
	AlwaysOnMachines []AlwaysOnMachine `yaml:"always_on_machines"`
}

// AlwaysOnMachine names one machine by the ids the bridges give it.
type AlwaysOnMachine struct {
	// PeerServerID is the connected server's own id, as GET /peer-connections
	// reports it in other_server_id. Empty means a machine of this host's
	// bridge.
	PeerServerID string `yaml:"peer_server_id,omitempty"`
	// MachineID is the bridge's machine id, as GET /machines/stats reports it.
	MachineID string `yaml:"machine_id"`
}

func (machineHealth *MachineHealthConfig) isAlwaysOn(peerServerID, machineID string) bool {
	for _, machine := range machineHealth.AlwaysOnMachines {
		if machine.PeerServerID == peerServerID && machine.MachineID == machineID {
			return true
		}
	}
	return false
}

func (machineHealth *MachineHealthConfig) applyDefaultsAndValidate() error {
	if machineHealth.DriveUsageThresholdPercent == 0 {
		machineHealth.DriveUsageThresholdPercent = 90
	}
	if machineHealth.BatteryLowChargeThresholdPercent == 0 {
		machineHealth.BatteryLowChargeThresholdPercent = 15
	}
	if machineHealth.StaleAfter == 0 {
		machineHealth.StaleAfter = 10 * time.Minute
	}
	if machineHealth.RequestTimeout == 0 {
		machineHealth.RequestTimeout = 15 * time.Second
	}
	if machineHealth.DriveUsageThresholdPercent < 0 || machineHealth.DriveUsageThresholdPercent > 100 {
		return fmt.Errorf("machine_health.drive_usage_threshold_percent %v is not between 0 and 100", machineHealth.DriveUsageThresholdPercent)
	}
	if machineHealth.BatteryLowChargeThresholdPercent < 0 || machineHealth.BatteryLowChargeThresholdPercent > 100 {
		return fmt.Errorf("machine_health.battery_low_charge_threshold_percent %v is not between 0 and 100", machineHealth.BatteryLowChargeThresholdPercent)
	}
	if machineHealth.StaleAfter < 0 || machineHealth.RequestTimeout < 0 {
		return fmt.Errorf("machine_health.stale_after and request_timeout must not be negative")
	}
	for _, machine := range machineHealth.AlwaysOnMachines {
		if machine.MachineID == "" {
			return fmt.Errorf("machine_health.always_on_machines has an entry with no machine_id")
		}
	}
	return nil
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
		cfg.ListenAddr = "127.0.0.1:8099"
	}
	if cfg.MachineHealth != nil {
		if cfg.LLMBridgeURL == "" {
			return nil, fmt.Errorf("machine_health needs llm_bridge_url, the bridge whose machines it checks")
		}
		if err := cfg.MachineHealth.applyDefaultsAndValidate(); err != nil {
			return nil, err
		}
	}
	cfg.LLMBridgeServiceToken = os.Getenv(llmBridgeServiceTokenEnvironmentVariable)
	return &cfg, nil
}
