# healthcheck

Infrastructure health monitor for Slava's services.

## What it does

- **HTTP checks** — pings web services and APIs on a configurable interval
- **Systemd checks** — monitors user services (openclaw-bus, inber-server, ssh-tunnels)
- **Command checks** — runs arbitrary commands (e.g. `openclaw gateway status`)
- **Version drift detection** — compares local git HEAD vs remote for deployed services
- **Auto-restart** — restarts failed systemd user services (configurable per-service)
- **Alerting** — logs alerts, posts to bus on status changes
- **Status API** — serves JSON at `/api/status` for the status page on kayushkin.com

## Services monitored

| Service | Type | Endpoint |
|---------|------|----------|
| kayushkin.com | HTTP | https://kayushkin.com |
| mangastack | HTTP | kayushkin.com:8084 |
| inber-server | HTTP + systemd | localhost:8200 |
| model-store | HTTP | localhost:8150 |
| bus | HTTP | localhost:8100 |
| logstack | HTTP | localhost:8088 |
| openclaw-gateway | command | `openclaw gateway status` |
| openclaw-bus | systemd | user service |
| ssh-tunnels | systemd | user service |

## Build & Run

```bash
go build -o healthcheck ./cmd/healthcheck
./healthcheck -config config.yaml
```

## Install as systemd service

```bash
cp deploy/healthcheck.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now healthcheck
```

## API

- `GET /api/status` — full status of all services + version drift info
- `GET /api/health` — simple health check for the monitor itself

## Config

Edit `config.yaml` to add/remove services, change intervals, or configure alerting.
