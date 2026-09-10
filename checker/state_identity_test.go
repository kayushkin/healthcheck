package checker

import "testing"

// The status a consumer reads must carry what identifies the checked thing —
// the unit or the URL — not only the display name. llm-bridge-server's service
// inventory joins on these to find the process, and a blank one there would
// mean "no process" rather than "config not surfaced".
func TestStatesCarryUnitAndURLFromConfig(t *testing.T) {
	c := New(&Config{Services: []ServiceConfig{
		{Name: "dash", Type: "systemd", Unit: "dash-server"},
		{Name: "bridge", Type: "systemd", Unit: "llm-bridge", SystemUnit: true},
		{Name: "marginalia", Type: "http", URL: "http://localhost:8192/health"},
	}})
	got := map[string]ServiceState{}
	for _, s := range c.GetStates() {
		got[s.Name] = s
	}
	if got["dash"].Unit != "dash-server" || got["dash"].SystemUnit {
		t.Fatalf("dash: unit=%q system_unit=%v", got["dash"].Unit, got["dash"].SystemUnit)
	}
	if got["bridge"].Unit != "llm-bridge" || !got["bridge"].SystemUnit {
		t.Fatalf("bridge: unit=%q system_unit=%v", got["bridge"].Unit, got["bridge"].SystemUnit)
	}
	if got["marginalia"].URL != "http://localhost:8192/health" {
		t.Fatalf("marginalia: url=%q", got["marginalia"].URL)
	}
}
