package server

import (
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/kayushkin/healthcheck/checker"
)

type Server struct {
	checker *checker.Checker
	addr    string
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

func (s *Server) Run() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/health", s.handleHealth)

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
