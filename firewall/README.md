# Host firewall

`host-firewall.nft` is the Linode's only firewall: an nftables table, `inet host_firewall`, whose input chain drops everything from outside except SSH (22), nginx (80, 443) and dash's TLS ports (9100–9119). Loopback, replies, ping and Docker's bridges are allowed, so services keep reaching each other, the Matrix bridges reach the host, and runner machines come in through SSH tunnels.

It was added on 2026-10-14. Until then there was no firewall, and about thirty services listening on every interface were reachable from the internet past nginx — scheduler (:8092) with no auth runs shell jobs, llm-bridge (:8160) has a password-less demo login, kanban-store (:8305) trusts `X-Principal-Id`, noteboard has no auth. Scanners were already probing bookstack (:8081).

- **Opening a port** means adding it to `tcp dport` here and running `./install.sh`. A service meant for the internet should go behind nginx instead.
- **Install or change:** `./install.sh` checks the syntax, installs the file and `host-firewall.service`, applies it, and arms a 10-minute rollback; check SSH and the sites from another machine, then `./install.sh --confirm`.
- **Never** use Debian's `nftables.service` or `nft flush ruleset`: both remove Docker's tables too. `host-firewall.service` loads and deletes only its own table.
- **What it drops** is logged (10 a minute): `journalctl -k | grep "host-firewall drop"`.
