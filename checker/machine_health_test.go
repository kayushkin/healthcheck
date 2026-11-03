package checker

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

const fakeServiceToken = "service-token-for-tests-0123456789abcdef"

var fakeNow = time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)

// fakeBridge stands in for llm-bridge-server: it answers the three routes the
// machine checks call, and refuses a call without the service token the way
// the real one does.
type fakeBridge struct {
	mu            sync.Mutex
	localMachines []machineStatsOverview
	peers         []map[string]any
	// peerAnswers is, per connection id, the status code and the machines.
	peerStatus   map[string]int
	peerMachines map[string][]machineStatsOverview
}

func (bridge *fakeBridge) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if r.Header.Get("X-LLM-Bridge-Service-Token") != fakeServiceToken {
		w.WriteHeader(http.StatusUnauthorized)
		w.Write([]byte(`{"error":"unauthorized"}`))
		return
	}
	switch {
	case r.URL.Path == "/machines/stats":
		json.NewEncoder(w).Encode(bridge.localMachines)
	case r.URL.Path == "/peer-connections":
		json.NewEncoder(w).Encode(bridge.peers)
	case strings.HasPrefix(r.URL.Path, "/peer-connections/") && strings.HasSuffix(r.URL.Path, "/proxy/machines/stats"):
		id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/peer-connections/"), "/proxy/machines/stats")
		if status := bridge.peerStatus[id]; status != 0 && status != http.StatusOK {
			w.WriteHeader(status)
			w.Write([]byte(`{"error":"fake"}`))
			return
		}
		json.NewEncoder(w).Encode(bridge.peerMachines[id])
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func overviewOf(id, name string, collectedAt time.Time, drives []machineDrive, batteries []machineBattery) machineStatsOverview {
	var overview machineStatsOverview
	overview.Machine.ID = id
	overview.Machine.Name = name
	overview.Latest = &machineStats{CollectedAt: collectedAt, Drives: drives, Batteries: batteries}
	return overview
}

func gigabytes(n uint64) uint64 { return n << 30 }

type recordedStatusChange struct {
	name     string
	from, to Status
}

// newMachineHealthChecker builds a checker pointed at bridge, with the clock
// held at fakeNow, and records every status change it reports.
func newMachineHealthChecker(t *testing.T, bridge *fakeBridge, alertThreshold int, token string, alwaysOn []AlwaysOnMachine) (*Checker, *[]recordedStatusChange) {
	t.Helper()
	server := httptest.NewServer(bridge)
	t.Cleanup(server.Close)
	machineHealth := &MachineHealthConfig{AlwaysOnMachines: alwaysOn}
	if err := machineHealth.applyDefaultsAndValidate(); err != nil {
		t.Fatal(err)
	}
	c := New(&Config{
		AlertThreshold:        alertThreshold,
		LLMBridgeURL:          server.URL,
		LLMBridgeServiceToken: token,
		MachineHealth:         machineHealth,
	})
	c.now = func() time.Time { return fakeNow }
	var changes []recordedStatusChange
	var changesMu sync.Mutex
	c.OnChange(func(name string, from, to Status) {
		changesMu.Lock()
		defer changesMu.Unlock()
		changes = append(changes, recordedStatusChange{name, from, to})
	})
	return c, &changes
}

func machineResourceNamed(t *testing.T, c *Checker, name string) ResourceState {
	t.Helper()
	for _, state := range c.GetResourceStates() {
		if state.Name == name {
			return state
		}
	}
	var names []string
	for _, state := range c.GetResourceStates() {
		names = append(names, state.Name)
	}
	t.Fatalf("no resource named %q; have %q", name, names)
	return ResourceState{}
}

func hasResourceNamed(c *Checker, name string) bool {
	for _, state := range c.GetResourceStates() {
		if state.Name == name {
			return true
		}
	}
	return false
}

func TestDriveOverThresholdAlertsNamingMachineAndDrive(t *testing.T) {
	bridge := &fakeBridge{localMachines: []machineStatsOverview{
		overviewOf("m_desktop", "desktop", fakeNow.Add(-time.Minute), []machineDrive{
			{MountPoint: "C:", TotalBytes: gigabytes(100), UsedBytes: gigabytes(95), FreeBytes: gigabytes(5)},
			{MountPoint: "D:", TotalBytes: gigabytes(100), UsedBytes: gigabytes(40), FreeBytes: gigabytes(60)},
		}, nil),
	}}
	c, changes := newMachineHealthChecker(t, bridge, 2, fakeServiceToken, nil)

	c.checkMachineHealth()
	full := machineResourceNamed(t, c, "drive C: on desktop")
	if full.Status != StatusDegraded || !full.ThresholdBreached {
		t.Fatalf("after one breach want degraded and breached, got %s breached=%v", full.Status, full.ThresholdBreached)
	}
	c.checkMachineHealth()
	full = machineResourceNamed(t, c, "drive C: on desktop")
	if full.Status != StatusDown {
		t.Fatalf("after alert_threshold breaches want down, got %s (%s)", full.Status, full.LastError)
	}
	if full.UsagePct < 94.9 || full.UsagePct > 95.1 || full.MachineID != "m_desktop" || full.DriveMountPoint != "C:" {
		t.Errorf("unexpected drive row: %+v", full)
	}
	if roomy := machineResourceNamed(t, c, "drive D: on desktop"); roomy.Status != StatusUp {
		t.Errorf("a 40%% full drive should be up, got %s", roomy.Status)
	}
	sawDown := false
	for _, change := range *changes {
		if change.name == "drive C: on desktop" && change.to == StatusDown {
			sawDown = true
		}
	}
	if !sawDown {
		t.Errorf("no down alert named after the machine and drive; changes: %+v", *changes)
	}
}

func TestLowBatteryAlertsOnlyWhileDischarging(t *testing.T) {
	bridge := &fakeBridge{localMachines: []machineStatsOverview{
		overviewOf("m_laptop_a", "laptop-a", fakeNow, nil, []machineBattery{{Name: "BAT0", ChargePercent: 10, State: "discharging"}}),
		overviewOf("m_laptop_b", "laptop-b", fakeNow, nil, []machineBattery{{Name: "BAT0", ChargePercent: 10, State: "charging"}}),
	}}
	c, _ := newMachineHealthChecker(t, bridge, 1, fakeServiceToken, nil)
	c.checkMachineHealth()

	discharging := machineResourceNamed(t, c, "battery BAT0 on laptop-a")
	if discharging.Status != StatusDown || !discharging.ThresholdBreached {
		t.Errorf("10%% and discharging should be down, got %s: %+v", discharging.Status, discharging)
	}
	if !strings.Contains(discharging.LastError, "10%") {
		t.Errorf("the alert should give the charge: %q", discharging.LastError)
	}
	charging := machineResourceNamed(t, c, "battery BAT0 on laptop-b")
	if charging.Status != StatusUp || charging.ThresholdBreached {
		t.Errorf("10%% and charging should be up, got %s", charging.Status)
	}
}

func TestStaleSampleAlertsOnlyForAlwaysOnMachines(t *testing.T) {
	old := fakeNow.Add(-2 * time.Hour)
	bridge := &fakeBridge{localMachines: []machineStatsOverview{
		overviewOf("m_server", "server", old, []machineDrive{{MountPoint: "/", TotalBytes: 100, UsedBytes: 99, FreeBytes: 1}}, nil),
		overviewOf("m_laptop", "laptop", old, []machineDrive{{MountPoint: "/", TotalBytes: 100, UsedBytes: 99, FreeBytes: 1}},
			[]machineBattery{{Name: "BAT0", ChargePercent: 3, State: "discharging"}}),
	}}
	c, changes := newMachineHealthChecker(t, bridge, 1, fakeServiceToken, []AlwaysOnMachine{{MachineID: "m_server"}})
	c.checkMachineHealth()

	if server := machineResourceNamed(t, c, "server reporting"); server.Status != StatusDown {
		t.Errorf("an always-on machine silent for 2h should be down, got %s (%s)", server.Status, server.Detail)
	}
	laptop := machineResourceNamed(t, c, "laptop reporting")
	if laptop.Status != StatusUnknown {
		t.Errorf("a laptop silent for 2h should be unknown, not alerting; got %s", laptop.Status)
	}
	// An old sample is not judged: a full drive or a flat battery from two
	// hours ago says nothing about now.
	for _, name := range []string{"drive / on server", "drive / on laptop", "battery BAT0 on laptop"} {
		if state := machineResourceNamed(t, c, name); state.Status != StatusUnknown || state.ThresholdBreached {
			t.Errorf("%s from a stale sample should be unknown and unbreached, got %s", name, state.Status)
		}
	}
	for _, change := range *changes {
		if change.to == StatusDown && change.name != "server reporting" {
			t.Errorf("only the always-on machine's silence should alert; got %+v", change)
		}
	}

	// It reports again: the always-on machine comes back up.
	bridge.mu.Lock()
	bridge.localMachines[0].Latest.CollectedAt = fakeNow
	bridge.mu.Unlock()
	c.checkMachineHealth()
	if server := machineResourceNamed(t, c, "server reporting"); server.Status != StatusUp {
		t.Errorf("after a fresh sample want up, got %s", server.Status)
	}
}

func TestPeerWithoutMachineStatsRouteIsNotAnOutage(t *testing.T) {
	bridge := &fakeBridge{
		peers: []map[string]any{
			{"connection": map[string]any{"id": "peer_old"}, "access_held": map[string]any{}, "other_server_name": "old-build", "other_server_id": "server_old"},
			{"connection": map[string]any{"id": "peer_new"}, "access_held": map[string]any{}, "other_server_name": "new-build", "other_server_id": "server_new"},
			// Without access held there is nothing to read; it is skipped.
			{"connection": map[string]any{"id": "peer_no_access"}, "other_server_name": "no-access"},
		},
		peerStatus: map[string]int{"peer_old": http.StatusNotFound, "peer_no_access": http.StatusForbidden},
		peerMachines: map[string][]machineStatsOverview{
			"peer_new": {overviewOf("m_far", "far-laptop", fakeNow, []machineDrive{{MountPoint: "/", TotalBytes: 100, UsedBytes: 95, FreeBytes: 5}}, nil)},
		},
	}
	c, changes := newMachineHealthChecker(t, bridge, 1, fakeServiceToken, nil)
	c.checkMachineHealth()
	c.checkMachineHealth()

	old := machineResourceNamed(t, c, "machine stats from old-build")
	if old.Status != StatusUnknown || !strings.Contains(old.Detail, "not reporting yet") {
		t.Errorf("a 404 from a peer should read not-reporting-yet and unknown, got %s %q", old.Status, old.Detail)
	}
	if hasResourceNamed(c, "machine stats from no-access") {
		t.Error("a connection with no access held should not be read")
	}
	far := machineResourceNamed(t, c, "drive / on far-laptop via new-build")
	if far.Status != StatusDown || far.PeerServerID != "server_new" || far.PeerConnectionID != "peer_new" {
		t.Errorf("a peer's full drive should be down and carry the server: %+v", far)
	}
	for _, change := range *changes {
		if strings.Contains(change.name, "old-build") && change.to != StatusUnknown {
			t.Errorf("the old-build peer should never alert: %+v", change)
		}
	}
}

func TestAuthorizationFailureSurfacesAsAnAlert(t *testing.T) {
	for _, testCase := range []struct{ description, token, wantInError string }{
		{"wrong token", "not-the-token-0123456789abcdef0123", "401"},
		{"no token", "", "LLMBRIDGE_SERVICE_TOKEN is not set"},
	} {
		t.Run(testCase.description, func(t *testing.T) {
			c, changes := newMachineHealthChecker(t, &fakeBridge{}, 2, testCase.token, nil)
			c.checkMachineHealth()
			source := machineResourceNamed(t, c, "machine stats from this server")
			if source.Status != StatusDegraded {
				t.Errorf("one failed read should be degraded, got %s", source.Status)
			}
			c.checkMachineHealth()
			source = machineResourceNamed(t, c, "machine stats from this server")
			if source.Status != StatusDown || !strings.Contains(source.LastError, testCase.wantInError) {
				t.Errorf("want down with %q in the error, got %s %q", testCase.wantInError, source.Status, source.LastError)
			}
			if len(*changes) == 0 || (*changes)[len(*changes)-1].to != StatusDown {
				t.Errorf("an auth failure must alert, got changes %+v", *changes)
			}
		})
	}
}

func TestPeerAuthorizationFailureAlerts(t *testing.T) {
	bridge := &fakeBridge{
		peers:      []map[string]any{{"connection": map[string]any{"id": "peer_a"}, "access_held": map[string]any{}, "other_server_name": "laptop-server"}},
		peerStatus: map[string]int{"peer_a": http.StatusForbidden},
	}
	c, _ := newMachineHealthChecker(t, bridge, 1, fakeServiceToken, nil)
	c.checkMachineHealth()
	if source := machineResourceNamed(t, c, "machine stats from laptop-server"); source.Status != StatusDown {
		t.Errorf("a 403 from a peer should alert, got %s", source.Status)
	}
}

// An asleep peer answers 503. Its machines stay on the page from the last
// answer, and an always-on one among them alerts once its sample ages.
func TestUnreachablePeerKeepsLastAnswerAndAgesIt(t *testing.T) {
	bridge := &fakeBridge{
		peers: []map[string]any{{"connection": map[string]any{"id": "peer_a"}, "access_held": map[string]any{}, "other_server_name": "far", "other_server_id": "server_far"}},
		peerMachines: map[string][]machineStatsOverview{
			"peer_a": {overviewOf("m_box", "box", fakeNow, nil, nil)},
		},
	}
	c, _ := newMachineHealthChecker(t, bridge, 1, fakeServiceToken, []AlwaysOnMachine{{PeerServerID: "server_far", MachineID: "m_box"}})
	c.checkMachineHealth()
	if box := machineResourceNamed(t, c, "box via far reporting"); box.Status != StatusUp {
		t.Fatalf("fresh sample should be up, got %s", box.Status)
	}

	bridge.mu.Lock()
	bridge.peerStatus = map[string]int{"peer_a": http.StatusServiceUnavailable}
	bridge.mu.Unlock()
	c.now = func() time.Time { return fakeNow.Add(time.Hour) }
	c.checkMachineHealth()

	if source := machineResourceNamed(t, c, "machine stats from far"); source.Status != StatusUnknown {
		t.Errorf("an unreachable peer should be unknown, not an alert of its own; got %s", source.Status)
	}
	if box := machineResourceNamed(t, c, "box via far reporting"); box.Status != StatusDown {
		t.Errorf("an always-on machine behind an unreachable peer should go down as it ages, got %s", box.Status)
	}
}

func TestMachineResourcesVanishWhenTheirMachineDoes(t *testing.T) {
	bridge := &fakeBridge{localMachines: []machineStatsOverview{
		overviewOf("m_a", "a", fakeNow, []machineDrive{{MountPoint: "/", TotalBytes: 10, UsedBytes: 1, FreeBytes: 9}}, nil),
	}}
	c, _ := newMachineHealthChecker(t, bridge, 1, fakeServiceToken, nil)
	c.checkMachineHealth()
	machineResourceNamed(t, c, "drive / on a")

	bridge.mu.Lock()
	bridge.localMachines = nil
	bridge.mu.Unlock()
	c.checkMachineHealth()
	if hasResourceNamed(c, "drive / on a") || hasResourceNamed(c, "a reporting") {
		t.Error("a machine the bridge no longer lists should leave the status page")
	}
}

func TestMachineHealthConfigDefaults(t *testing.T) {
	machineHealth := &MachineHealthConfig{}
	if err := machineHealth.applyDefaultsAndValidate(); err != nil {
		t.Fatal(err)
	}
	if machineHealth.DriveUsageThresholdPercent != 90 || machineHealth.BatteryLowChargeThresholdPercent != 15 || machineHealth.StaleAfter != 10*time.Minute {
		t.Errorf("unexpected defaults: %+v", machineHealth)
	}
	if err := (&MachineHealthConfig{AlwaysOnMachines: []AlwaysOnMachine{{}}}).applyDefaultsAndValidate(); err == nil {
		t.Error("an always-on entry with no machine_id should be refused")
	}
}
