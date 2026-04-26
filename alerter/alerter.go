package alerter

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/kayushkin/bus"
	"github.com/kayushkin/healthcheck/checker"
)

type Alerter struct {
	logFile      string
	nats         *bus.Client
	llmBridgeURL string
	mu           sync.Mutex
	logger       *log.Logger
}

type HealthEvent struct {
	Type      string `json:"type"`
	Service   string `json:"service"`
	OldStatus string `json:"old_status"`
	NewStatus string `json:"new_status"`
	Timestamp string `json:"timestamp"`
	Message   string `json:"message"`
}

func New(logFile, natsURL, llmBridgeURL string) (*Alerter, error) {
	a := &Alerter{
		logFile:      logFile,
		llmBridgeURL: llmBridgeURL,
	}
	if logFile != "" {
		f, err := os.OpenFile(logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		if err != nil {
			return nil, fmt.Errorf("open log file: %w", err)
		}
		a.logger = log.New(f, "", log.LstdFlags)
	}

	if natsURL != "" {
		client, err := bus.Connect(bus.Options{
			URL:  natsURL,
			Name: "healthcheck",
		})
		if err != nil {
			log.Printf("WARN: failed to connect to NATS (%s), alerts will be log-only: %v", natsURL, err)
		} else {
			a.nats = client
		}
	}

	return a, nil
}

func (a *Alerter) OnStatusChange(name string, oldStatus, newStatus checker.Status) {
	msg := fmt.Sprintf("[%s] %s: %s → %s", time.Now().Format(time.RFC3339), name, oldStatus, newStatus)

	a.mu.Lock()
	if a.logger != nil {
		a.logger.Println(msg)
	}
	a.mu.Unlock()

	log.Println("ALERT:", msg)

	if a.nats != nil {
		go func() {
			err := a.nats.Publish("health.status_change", HealthEvent{
				Type:      "healthcheck.status_change",
				Service:   name,
				OldStatus: string(oldStatus),
				NewStatus: string(newStatus),
				Timestamp: time.Now().Format(time.RFC3339),
				Message:   msg,
			})
			if err != nil {
				log.Printf("Failed to publish to NATS: %v", err)
			}
		}()
	}
}

func (a *Alerter) OnPersistentAlert(name string, state checker.ResourceState) {
	msg := fmt.Sprintf("[%s] STILL DOWN: %s at %.1f%% (threshold %.1f%%) %s",
		time.Now().Format(time.RFC3339), name, state.UsagePct, state.Threshold, state.Detail)

	a.mu.Lock()
	if a.logger != nil {
		a.logger.Println(msg)
	}
	a.mu.Unlock()

	log.Println("STILL-DOWN:", msg)

	if a.nats != nil {
		go func() {
			err := a.nats.Publish("health.persistent_alert", HealthEvent{
				Type:      "healthcheck.persistent_alert",
				Service:   name,
				OldStatus: "down",
				NewStatus: "down",
				Timestamp: time.Now().Format(time.RFC3339),
				Message:   msg,
			})
			if err != nil {
				log.Printf("Failed to publish persistent alert to NATS: %v", err)
			}
		}()
	}
}

func (a *Alerter) OnCCAgentExhausted(name string, state checker.ResourceState) {
	msg := fmt.Sprintf("[%s] CC-AGENT EXHAUSTED: %s after %d attempts (still %.1f%% / threshold %.1f%%). Manual intervention required.",
		time.Now().Format(time.RFC3339), name, state.CCAgentAttempts, state.UsagePct, state.Threshold)

	a.mu.Lock()
	if a.logger != nil {
		a.logger.Println(msg)
	}
	a.mu.Unlock()

	log.Println("CC-AGENT-EXHAUSTED:", msg)

	if a.nats != nil {
		go func() {
			err := a.nats.Publish("health.cc_agent_exhausted", HealthEvent{
				Type:      "healthcheck.cc_agent_exhausted",
				Service:   name,
				OldStatus: "down",
				NewStatus: "down",
				Timestamp: time.Now().Format(time.RFC3339),
				Message:   msg,
			})
			if err != nil {
				log.Printf("Failed to publish exhaustion alert to NATS: %v", err)
			}
		}()
	}

	if a.llmBridgeURL != "" {
		go a.createEscalationSession(name, state)
	}
}

func (a *Alerter) createEscalationSession(name string, state checker.ResourceState) {
	prompt := fmt.Sprintf(
		"AUTOMATED ESCALATION from healthcheck.\n\n"+
			"Resource: %s (%s)\n"+
			"Status: DOWN — usage %.1f%% vs threshold %.1f%%\n"+
			"Detail: %s\n"+
			"Consecutive failures: %d\n"+
			"Auto-cleanup CC agent was spawned %d times (max reached) and did not bring usage below threshold. Giving up on automated remediation.\n\n"+
			"Please investigate what is consuming %s, identify the top offenders, and take corrective action. "+
			"The prior auto-agent has already attempted the obvious cleanups (journal vacuum, cache, go clean, docker prune) — "+
			"focus on anything unusual or that requires a human decision.",
		name, state.Type, state.UsagePct, state.Threshold, state.Detail,
		state.ConsecutiveFails, state.CCAgentAttempts, state.Type,
	)

	displayName := fmt.Sprintf("[ALERT] %s auto-cleanup exhausted", name)
	clientID := fmt.Sprintf("healthcheck-%s-%d", name, time.Now().Unix())

	createBody, _ := json.Marshal(map[string]any{
		"harness":      "claude_code",
		"client_id":    clientID,
		"display_name": displayName,
		"source":       "healthcheck",
		"auto_start":   true,
	})
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Post(a.llmBridgeURL+"/sessions", "application/json", bytes.NewReader(createBody))
	if err != nil {
		log.Printf("LLMUX-ESCALATION: create session failed: %v", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		log.Printf("LLMUX-ESCALATION: create session returned %d: %s", resp.StatusCode, string(body))
		return
	}

	var session struct {
		BridgeID    string `json:"bridge_id"`
		DisplayName string `json:"display_name"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&session); err != nil {
		log.Printf("LLMUX-ESCALATION: decode session response: %v", err)
		return
	}
	if session.BridgeID == "" {
		log.Printf("LLMUX-ESCALATION: empty bridge_id in response")
		return
	}

	sendBody, _ := json.Marshal(map[string]string{"message": prompt})
	sendResp, err := client.Post(a.llmBridgeURL+"/sessions/"+session.BridgeID+"/send", "application/json", bytes.NewReader(sendBody))
	if err != nil {
		log.Printf("LLMUX-ESCALATION: send message to %s failed: %v", session.BridgeID, err)
		return
	}
	defer sendResp.Body.Close()
	if sendResp.StatusCode >= 300 {
		body, _ := io.ReadAll(sendResp.Body)
		log.Printf("LLMUX-ESCALATION: send message returned %d: %s", sendResp.StatusCode, string(body))
		return
	}

	log.Printf("LLMUX-ESCALATION: created session %s (%q) for %s", session.BridgeID, session.DisplayName, name)
}

func (a *Alerter) OnRestart(name string, success bool, err error) {
	status := "success"
	errMsg := ""
	if !success {
		status = "failed"
		if err != nil {
			errMsg = err.Error()
		}
	}
	msg := fmt.Sprintf("[%s] RESTART %s: %s %s", time.Now().Format(time.RFC3339), name, status, errMsg)

	a.mu.Lock()
	if a.logger != nil {
		a.logger.Println(msg)
	}
	a.mu.Unlock()

	log.Println("RESTART:", msg)

	if a.nats != nil {
		go func() {
			_ = a.nats.Publish("health.restart", HealthEvent{
				Type:      "healthcheck.restart",
				Service:   name,
				NewStatus: status,
				Timestamp: time.Now().Format(time.RFC3339),
				Message:   msg,
			})
		}()
	}
}

func (a *Alerter) Close() {
	if a.nats != nil {
		a.nats.Close()
	}
}
