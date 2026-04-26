package checker

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
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
	LastAlertAt      time.Time `json:"last_alert_at,omitempty"`
	LastCCAgentAt    time.Time `json:"last_cc_agent_at,omitempty"`
	CCAgentAttempts  int       `json:"cc_agent_attempts,omitempty"`
	CCAgentGaveUp    bool      `json:"cc_agent_gave_up,omitempty"`
}

const (
	ccAgentCooldown         = 30 * time.Minute
	persistentAlertInterval = 15 * time.Minute
	maxCCAgentAttempts      = 3
)

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
	now := time.Now()

	firePersistent := false
	spawnAgent := false
	fireGaveUp := false
	if newStatus == StatusDown {
		if !state.LastAlertAt.IsZero() && now.Sub(state.LastAlertAt) >= persistentAlertInterval {
			state.LastAlertAt = now
			firePersistent = true
		} else if state.LastAlertAt.IsZero() {
			state.LastAlertAt = now
		}
		if res.CCAgent && (state.LastCCAgentAt.IsZero() || now.Sub(state.LastCCAgentAt) >= ccAgentCooldown) {
			if state.CCAgentAttempts < maxCCAgentAttempts {
				state.LastCCAgentAt = now
				state.CCAgentAttempts++
				spawnAgent = true
			} else if !state.CCAgentGaveUp {
				state.CCAgentGaveUp = true
				fireGaveUp = true
			}
		}
	} else {
		state.LastAlertAt = time.Time{}
		state.LastCCAgentAt = time.Time{}
		state.CCAgentAttempts = 0
		state.CCAgentGaveUp = false
	}
	stateCopy := *state
	c.mu.Unlock()

	if oldStatus != newStatus && newStatus != StatusUnknown && c.onChange != nil {
		c.onChange(res.Name, oldStatus, newStatus)
	}

	if firePersistent && c.onPersistentAlert != nil {
		c.onPersistentAlert(res.Name, stateCopy)
	}

	if fireGaveUp && c.onCCAgentExhausted != nil {
		c.onCCAgentExhausted(res.Name, stateCopy)
	}

	if spawnAgent {
		go c.spawnCCAgent(res, &stateCopy)
	}
}

func (c *Checker) GetResourceState(name string) (ResourceState, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	state, ok := c.resourceStates[name]
	if !ok {
		return ResourceState{}, false
	}
	return *state, true
}

func (c *Checker) RunResourceCheck(name string) (*ResourceState, bool) {
	var resCfg *ResourceConfig
	for i := range c.config.Resources {
		if c.config.Resources[i].Name == name {
			resCfg = &c.config.Resources[i]
			break
		}
	}
	if resCfg == nil {
		return nil, false
	}
	c.checkResource(*resCfg)
	c.mu.RLock()
	defer c.mu.RUnlock()
	state := c.resourceStates[name]
	if state == nil {
		return nil, false
	}
	stateCopy := *state
	return &stateCopy, true
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
	bridgeURL := c.config.LLMBridgeURL
	if bridgeURL == "" {
		log.Printf("CC-AGENT: skipping spawn for %s: llm_bridge_url not configured", res.Name)
		return
	}

	prompt := fmt.Sprintf(
		"ALERT: %s usage is critical at %.1f%% (threshold: %.1f%%). Details: %s. "+
			"Investigate what is consuming %s, identify the top offenders, and take safe corrective action "+
			"(e.g. clean up logs, temp files, caches, old builds). Do NOT delete anything that looks like user data or active state. "+
			"Report what you found and what you cleaned up.",
		res.Type, state.UsagePct, res.Threshold, state.Detail, res.Type,
	)
	displayName := fmt.Sprintf("ALERT: %s usage critical at %.1f%%", res.Type, state.UsagePct)
	clientID := fmt.Sprintf("healthcheck-%s-%d", res.Name, time.Now().Unix())

	log.Printf("CC-AGENT: spawning bridge session for %s alert (%.1f%% >= %.1f%%)", res.Name, state.UsagePct, res.Threshold)

	createBody, _ := json.Marshal(map[string]any{
		"harness":      "claude_code",
		"client_id":    clientID,
		"display_name": displayName,
		"source":       "healthcheck",
		"auto_start":   true,
	})
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Post(bridgeURL+"/sessions", "application/json", bytes.NewReader(createBody))
	if err != nil {
		log.Printf("CC-AGENT: create session failed for %s: %v", res.Name, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		log.Printf("CC-AGENT: create session returned %d for %s: %s", resp.StatusCode, res.Name, string(body))
		return
	}

	var session struct {
		BridgeID string `json:"bridge_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&session); err != nil {
		log.Printf("CC-AGENT: decode session response for %s: %v", res.Name, err)
		return
	}
	if session.BridgeID == "" {
		log.Printf("CC-AGENT: empty bridge_id for %s", res.Name)
		return
	}

	sendBody, _ := json.Marshal(map[string]string{"message": prompt})
	sendResp, err := client.Post(bridgeURL+"/sessions/"+session.BridgeID+"/send", "application/json", bytes.NewReader(sendBody))
	if err != nil {
		log.Printf("CC-AGENT: send message to %s failed: %v", session.BridgeID, err)
		return
	}
	defer sendResp.Body.Close()
	if sendResp.StatusCode >= 300 {
		body, _ := io.ReadAll(sendResp.Body)
		log.Printf("CC-AGENT: send message returned %d for %s: %s", sendResp.StatusCode, res.Name, string(body))
		return
	}
	log.Printf("CC-AGENT: started session %s for %s", session.BridgeID, res.Name)
}
