package checker

import (
	"context"
	"fmt"
	"log"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

type ResourceState struct {
	Name             string    `json:"name"`
	Type             string    `json:"type"`
	Status           Status    `json:"status"`
	UsagePct         float64   `json:"usage_pct"`
	Threshold        float64   `json:"threshold"`
	Detail           string    `json:"detail"`
	LastCheck        time.Time `json:"last_check"`
	ConsecutiveFails int       `json:"consecutive_failures"`
	LastError        string    `json:"last_error,omitempty"`
}

func (c *Checker) GetResourceStates() []ResourceState {
	c.mu.RLock()
	defer c.mu.RUnlock()
	result := make([]ResourceState, 0, len(c.resourceStates))
	for _, s := range c.resourceStates {
		result = append(result, *s)
	}
	return result
}

func (c *Checker) checkAllResources() {
	var wg sync.WaitGroup
	for _, res := range c.config.Resources {
		wg.Add(1)
		go func(res ResourceConfig) {
			defer wg.Done()
			c.checkResource(res)
		}(res)
	}
	wg.Wait()
}

func (c *Checker) checkResource(res ResourceConfig) {
	var usagePct float64
	var detail string
	var checkErr error

	switch res.Type {
	case "disk":
		usagePct, detail, checkErr = checkDisk(res.Path)
	case "memory":
		usagePct, detail, checkErr = checkMemory()
	default:
		checkErr = fmt.Errorf("unknown resource type: %s", res.Type)
	}

	c.mu.Lock()
	state := c.resourceStates[res.Name]
	oldStatus := state.Status
	state.LastCheck = time.Now()

	if checkErr != nil {
		state.ConsecutiveFails++
		state.LastError = checkErr.Error()
		state.Status = StatusDown
	} else {
		state.UsagePct = usagePct
		state.Detail = detail
		if usagePct >= res.Threshold {
			state.ConsecutiveFails++
			state.LastError = fmt.Sprintf("usage %.1f%% exceeds threshold %.1f%%", usagePct, res.Threshold)
			if state.ConsecutiveFails >= c.config.AlertThreshold {
				state.Status = StatusDown
			} else {
				state.Status = StatusDegraded
			}
		} else {
			state.ConsecutiveFails = 0
			state.Status = StatusUp
			state.LastError = ""
		}
	}

	newStatus := state.Status
	c.mu.Unlock()

	if oldStatus != newStatus && oldStatus != StatusUnknown && c.onChange != nil {
		c.onChange(res.Name, oldStatus, newStatus)
	}

	// Spawn CC agent on resource alert
	if res.CCAgent && state.Status == StatusDown && state.ConsecutiveFails == c.config.AlertThreshold {
		go c.spawnCCAgent(res, state)
	}
}

func checkDisk(path string) (float64, string, error) {
	if path == "" {
		path = "/"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "df", "--output=pcent,avail,size", path)
	out, err := cmd.Output()
	if err != nil {
		return 0, "", fmt.Errorf("df failed: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) < 2 {
		return 0, "", fmt.Errorf("unexpected df output")
	}
	fields := strings.Fields(lines[1])
	if len(fields) < 3 {
		return 0, "", fmt.Errorf("unexpected df fields: %s", lines[1])
	}
	pctStr := strings.TrimSuffix(fields[0], "%")
	pct, err := strconv.ParseFloat(pctStr, 64)
	if err != nil {
		return 0, "", fmt.Errorf("parse disk pct: %v", err)
	}
	availKB, _ := strconv.ParseFloat(fields[1], 64)
	totalKB, _ := strconv.ParseFloat(fields[2], 64)
	detail := fmt.Sprintf("%.1fGB free / %.1fGB total", availKB/1048576, totalKB/1048576)
	return pct, detail, nil
}

func checkMemory() (float64, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "free", "-b")
	out, err := cmd.Output()
	if err != nil {
		return 0, "", fmt.Errorf("free failed: %v", err)
	}
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		if strings.HasPrefix(line, "Mem:") {
			fields := strings.Fields(line)
			if len(fields) < 4 {
				return 0, "", fmt.Errorf("unexpected free output: %s", line)
			}
			total, _ := strconv.ParseFloat(fields[1], 64)
			used, _ := strconv.ParseFloat(fields[2], 64)
			if total == 0 {
				return 0, "", fmt.Errorf("total memory is 0")
			}
			available, _ := strconv.ParseFloat(fields[6], 64)
			pct := (1 - available/total) * 100
			detail := fmt.Sprintf("%.1fGB used / %.1fGB total (%.1fGB available)",
				used/1073741824, total/1073741824, available/1073741824)
			return pct, detail, nil
		}
	}
	return 0, "", fmt.Errorf("no Mem: line in free output")
}

func (c *Checker) spawnCCAgent(res ResourceConfig, state *ResourceState) {
	claudePath := c.config.ClaudePath
	if claudePath == "" {
		claudePath = "claude"
	}
	workdir := c.config.ClaudeWorkdir
	if workdir == "" {
		workdir = expandHome("~/")
	}

	prompt := fmt.Sprintf(
		"ALERT: %s usage is critical at %.1f%% (threshold: %.1f%%). Details: %s. "+
			"Investigate what is consuming %s, identify the top offenders, and take safe corrective action "+
			"(e.g. clean up logs, temp files, caches, old builds). Do NOT delete anything that looks like user data or active state. "+
			"Report what you found and what you cleaned up.",
		res.Type, state.UsagePct, res.Threshold, state.Detail, res.Type,
	)

	log.Printf("CC-AGENT: spawning for %s alert (%.1f%% >= %.1f%%)", res.Name, state.UsagePct, res.Threshold)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	cmd := exec.CommandContext(ctx, claudePath,
		"-p", prompt,
		"--output-format", "stream-json",
		"--dangerously-skip-permissions",
		"--verbose",
	)
	cmd.Dir = workdir
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("CC-AGENT: failed for %s: %v\n%s", res.Name, err, string(out))
	} else {
		log.Printf("CC-AGENT: completed for %s", res.Name)
	}
}
