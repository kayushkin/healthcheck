package alerter

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/kayushkin/healthcheck/checker"
)

type Alerter struct {
	logFile string
	busURL  string
	mu      sync.Mutex
	logger  *log.Logger
}

type BusEvent struct {
	Type      string `json:"type"`
	Service   string `json:"service"`
	OldStatus string `json:"old_status"`
	NewStatus string `json:"new_status"`
	Timestamp string `json:"timestamp"`
	Message   string `json:"message"`
}

func New(logFile, busURL string) (*Alerter, error) {
	a := &Alerter{
		logFile: logFile,
		busURL:  busURL,
	}
	if logFile != "" {
		f, err := os.OpenFile(logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		if err != nil {
			return nil, fmt.Errorf("open log file: %w", err)
		}
		a.logger = log.New(f, "", log.LstdFlags)
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

	// Post to bus
	if a.busURL != "" {
		go a.postToBus(BusEvent{
			Type:      "healthcheck.status_change",
			Service:   name,
			OldStatus: string(oldStatus),
			NewStatus: string(newStatus),
			Timestamp: time.Now().Format(time.RFC3339),
			Message:   msg,
		})
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
}

func (a *Alerter) postToBus(event BusEvent) {
	data, _ := json.Marshal(event)
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Post(a.busURL+"/events", "application/json", bytes.NewReader(data))
	if err != nil {
		log.Printf("Failed to post to bus: %v", err)
		return
	}
	resp.Body.Close()
}
