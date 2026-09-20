package checker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The live unit reads ~/repos/healthcheck/config.yaml at start and exits on a
// config it cannot load, so a bad edit is found by the restart that takes
// monitoring down. This loads the committed file instead.
func TestCommittedConfigLoadsAndEveryRepoScriptItNamesExists(t *testing.T) {
	repoRoot, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(filepath.Join(repoRoot, "config.yaml"))
	if err != nil {
		t.Fatalf("config.yaml does not load: %v", err)
	}

	// config.yaml names its scripts by their path in the main clone, which is
	// where the live unit runs them from. The test may run in a worktree, so it
	// looks for the same path under this tree's root.
	const mainCloneScripts = "/home/kayushkincom/repos/healthcheck/scripts/"

	seenNames := map[string]bool{}
	for _, svc := range cfg.Services {
		if svc.Name == "" {
			t.Errorf("a service has no name: %+v", svc)
		}
		if seenNames[svc.Name] {
			t.Errorf("two services are named %q; state is keyed by name", svc.Name)
		}
		seenNames[svc.Name] = true

		switch svc.Type {
		case "systemd":
			if svc.Unit == "" {
				t.Errorf("%s: a systemd check with no unit", svc.Name)
			}
		case "http":
			if svc.URL == "" {
				t.Errorf("%s: an http check with no url", svc.Name)
			}
		case "command":
			if len(svc.Command) == 0 {
				t.Errorf("%s: a command check with no command", svc.Name)
				continue
			}
			if !strings.HasPrefix(svc.Command[0], mainCloneScripts) {
				continue
			}
			script := filepath.Join(repoRoot, "scripts", strings.TrimPrefix(svc.Command[0], mainCloneScripts))
			info, err := os.Stat(script)
			if err != nil {
				t.Errorf("%s: %v", svc.Name, err)
				continue
			}
			if info.Mode()&0o111 == 0 {
				t.Errorf("%s: %s is not executable", svc.Name, script)
			}
		default:
			t.Errorf("%s: unknown check type %q", svc.Name, svc.Type)
		}
	}

	for _, want := range []string{"discord-signup-store", "discord-signup-gateway"} {
		if !seenNames[want] {
			t.Errorf("config.yaml has no %q check", want)
		}
	}
	for _, svc := range cfg.Services {
		if svc.Name == "discord-signup-gateway" && svc.AutoRestart {
			t.Error("discord-signup-gateway must not auto_restart: a Discord outage is not the unit's fault")
		}
	}
}
