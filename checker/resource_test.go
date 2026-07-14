package checker

import (
	"testing"
	"time"
)

// TestFailedMeasurementDoesNotSpawnCCAgent pins the expensive half of the
// 2026-07-13 OOM.
//
// A check that cannot MEASURE is not a check that found a breach. UsagePct
// still holds the last good reading, so a resource that is perfectly healthy
// can land in StatusDown carrying a reassuring number. When the gate for
// spawning a remediation agent was `Status == StatusDown`, memory pressure
// made the disk check time out and healthcheck spawned six Claude Code agents
// for a disk that was 25% full — each logging the flatly false "spawning
// bridge session for disk-root alert (25.0% >= 90.0%)", and each a fresh
// ~300MB process on a box that was already dying of memory exhaustion.
//
// The remediation gate must be a real measurement that really exceeded the
// threshold, never merely "the check is unhappy".
func TestFailedMeasurementDoesNotSpawnCCAgent(t *testing.T) {
	c := New(&Config{AlertThreshold: 1}) // fire on the very first failure

	res := ResourceConfig{
		Name:      "phantom-disk",
		Type:      "disk",
		Path:      "/definitely/not/a/mounted/path",
		Threshold: 90,
		CCAgent:   true, // armed, exactly as disk-root and memory are in config.yaml
	}
	c.resourceStates[res.Name] = &ResourceState{Name: res.Name, Type: res.Type, Status: StatusUnknown}

	// Check repeatedly: the historical bug was not one spawn, it was six.
	for i := 0; i < 6; i++ {
		c.checkResource(res)
	}
	// spawnCCAgent is launched with `go`, so give it room to have misfired.
	time.Sleep(250 * time.Millisecond)

	got := resourceState(t, c, res.Name)

	if got.ThresholdBreached {
		t.Error("a check that failed to measure must not report ThresholdBreached — " +
			"nothing was measured, so nothing can have exceeded the threshold")
	}
	if got.CCAgentAttempts != 0 {
		t.Errorf("spawned %d remediation agent(s) for a resource whose check merely "+
			"errored — this is the six-agents-on-a-dying-box bug; a broken check has "+
			"nothing for an agent to remediate", got.CCAgentAttempts)
	}
}

// TestHealthyResourceUnderThresholdSpawnsNothing guards the ordinary path: a
// resource comfortably under its threshold is up, unbreached, and untouched.
func TestHealthyResourceUnderThresholdSpawnsNothing(t *testing.T) {
	c := New(&Config{AlertThreshold: 1})

	res := ResourceConfig{
		Name: "root", Type: "disk", Path: "/",
		Threshold: 99.9, // a real, readable mount that is not this full
		CCAgent:   true,
	}
	c.resourceStates[res.Name] = &ResourceState{Name: res.Name, Type: res.Type, Status: StatusUnknown}

	c.checkResource(res)
	time.Sleep(100 * time.Millisecond)

	got := resourceState(t, c, res.Name)

	if got.Status != StatusUp {
		t.Errorf("a resource under its threshold must be %q, got %q (usage %.1f%%)",
			StatusUp, got.Status, got.UsagePct)
	}
	if got.ThresholdBreached {
		t.Errorf("usage %.1f%% is under the %.1f%% threshold — ThresholdBreached must be false",
			got.UsagePct, res.Threshold)
	}
	if got.CCAgentAttempts != 0 {
		t.Errorf("spawned %d remediation agent(s) for a healthy resource", got.CCAgentAttempts)
	}
}

func resourceState(t *testing.T, c *Checker, name string) ResourceState {
	t.Helper()
	for _, s := range c.GetResourceStates() {
		if s.Name == name {
			return s
		}
	}
	t.Fatalf("no state recorded for resource %q", name)
	return ResourceState{}
}
