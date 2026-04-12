package alerter

import (
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/kayushkin/bus"
	"github.com/kayushkin/healthcheck/checker"
)

type Alerter struct {
	logFile string
	nats    *bus.Client
	mu      sync.Mutex
	logger  *log.Logger
}

type HealthEvent struct {
	Type      string `json:"type"`
	Service   string `json:"service"`
	OldStatus string `json:"old_status"`
	NewStatus string `json:"new_status"`
	Timestamp string `json:"timestamp"`
	Message   string `json:"message"`
}

func New(logFile, natsURL string) (*Alerter, error) {
	a := &Alerter{
		logFile: logFile,
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
