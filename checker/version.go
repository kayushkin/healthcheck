package checker

import (
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

type VersionState struct {
	Name       string `json:"name"`
	LocalHead  string `json:"local_head"`
	RemoteHead string `json:"remote_head"`
	Drift      int    `json:"drift"`
	Behind     bool   `json:"behind"`
	Error      string `json:"error,omitempty"`
}

func (c *Checker) CheckVersions() []VersionState {
	results := make([]VersionState, 0, len(c.config.VersionChecks))
	for _, vc := range c.config.VersionChecks {
		vs := c.checkVersion(vc)
		results = append(results, vs)
	}
	return results
}

func (c *Checker) checkVersion(vc VersionConfig) VersionState {
	vs := VersionState{Name: vc.Name}

	repo := expandHome(vc.LocalRepo)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Fetch latest
	fetch := exec.CommandContext(ctx, "git", "-C", repo, "fetch", "--quiet")
	fetch.Run() // best effort

	// Local HEAD
	headCmd := exec.CommandContext(ctx, "git", "-C", repo, "rev-parse", "HEAD")
	out, err := headCmd.Output()
	if err != nil {
		vs.Error = fmt.Sprintf("failed to get local HEAD: %v", err)
		return vs
	}
	vs.LocalHead = strings.TrimSpace(string(out))

	// Remote HEAD
	remoteCmd := exec.CommandContext(ctx, "git", "-C", repo, "rev-parse", vc.RemoteRef)
	out, err = remoteCmd.Output()
	if err != nil {
		vs.Error = fmt.Sprintf("failed to get remote ref %s: %v", vc.RemoteRef, err)
		return vs
	}
	vs.RemoteHead = strings.TrimSpace(string(out))

	// Count commits behind
	rangeSpec := fmt.Sprintf("%s..%s", vs.LocalHead, vs.RemoteHead)
	countCmd := exec.CommandContext(ctx, "git", "-C", repo, "rev-list", "--count", rangeSpec)
	out, err = countCmd.Output()
	if err != nil {
		vs.Error = fmt.Sprintf("failed to count drift: %v", err)
		return vs
	}
	drift, _ := strconv.Atoi(strings.TrimSpace(string(out)))
	vs.Drift = drift
	vs.Behind = drift > vc.MaxDrift

	return vs
}

func expandHome(path string) string {
	if strings.HasPrefix(path, "~/") {
		home, _ := exec.Command("sh", "-c", "echo $HOME").Output()
		return strings.TrimSpace(string(home)) + path[1:]
	}
	return path
}
