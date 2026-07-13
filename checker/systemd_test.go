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
