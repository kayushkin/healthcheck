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

`main` lives at the repo root — there is no `cmd/` package.

```bash
go build -o healthcheck .
./healthcheck -config config.yaml
```

## Deploy

```bash
./deploy.sh
```

Builds, runs the tests, installs the unit file and the binary to `~/bin/healthcheck`,
restarts the user unit, and smoke-tests `/api/status`. The smoke test fails loudly
on a stale binary and on any check that reports `misconfigured`.

First-time install only:

```bash
systemctl --user enable healthcheck
```

## systemd checks: `system_unit` must match where the unit lives

A `type: systemd` check probes `systemctl --user` by default, or `systemctl` when
`system_unit: true`. If that flag disagrees with the manager the unit is actually
registered under, the check watches nothing — and because `systemctl is-active`
prints `inactive` both for a stopped unit and for one that does not exist, the
mistake reads as a routine outage.

The checker therefore probes `LoadState`, not `is-active`, and reports a unit it
cannot find as **`misconfigured`** rather than `down`. The two are kept distinct on
purpose: `down` means *fix the service*, `misconfigured` means *fix this config*.
`auto_restart` is suppressed for a misconfigured check — restarting a unit that
does not exist can never succeed, and when the phantom unit does exist but can
never start (a shadow user unit whose port the real system unit already holds),
that retry loop is unbounded. It once reached 811,295 restarts.

That guard only catches a unit that is *missing*. A unit that exists and loads
but still can never start slips past it, so `auto_restart` also carries a budget:
**5 consecutive attempts**, after which the checker logs `RESTART SUPPRESSED`
once — naming the likely causes — and stops. Any healthy check re-arms the
budget, so the bound covers a single continuous outage rather than the service's
lifetime. `GET /api/status` reports `restart_attempts` and `restart_suppressed`,
which is how you tell a service healthcheck has given up on from one it is still
retrying. Without the budget the mirror image of the 811k loop ran unbounded a
second time: 1,325 futile restarts in 24h against the *system* `kayushkin.service`
once the *user* unit of the same name took its port.

## API

- `GET /api/status` — full status of all services + version drift info
- `GET /api/health` — simple health check for the monitor itself

## Config

Edit `config.yaml` to add/remove services, change intervals, or configure alerting.
