package checker

import (
	"testing"
	"time"
)

// TestAMisconfiguredCheckDoesNotWriteSystemdState is the enable-side twin of
// TestMisconfiguredCheckDoesNotDriveAutoRestart. That test pins the rule for
// `systemctl restart`; auto-enable was gated on nothing at all — not
// auto_restart, not recovery_command, not the misconfigured suppression — so a
// check that reported "misconfigured" could still write systemd state.
//
// The unit is named with a ".service" suffix on purpose. That is the shape that
// actually reaches the defect, and it is not the shape the gap sounds like:
// checkSystemd probes svc.Unit+".service" while systemdIsEnabled probes svc.Unit
// bare, so a configured "x.service" asks about "x.service.service" (not-found,
// hence misconfigured) while is-enabled answers for the real unit x. A plain
// phantom never gets here, because is-enabled answers "not-found" rather than
// "disabled" — so the unit this guard protects is a LIVE one.
func TestAMisconfiguredCheckDoesNotWriteSystemdState(t *testing.T) {
	c := New(&Config{AlertThreshold: 1})

	enabled := make(chan string, 8)
	c.enableUnit = func(svc ServiceConfig) (string, error) {
		enabled <- svc.Unit
		return "", nil
	}

	svc := ServiceConfig{
		Name: "suffixed", Type: "systemd",
		Unit: "healthcheck-test-definitely-not-a-real-unit.service",
	}
	c.states[svc.Name] = &ServiceState{Name: svc.Name, Type: svc.Type, Status: StatusUnknown}

	// Drive the decision directly rather than shelling out, so the assertion
	// holds on a host where `systemctl --user` cannot answer.
	if shouldEnsureEnabled(svc, "disabled", true) {
		t.Error("a misconfigured check must not be enabled: the check is watching " +
			"nothing, so nothing it reports about its unit is worth acting on")
	}

	// And prove checkService consults that decision, not a condition of its own.
	// Without this, deleting the !misconfigured term leaves the test above green.
	//
	// The enablement probe is substituted to report "disabled". That is not
	// convenience: a unit that does not exist answers "not-found", so a test
	// built on a phantom alone reaches the enable branch under NO condition and
	// passes by being unable to fail. Reporting "disabled" against a unit
	// checkSystemd cannot find is exactly the suffixed-name case, and it is the
	// only input on which this assertion can discriminate.
	c.isEnabled = func(ServiceConfig) string { return "disabled" }
	userManagerReachable(t)
	for i := 0; i < 3; i++ {
		c.checkService(svc)
	}
	select {
	case unit := <-enabled:
		t.Fatalf("auto-enable fired for misconfigured check on unit %q — "+
			"healthcheck wrote systemd state off a check that is watching nothing", unit)
	case <-time.After(250 * time.Millisecond):
	}
}

// TestAHealthyDisabledCheckIsStillEnabled is the negative control. The guard
// above must not be a blanket refusal: a well-configured systemd check that
// systemd reports "disabled" is exactly the case auto-enable exists for, and a
// fix that suppressed it too would pass the test above by doing nothing.
func TestAHealthyDisabledCheckIsStillEnabled(t *testing.T) {
	svc := ServiceConfig{Name: "ordinary", Type: "systemd", Unit: "ordinary"}
	if !shouldEnsureEnabled(svc, "disabled", false) {
		t.Error("a disabled unit on a check that is NOT misconfigured must still be " +
			"enabled — the registry is the source of truth for what runs at boot")
	}
}

// TestTheEnableDecisionIsTakenOnMeasuredSystemctlOutput pins the decision against
// the states `systemctl is-enabled` actually emits, rather than against the two
// the original condition implied. "not-found" is the measured answer for a unit
// that does not exist — systemd prints it on stdout and exits 4 — which is why a
// plain phantom was never the reachable case.
func TestTheEnableDecisionIsTakenOnMeasuredSystemctlOutput(t *testing.T) {
	svc := ServiceConfig{Name: "s", Type: "systemd", Unit: "s"}
	cases := []struct {
		enabledState string
		misconfigured,
		want bool
		why string
	}{
		{"disabled", false, true, "the case auto-enable exists for"},
		{"disabled", true, false, "the guard this test file was added for"},
		{"not-found", false, false, "a unit that does not exist cannot be enabled"},
		{"not-found", true, false, "a plain phantom: not-found, never disabled"},
		{"enabled", false, false, "already enabled, nothing to do"},
		{"static", false, false, "static units have no enablement to write"},
		{"masked", false, false, "masked is a deliberate operator choice"},
		{"", false, false, "no answer at all: an unreachable manager is not a finding"},
	}
	for _, tc := range cases {
		got := shouldEnsureEnabled(svc, tc.enabledState, tc.misconfigured)
		if got != tc.want {
			t.Errorf("shouldEnsureEnabled(is-enabled=%q, misconfigured=%v) = %v, want %v — %s",
				tc.enabledState, tc.misconfigured, got, tc.want, tc.why)
		}
	}
}

// TestOnlySystemdChecksAreEnabled guards the type term. An http or command check
// has no unit to enable, and reaching systemctl for one would be a category error.
func TestOnlySystemdChecksAreEnabled(t *testing.T) {
	for _, typ := range []string{"http", "command", "", "unknown"} {
		svc := ServiceConfig{Name: "s", Type: typ, Unit: "s"}
		if shouldEnsureEnabled(svc, "disabled", false) {
			t.Errorf("a %q check has no systemd unit to enable", typ)
		}
	}
}
