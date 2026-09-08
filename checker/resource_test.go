package checker

import (
	"fmt"
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

// scriptedResource drives checkResource through a sequence of (usage, clock)
// samples without touching a real disk or waiting on a real clock.
type scriptedResource struct {
	c       *Checker
	res     ResourceConfig
	started time.Time
}

func newScriptedResource(t *testing.T) *scriptedResource {
	t.Helper()
	c := New(&Config{AlertThreshold: 1}) // one breached sample is Down
	res := ResourceConfig{Name: "memory", Type: "memory", Threshold: 90, CCAgent: true}
	c.resourceStates[res.Name] = &ResourceState{Name: res.Name, Type: res.Type, Status: StatusUnknown}
	return &scriptedResource{c: c, res: res, started: time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)}
}

// sample records one measurement at `at` minutes after the start.
func (s *scriptedResource) sample(usagePct float64, atMinutes int) ResourceState {
	s.c.measureResource = func(ResourceConfig) (float64, string, error) { return usagePct, "scripted", nil }
	s.c.now = func() time.Time { return s.started.Add(time.Duration(atMinutes) * time.Minute) }
	s.c.checkResource(s.res)
	return *s.c.resourceStates[s.res.Name]
}

// TestOneHealthySampleBetweenTwoBreachesDoesNotResetTheCCAgentCap pins the
// 2026-09-04/05 amplifier. Memory sat at 90-92% and crossed the threshold
// every few minutes; every dip under it wiped the attempt count AND the
// cooldown, so a cap of "3 attempts, 30 minutes apart" spawned 16 Claude Code
// remediation agents — some 10 minutes apart — onto a box with 0.5 GB free.
func TestOneHealthySampleBetweenTwoBreachesDoesNotResetTheCCAgentCap(t *testing.T) {
	s := newScriptedResource(t)

	first := s.sample(95, 0) // breach → Down → first agent
	if first.CCAgentAttempts != 1 {
		t.Fatalf("first breach: want 1 attempt, got %d", first.CCAgentAttempts)
	}
	firstSpawn := first.LastCCAgentAt

	dip := s.sample(85, 5) // one sample under the threshold, five minutes on
	if dip.Status != StatusUp {
		t.Fatalf("dip: want %q, got %q", StatusUp, dip.Status)
	}
	if dip.CCAgentAttempts != 1 || !dip.LastCCAgentAt.Equal(firstSpawn) {
		t.Errorf("a single healthy sample reset the cap: attempts=%d lastSpawn=%v (want 1, %v) — "+
			"this is the flap that spawned 16 agents against a cap of 3", dip.CCAgentAttempts, dip.LastCCAgentAt, firstSpawn)
	}

	again := s.sample(95, 10) // back over the line inside the 30-minute cooldown
	if again.CCAgentAttempts != 1 || !again.LastCCAgentAt.Equal(firstSpawn) {
		t.Errorf("re-breach inside the cooldown spawned again: attempts=%d lastSpawn=%v (want 1, %v)",
			again.CCAgentAttempts, again.LastCCAgentAt, firstSpawn)
	}
}

// TestSustainedRecoveryForgivesTheCCAgentCap guards the other direction: a
// resource that stays under its threshold for the full window earns a clean
// slate, so a genuinely new incident weeks later is not treated as attempt #4.
func TestSustainedRecoveryForgivesTheCCAgentCap(t *testing.T) {
	s := newScriptedResource(t)

	s.sample(95, 0)
	s.sample(85, 5)
	mid := s.sample(85, 20) // healthy for 15 minutes: not yet
	if mid.CCAgentAttempts != 1 {
		t.Errorf("15 healthy minutes forgave the cap early: attempts=%d", mid.CCAgentAttempts)
	}
	done := s.sample(85, 36) // healthy for 31 minutes: forgiven
	if done.CCAgentAttempts != 0 || !done.LastCCAgentAt.IsZero() || done.CCAgentGaveUp {
		t.Errorf("31 healthy minutes did not forgive the cap: attempts=%d lastSpawn=%v gaveUp=%v",
			done.CCAgentAttempts, done.LastCCAgentAt, done.CCAgentGaveUp)
	}

	fresh := s.sample(95, 40) // a new incident after real recovery spawns normally
	if fresh.CCAgentAttempts != 1 {
		t.Errorf("post-recovery breach: want 1 attempt, got %d", fresh.CCAgentAttempts)
	}
}

// TestFailedMeasurementDoesNotCountAsRecovery: a check that could not read the
// resource contributes nothing to the recovery window, in either direction.
func TestFailedMeasurementDoesNotCountAsRecovery(t *testing.T) {
	s := newScriptedResource(t)
	s.sample(95, 0)
	s.sample(85, 5)
	s.c.measureResource = func(ResourceConfig) (float64, string, error) { return 0, "", fmt.Errorf("free: timed out") }
	s.c.now = func() time.Time { return s.started.Add(40 * time.Minute) }
	s.c.checkResource(s.res)
	got := *s.c.resourceStates[s.res.Name]
	if got.CCAgentAttempts != 1 {
		t.Errorf("an unmeasured sample at +40m forgave the cap: attempts=%d", got.CCAgentAttempts)
	}
	if !got.UnderThresholdSince.IsZero() {
		t.Errorf("an unmeasured sample left the recovery clock running: %v", got.UnderThresholdSince)
	}
}
