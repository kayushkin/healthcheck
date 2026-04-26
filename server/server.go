package server

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/kayushkin/healthcheck/checker"
)

type Server struct {
	checker    *checker.Checker
	addr       string
	onEscalate func(name string, state checker.ResourceState)
}

type StatusResponse struct {
	Timestamp string                   `json:"timestamp"`
	Services  []checker.ServiceState   `json:"services"`
	Resources []checker.ResourceState  `json:"resources"`
	Versions  []checker.VersionState   `json:"versions"`
}

func New(c *checker.Checker, addr string) *Server {
	return &Server{checker: c, addr: addr}
}

func (s *Server) OnEscalate(fn func(name string, state checker.ResourceState)) {
	s.onEscalate = fn
}

func (s *Server) Run() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/health", s.handleHealth)
	mux.HandleFunc("/api/check/", s.handleCheck)
	mux.HandleFunc("/api/escalate/", s.handleEscalate)

	log.Printf("Status API listening on %s", s.addr)
	return http.ListenAndServe(s.addr, mux)
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	resp := StatusResponse{
		Timestamp: time.Now().Format(time.RFC3339),
		Services:  s.checker.GetStates(),
		Resources: s.checker.GetResourceStates(),
		Versions:  s.checker.CheckVersions(),
	}

	json.NewEncoder(w).Encode(resp)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (s *Server) handleEscalate(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		json.NewEncoder(w).Encode(map[string]string{"error": "POST required"})
		return
	}
	if s.onEscalate == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(map[string]string{"error": "escalation not configured (llm_bridge_url missing)"})
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/api/escalate/")
	if name == "" {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "resource name required: /api/escalate/{name}"})
		return
	}
	state, ok := s.checker.GetResourceState(name)
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(map[string]string{"error": "unknown resource: " + name})
		return
	}
	go s.onEscalate(name, state)
	w.WriteHeader(http.StatusAccepted)
	json.NewEncoder(w).Encode(map[string]string{"status": "escalation queued", "resource": name})
}

func (s *Server) handleCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		json.NewEncoder(w).Encode(map[string]string{"error": "POST required"})
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/api/check/")
	if name == "" {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "resource name required: /api/check/{name}"})
		return
	}
	state, ok := s.checker.RunResourceCheck(name)
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(map[string]string{"error": "unknown resource: " + name})
		return
	}
	if state.Status == checker.StatusDown {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	json.NewEncoder(w).Encode(state)
}
