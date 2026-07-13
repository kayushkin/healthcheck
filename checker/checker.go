package checker

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type Status string

const (
	StatusUp      Status = "up"
	StatusDown    Status = "down"
	StatusDegraded Status = "degraded"
	StatusUnknown Status = "unknown"
	// StatusMisconfigured means the check itself is wrong — it is watching
	// something that does not exist — so it reports nothing about the service.
	// Distinct from StatusDown ("the service is not running"), because the two
	// demand opposite responses: down wants the service restarted,
	// misconfigured wants the *config* fixed and must never drive a restart.
	StatusMisconfigured Status = "misconfigured"
)

// UnitNotFoundError reports that a systemd check names a unit that does not
// exist under the manager it probed — i.e. `system_unit` disagrees with where
// the unit actually lives, or the unit is gone. This is a config bug, not a
// service outage, and callers must treat it as one.
type UnitNotFoundError struct {
	Unit       string
	SystemUnit bool
}

func (e *UnitNotFoundError) Error() string {
	manager := "the user manager (systemctl --user)"
	fix := "set system_unit: true if it is a system unit"
	if e.SystemUnit {
		manager = "the system manager (systemctl)"
		fix = "remove system_unit: true if it is a user unit"
	}
	return fmt.Sprintf("unit %s does not exist under %s — this check is watching nothing; %s",
		e.Unit, manager, fix)
}

type ServiceState struct {
	Name              string    `json:"name"`
	Type              string    `json:"type"`
	Status            Status    `json:"status"`
	ResponseMs        int64     `json:"response_ms"`
	LastCheck         time.Time `json:"last_check"`
	ConsecutiveFails  int       `json:"consecutive_failures"`
	UptimePct24h      float64   `json:"uptime_pct_24h"`
	Version           string    `json:"version,omitempty"`
	VersionDrift      int       `json:"version_drift,omitempty"`
	LastError         string    `json:"last_error,omitempty"`
	EnabledState      string    `json:"enabled_state,omitempty"` // systemctl is-enabled output (only set for type=systemd)
}

type uptimeRecord struct {
	timestamp time.Time
	up        bool
}

type Checker struct {
	config             *Config
	mu                 sync.RWMutex
	states             map[string]*ServiceState
	resourceStates     map[string]*ResourceState
	history            map[string][]uptimeRecord
	onChange           func(name string, oldStatus, newStatus Status)
	onRestart          func(name string, success bool, err error)
	onPersistentAlert  func(name string, state ResourceState)
	onCCAgentExhausted func(name string, state ResourceState)
}

func New(cfg *Config) *Checker {
	c := &Checker{
		config:         cfg,
		states:         make(map[string]*ServiceState),
		resourceStates: make(map[string]*ResourceState),
		history:        make(map[string][]uptimeRecord),
	}
	for _, svc := range cfg.Services {
		c.states[svc.Name] = &ServiceState{
			Name:   svc.Name,
			Type:   svc.Type,
			Status: StatusUnknown,
		}
	}
	for _, res := range cfg.Resources {
		c.resourceStates[res.Name] = &ResourceState{
			Name:      res.Name,
			Type:      res.Type,
			Threshold: res.Threshold,
			Status:    StatusUnknown,
		}
	}
	return c
}

func (c *Checker) OnChange(fn func(name string, oldStatus, newStatus Status)) {
	c.onChange = fn
}

func (c *Checker) OnRestart(fn func(name string, success bool, err error)) {
	c.onRestart = fn
}

func (c *Checker) OnPersistentAlert(fn func(name string, state ResourceState)) {
	c.onPersistentAlert = fn
}

func (c *Checker) OnCCAgentExhausted(fn func(name string, state ResourceState)) {
	c.onCCAgentExhausted = fn
}

func (c *Checker) GetStates() []ServiceState {
	c.mu.RLock()
	defer c.mu.RUnlock()
	result := make([]ServiceState, 0, len(c.states))
	for _, s := range c.states {
		result = append(result, *s)
	}
	return result
}

func (c *Checker) Run(ctx context.Context) {
	// Initial check
	c.checkAll()
	c.checkAllResources()

	ticker := time.NewTicker(c.config.CheckInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.checkAll()
			c.checkAllResources()
		}
	}
}

func (c *Checker) checkAll() {
	var wg sync.WaitGroup
	for _, svc := range c.config.Services {
		wg.Add(1)
		go func(svc ServiceConfig) {
			defer wg.Done()
			c.checkService(svc)
		}(svc)
	}
	wg.Wait()
}

func (c *Checker) checkService(svc ServiceConfig) {
	start := time.Now()
	var checkErr error
	var enabledState string

	switch svc.Type {
	case "http":
		checkErr = c.checkHTTP(svc)
	case "systemd":
		checkErr = c.checkSystemd(svc)
		enabledState = systemdIsEnabled(svc)
	case "command":
		checkErr = c.checkCommand(svc)
	default:
		checkErr = fmt.Errorf("unknown check type: %s", svc.Type)
	}

	elapsed := time.Since(start)

	c.mu.Lock()
	state := c.states[svc.Name]
	oldStatus := state.Status

	state.LastCheck = time.Now()
	state.ResponseMs = elapsed.Milliseconds()
	state.EnabledState = enabledState

	// A check that names a unit which does not exist is broken config, and it is
	// broken deterministically — there is nothing to ramp up to, so it does not
	// wait for AlertThreshold the way a flaky service does. Report it on the
	// first observation.
	var unitNotFound *UnitNotFoundError
	misconfigured := errors.As(checkErr, &unitNotFound)

	if checkErr != nil {
		state.ConsecutiveFails++
		state.LastError = checkErr.Error()
		switch {
		case misconfigured:
			state.Status = StatusMisconfigured
		case state.ConsecutiveFails >= c.config.AlertThreshold:
			state.Status = StatusDown
		default:
			state.Status = StatusDegraded
		}
	} else {
		state.ConsecutiveFails = 0
		state.Status = StatusUp
		state.LastError = ""
	}
	consecutiveFails := state.ConsecutiveFails

	// Record uptime history
	c.history[svc.Name] = append(c.history[svc.Name], uptimeRecord{
		timestamp: time.Now(),
		up:        checkErr == nil,
	})
	state.UptimePct24h = c.calcUptime24h(svc.Name)

	newStatus := state.Status
	c.mu.Unlock()

	if oldStatus != newStatus && oldStatus != StatusUnknown && c.onChange != nil {
		c.onChange(svc.Name, oldStatus, newStatus)
	}

	// Auto-recover on threshold breach. systemd services use systemctl
	// restart; anything else (e.g. command checks) runs RecoveryCommand if
	// configured.
	//
	// A misconfigured check is never recovered from. Restarting a unit that does
	// not exist cannot succeed, so auto_restart would retry it every interval
	// forever — and when the phantom unit DOES exist but can never start (a
	// shadow user unit whose port is already held by the real system unit), that
	// loop is unbounded and real: it once drove 811,295 restarts. The check is
	// wrong, so the only valid recovery is a human fixing the config.
	if misconfigured {
		log.Printf("MISCONFIGURED CHECK %s: %v (auto-restart suppressed; fix config.yaml)",
			svc.Name, checkErr)
	} else if checkErr != nil && consecutiveFails >= c.config.AlertThreshold {
		if svc.AutoRestart && svc.Type == "systemd" {
			go c.restartService(svc)
		} else if len(svc.RecoveryCommand) > 0 {
			go c.runRecovery(svc)
		}
	}

	// Registry is the source of truth: a service listed here is one we want
	// running at boot. If systemd reports it disabled, enable it now so it
	// auto-starts on next reboot. (Does not start the service — restart is
	// already handled by AutoRestart on a separate signal.)
	if svc.Type == "systemd" && enabledState == "disabled" {
		go c.ensureEnabled(svc)
	}
}

func (c *Checker) checkHTTP(svc ServiceConfig) error {
	timeout := svc.Timeout
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	client := &http.Client{Timeout: timeout}
	resp, err := client.Get(svc.URL)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode >= 500 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

// checkSystemd asks for LoadState alongside ActiveState rather than using
// `systemctl is-active`. is-active prints "inactive" both for a unit that is
// stopped and for one that does not exist at all, so it cannot tell a service
// outage from a check pointed at the wrong systemd manager. LoadState can:
// "not-found" means the unit is not there. Conflating them is what let a check
// stay red for a service that was up, while its auto_restart hammered a unit
// that could never start.
func (c *Checker) checkSystemd(svc ServiceConfig) error {
	args := systemctlArgs(svc, "show", svc.Unit+".service")
	args = append(args, "--property=LoadState", "--property=ActiveState", "--value")
	cmd := exec.Command("systemctl", args...)
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("unit %s: systemctl show failed: %v: %s",
			svc.Unit, err, strings.TrimSpace(string(out)))
	}

	lines := strings.Fields(strings.TrimSpace(string(out)))
	if len(lines) != 2 {
		return fmt.Errorf("unit %s: unparseable systemctl show output: %q", svc.Unit, string(out))
	}
	loadState, activeState := lines[0], lines[1]

	if loadState == "not-found" {
		return &UnitNotFoundError{Unit: svc.Unit, SystemUnit: svc.SystemUnit}
	}
	if activeState != "active" {
		return fmt.Errorf("unit %s is %s", svc.Unit, activeState)
	}
	return nil
}

// systemdIsEnabled returns the raw `systemctl is-enabled` output (e.g.
// "enabled", "disabled", "static", "masked"). Empty string on lookup error.
func systemdIsEnabled(svc ServiceConfig) string {
	args := systemctlArgs(svc, "is-enabled", svc.Unit)
	cmd := exec.Command("systemctl", args...)
	out, _ := cmd.Output()
	return strings.TrimSpace(string(out))
}

// ensureEnabled runs `systemctl enable` for a registered systemd service that
// is currently disabled. Logs loudly on failure so a permission/path issue
// surfaces in journalctl instead of silently leaving the service unbootable.
func (c *Checker) ensureEnabled(svc ServiceConfig) {
	args := systemctlArgs(svc, "enable", svc.Unit)
	cmd := exec.Command("systemctl", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("auto-enable failed for %s (unit=%s system=%v): %v: %s",
			svc.Name, svc.Unit, svc.SystemUnit, err, strings.TrimSpace(string(out)))
		return
	}
	log.Printf("auto-enabled %s (unit=%s system=%v)", svc.Name, svc.Unit, svc.SystemUnit)
}

func systemctlArgs(svc ServiceConfig, verb, unit string) []string {
	if svc.SystemUnit {
		return []string{verb, unit}
	}
	return []string{"--user", verb, unit}
}

func (c *Checker) checkCommand(svc ServiceConfig) error {
	if len(svc.Command) == 0 {
		return fmt.Errorf("no command specified")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, svc.Command[0], svc.Command[1:]...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("command failed: %v: %s", err, string(out))
	}
	if svc.ExpectOutput != "" && !strings.Contains(strings.ToLower(string(out)), strings.ToLower(svc.ExpectOutput)) {
		return fmt.Errorf("expected output containing %q, got: %s", svc.ExpectOutput, string(out))
	}
	return nil
}

func (c *Checker) restartService(svc ServiceConfig) {
	args := systemctlArgs(svc, "restart", svc.Unit)
	cmd := exec.Command("systemctl", args...)
	err := cmd.Run()
	success := err == nil
	if c.onRestart != nil {
		c.onRestart(svc.Name, success, err)
	}
}

func (c *Checker) runRecovery(svc ServiceConfig) {
	timeout := svc.RecoveryTimeout
	if timeout == 0 {
		timeout = 90 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, svc.RecoveryCommand[0], svc.RecoveryCommand[1:]...)
	out, err := cmd.CombinedOutput()
	success := err == nil
	if c.onRestart != nil {
		var reportErr error
		if err != nil {
			reportErr = fmt.Errorf("recovery_command: %v: %s", err, strings.TrimSpace(string(out)))
		}
		c.onRestart(svc.Name, success, reportErr)
	}
}

func (c *Checker) calcUptime24h(name string) float64 {
	records := c.history[name]
	cutoff := time.Now().Add(-24 * time.Hour)
	total := 0
	up := 0
	for _, r := range records {
		if r.timestamp.After(cutoff) {
			total++
			if r.up {
				up++
			}
		}
	}
	if total == 0 {
		return 100.0
	}
	return float64(up) / float64(total) * 100.0
}
