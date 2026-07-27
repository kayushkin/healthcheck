package checker

import (
	"errors"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// userManagerReachable reports whether `systemctl --user` can actually answer
// here. It returns empty output rather than an error when XDG_RUNTIME_DIR /
// DBUS_SESSION_BUS_ADDRESS are missing, so a test that assumed it worked would
// read that silence as a finding. Skip instead of lying.
func userManagerReachable(t *testing.T) {
	t.Helper()
	out, err := exec.Command("systemctl", "--user", "show", "-p", "Version", "--value").Output()
	if err != nil || strings.TrimSpace(string(out)) == "" {
		t.Skip("systemctl --user not reachable from this environment (needs XDG_RUNTIME_DIR + DBUS_SESSION_BUS_ADDRESS)")
	}
}

// TestCheckSystemdDistinguishesMissingUnitFromStoppedUnit is the core property.
// `systemctl is-active` prints "inactive" for BOTH a stopped unit and a unit
// that does not exist, which is why a check pointed at the wrong systemd
// manager looked merely "down" instead of broken. checkSystemd must tell them
// apart.
func TestCheckSystemdDistinguishesMissingUnitFromStoppedUnit(t *testing.T) {
	userManagerReachable(t)

	c := New(&Config{AlertThreshold: 3})

	// A unit that exists under no manager: the config-bug case.
	missing := ServiceConfig{
		Name: "phantom", Type: "systemd",
		Unit: "healthcheck-test-definitely-not-a-real-unit",
	}
	err := c.checkSystemd(missing)
	if err == nil {
		t.Fatal("expected an error for a unit that does not exist")
	}
	var notFound *UnitNotFoundError
	if !errors.As(err, &notFound) {
		t.Fatalf("a nonexistent unit must surface as *UnitNotFoundError (a config bug), got %T: %v", err, err)
	}
	if !strings.Contains(err.Error(), "watching nothing") {
		t.Errorf("error should say the check is watching nothing, got: %v", err)
	}
	// The message must name the fix, since the whole point is that a human has
	// to correct system_unit.
	if !strings.Contains(err.Error(), "system_unit") {
		t.Errorf("error should name the system_unit flag as the fix, got: %v", err)
	}
}

// TestMisconfiguredCheckDoesNotDriveAutoRestart pins the destructive half.
// healthcheck's auto_restart on a check that was watching a phantom unit drove
// an 811,295-restart crash loop. A check that cannot find its unit must never
// ask systemd to restart it — there is nothing to restart, and the retry is
// unbounded.
func TestMisconfiguredCheckDoesNotDriveAutoRestart(t *testing.T) {
	userManagerReachable(t)

	c := New(&Config{AlertThreshold: 1}) // fire on the very first failure

	restarted := make(chan string, 8)
	c.OnRestart(func(name string, success bool, err error) { restarted <- name })

	svc := ServiceConfig{
		Name: "phantom", Type: "systemd",
		Unit:        "healthcheck-test-definitely-not-a-real-unit",
		AutoRestart: true, // armed, exactly as every real entry in config.yaml is
	}
	c.states[svc.Name] = &ServiceState{Name: svc.Name, Type: svc.Type, Status: StatusUnknown}

	// Check repeatedly: the historical bug was not one restart, it was a loop.
	for i := 0; i < 5; i++ {
		c.checkService(svc)
	}

	states := c.GetStates()
	var got *ServiceState
	for i := range states {
		if states[i].Name == "phantom" {
			got = &states[i]
		}
	}
	if got == nil {
		t.Fatal("no state recorded for the phantom service")
	}
	if got.Status != StatusMisconfigured {
		t.Errorf("a check watching a nonexistent unit must be %q, not %q — "+
			"%q would mean the SERVICE is broken, when in fact the CHECK is",
			StatusMisconfigured, got.Status, got.Status)
	}

	// restartService is spawned via `go`, so give it room to have misfired.
	select {
	case name := <-restarted:
		t.Fatalf("auto_restart fired for misconfigured check %q — this is the "+
			"811k-restart crash loop; a phantom unit must never be restarted", name)
	case <-time.After(250 * time.Millisecond):
	}
}

// TestCheckSystemdReportsRealRunningUnit guards the other direction: the new
// LoadState-based probe must still recognise a genuinely healthy unit, and must
// not trip over a unit whose drop-in is root-only (`systemctl cat` exits
// non-zero on a permission-denied drop-in even though the unit loads fine —
// which is exactly why this code does not shell out to `cat`).
func TestCheckSystemdReportsRealRunningUnit(t *testing.T) {
	userManagerReachable(t)

	c := New(&Config{AlertThreshold: 3})
	// noteboard is a --user unit and is expected up on this host.
	svc := ServiceConfig{Name: "noteboard", Type: "systemd", Unit: "noteboard"}

	if err := c.checkSystemd(svc); err != nil {
		t.Skipf("noteboard not running locally, cannot assert the happy path: %v", err)
	}

	var notFound *UnitNotFoundError
	if errors.As(error(nil), &notFound) {
		t.Fatal("unreachable")
	}
}

// TestAutoRestartIsBounded pins the second half of the crash-loop class. The
// misconfigured guard above only catches a unit that does not exist. A unit that
// exists, loads, and can never start — because another process holds its port —
// stays StatusDown forever, and auto_restart used to fire on every single check
// interval against it: 1,325 futile `systemctl restart` calls in 24h on this
// host, indefinitely.
//
// The budget is asserted directly on the state rather than by counting restarts
// over a wall-clock window, so the test cannot go flaky under load.
func TestAutoRestartIsBounded(t *testing.T) {
	state := &ServiceState{Name: "stuck", Type: "systemd", Status: StatusDown}

	attempts, suppressions := 0, 0
	// Far more rounds than the budget: the historical bug was not one restart too
	// many, it was that the retries never stopped.
	for i := 0; i < maxConsecutiveAutoRestarts*20; i++ {
		allowed, suppressedNow := state.authorizeAutoRestart(maxConsecutiveAutoRestarts)
		if allowed {
			attempts++
		}
		if suppressedNow {
			suppressions++
		}
	}

	if attempts != maxConsecutiveAutoRestarts {
		t.Errorf("auto_restart fired %d times, want exactly %d — an unbounded retry "+
			"against a unit that can never start is the 811k/167k-restart crash loop",
			attempts, maxConsecutiveAutoRestarts)
	}
	// Exactly one, or the suppression notice becomes the new per-interval spam.
	if suppressions != 1 {
		t.Errorf("suppression reported %d times, want exactly 1 — logging it on every "+
			"later check would just replace one unbounded log stream with another",
			suppressions)
	}
	if !state.RestartSuppressed {
		t.Error("state must record RestartSuppressed so a given-up service is visibly " +
			"distinct in /api/status from one still being retried")
	}
}

// TestFlappingUnitCannotRefillItsRestartBudget pins the hole the first version of
// the budget left open, found by watching the real check for an hour rather than
// for three minutes.
//
// A unit with the default Type=simple counts as "active" from the instant systemd
// forks it, so one stuck in a bind-fail restart loop reports active for a fraction
// of every cycle. A single probe landing in that window looks like recovery. When
// one healthy check was enough to refill the budget, that happened about once an
// hour and bought five more futile restarts each time — the loop was throttled,
// not stopped. Recovery must mean the service is still there at the next check.
func TestFlappingUnitCannotRefillItsRestartBudget(t *testing.T) {
	state := &ServiceState{Name: "flapper", Type: "systemd", Status: StatusDown}

	spend := func() int {
		fired := 0
		for i := 0; i < maxConsecutiveAutoRestarts*3; i++ {
			if allowed, _ := state.authorizeAutoRestart(maxConsecutiveAutoRestarts); allowed {
				fired++
			}
		}
		return fired
	}
	// One healthy blip, exactly as a mid-restart-loop probe would see.
	blip := func() {
		state.ConsecutiveFails = 0
		state.ConsecutiveOKs++
		if state.ConsecutiveOKs >= minHealthyChecksToRearmAutoRestart {
			state.RestartAttempts = 0
			state.RestartSuppressed = false
		}
	}
	fail := func() { state.ConsecutiveFails++; state.ConsecutiveOKs = 0 }

	if got := spend(); got != maxConsecutiveAutoRestarts {
		t.Fatalf("first outage fired %d restarts, want %d", got, maxConsecutiveAutoRestarts)
	}

	// Three separate blips, each immediately followed by failure again — the
	// flapping pattern. None is a recovery, so none may refill the budget.
	for round := 0; round < 3; round++ {
		blip()
		fail()
		if got := spend(); got != 0 {
			t.Fatalf("a lone healthy blip refilled the budget and bought %d more restarts "+
				"in round %d — a unit that is down again at the very next check has not "+
				"recovered, and this is how the loop stayed alive at ~5 restarts/hour",
				got, round)
		}
	}

	// A real recovery — healthy on consecutive checks — must still refill it.
	for i := 0; i < minHealthyChecksToRearmAutoRestart; i++ {
		blip()
	}
	if got := spend(); got != maxConsecutiveAutoRestarts {
		t.Errorf("after %d consecutive healthy checks the budget must refill, got %d restarts",
			minHealthyChecksToRearmAutoRestart, got)
	}
}

// TestAutoRestartBudgetRearmsAfterRecovery guards the opposite direction: the
// budget bounds a single continuous outage, not the service's whole lifetime. A
// service that failed, was restarted, came back, and later fails again must get a
// full budget the second time — otherwise auto_restart silently stops working for
// every service that has ever flapped.
func TestAutoRestartBudgetRearmsAfterRecovery(t *testing.T) {
	userManagerReachable(t)

	c := New(&Config{AlertThreshold: 1})
	svc := ServiceConfig{Name: "noteboard", Type: "systemd", Unit: "noteboard", AutoRestart: true}
	if err := c.checkSystemd(svc); err != nil {
		t.Skipf("noteboard not running locally, cannot drive a real recovery: %v", err)
	}

	c.states[svc.Name] = &ServiceState{
		Name: svc.Name, Type: svc.Type, Status: StatusDown,
		RestartAttempts: maxConsecutiveAutoRestarts, RestartSuppressed: true,
	}

	// Sustained health must clear the exhausted budget. One check is deliberately
	// not enough (see TestFlappingUnitCannotRefillItsRestartBudget), so drive the
	// full re-arm threshold against the real live unit.
	for i := 0; i < minHealthyChecksToRearmAutoRestart; i++ {
		c.checkService(svc)
	}

	state := c.states[svc.Name]
	if state.Status != StatusUp {
		t.Fatalf("expected the live noteboard unit to check out up, got %q", state.Status)
	}
	if state.RestartSuppressed || state.RestartAttempts != 0 {
		t.Errorf("a service that reported healthy must get its auto_restart budget back, "+
			"got attempts=%d suppressed=%v", state.RestartAttempts, state.RestartSuppressed)
	}
}
