# About healthcheck

## What it owns

Infrastructure health monitoring. HTTP checks, systemd monitoring, version drift detection, status API with alerting. Since 2026-09-10 each row of `GET /api/status` also carries what was checked — `unit` and `system_unit` for a systemd check, `url` for an http one — which is what llm-bridge-server's service inventory joins on to find the process.

## Where this prompt lives

These sections are stored in agent-store as a project prompt collection and rendered, with identical text, to `AGENTS.md` and `CLAUDE.md` at the root of this repo, so that whichever file a harness reads it gets the same thing. Edit them on dash `/files`, or edit either rendered file: the 15-minute scan carries the edit back into the sections and out to the other file. The host prompt keeps one row for this repo with only what an agent elsewhere needs.

# Access and operations

## Running it, and what a failing check does

The user unit `healthcheck.service` runs the installed binary with `-config` pointing at this repo's own `config.yaml`, so that file is the live list of checks, and its `listen_addr` binds `127.0.0.1:8099`. The service reloads nothing on a signal (`main.go` handles only SIGINT and SIGTERM), so a change to `config.yaml` takes effect when `./deploy.sh` restarts the unit. A check may set `auto_restart: true`, which restarts its systemd unit when it fails; a check that reports `misconfigured` is never restarted. After `alert_threshold` failures in a row, the alerter appends to the alerts log named in `log_file` and publishes `health.status_change`, `health.persistent_alert`, `health.cc_agent_exhausted` or `health.restart` on NATS (`alerter/alerter.go`).
