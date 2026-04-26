package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/kayushkin/healthcheck/alerter"
	"github.com/kayushkin/healthcheck/checker"
	"github.com/kayushkin/healthcheck/server"
)

func main() {
	configPath := flag.String("config", "config.yaml", "path to config file")
	flag.Parse()

	cfg, err := checker.LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	a, err := alerter.New(cfg.LogFile, cfg.NatsURL, cfg.LLMBridgeURL)
	if err != nil {
		log.Fatalf("Failed to create alerter: %v", err)
	}

	c := checker.New(cfg)
	c.OnChange(a.OnStatusChange)
	c.OnRestart(a.OnRestart)
	c.OnPersistentAlert(a.OnPersistentAlert)
	c.OnCCAgentExhausted(a.OnCCAgentExhausted)

	srv := server.New(c, cfg.ListenAddr)
	srv.OnEscalate(a.OnCCAgentExhausted)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go c.Run(ctx)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("shutting down...")
		cancel()
		os.Exit(0)
	}()

	log.Fatal(srv.Run())
}
