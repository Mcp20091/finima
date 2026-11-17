# Finima on Proxmox VE (LXC)

One command on a Proxmox VE 9 host creates an unprivileged Debian 13 LXC that runs the
production Docker Compose stack (PostgreSQL, MinIO, backend, frontend, Caddy, daily backups,
optional Ollama), using the published `ghcr.io/pacphi/finima-*` images. No Rust/Node build.

## Install (Proxmox host, as root)

```bash
curl -L https://github.com/Mcp20091/finima/archive/refs/heads/main.tar.gz | tar xz finima-main/proxmox
cd finima-main/proxmox
./install.sh
```

The installer asks for container ID, storage, disk, CPU, RAM, bridge, IP, AI mode and image version,
prints the full plan, and changes nothing until you answer `y`. Then it opens at the URL it prints
(default `http://<container IP>`).

| AI mode | What it does | Suggested size |
|---|---|---|
| `none` | Rule-based categorization only | 2 cores, 4 GB RAM, 20 GB disk |
| `ollama` | Local LLM (`qwen3:4b` by default) on CPU | 4 cores, 8 GB RAM, 40 GB disk |

Use a static IP or a DHCP reservation: the URL is baked into sign-in links.

## Signing in

Finima signs in with emailed magic links.
- **With a [Resend](https://resend.com) API key** (asked during install): links are emailed.
- **Without one**: request a link in the browser, then on the Proxmox host run
  `pct exec <id> -- finima-login-link` and open the printed URL. (The link appears in the backend
  log, which is acceptable on a private LAN but not on an internet-exposed install.)

## Day-to-day (inside the container: `pct enter <id>`)

```bash
cd /opt/finima
docker compose ps                 # status
docker compose logs -f backend    # logs
finima-update                     # pull latest code + images for the current version, restart
finima-update 0.3.0               # switch to another image version
```

Settings and generated secrets live in `/opt/finima/.env` (mode 600). After editing it, run `finima-update`.
To serve HTTPS on a real domain, set `DOMAIN=finima.example.com` and `FINIMA_URL=https://finima.example.com`
(Caddy then gets a Let's Encrypt certificate, which needs the domain reachable on ports 80/443).

## How it differs from plain `docker-compose.prod.yml`

`proxmox/compose.proxmox.yml` is layered on top (via `COMPOSE_FILE` in `.env`); upstream files are untouched:

- Pins image versions (`FINIMA_VERSION`, default `0.2.0`) instead of `latest`.
- Passes `DOMAIN` to Caddy (default `:80` = plain HTTP on any address). Without it Caddy only answers
  `localhost`.
- Provides `cors.allowed_origins`, which production requires (the backend panics if it is empty) and
  which can't be set through `APP__` env vars because the config loader doesn't parse lists from env.
  `setup.sh` generates `proxmox/local/production.yaml` from `config/production.yaml` on every run.
- Passes `APP__AUTH__PUBLIC_URL` and the LLM provider/model to the backend.
- Starts Ollama only when the `ollama` AI mode is chosen.

## Notes

- Docker runs inside an unprivileged LXC with `nesting=1,keyctl=1`. This is common and works on PVE 9,
  but Proxmox's docs still recommend a VM when you want maximum isolation.
- If Docker can't start containers, `setup.sh` stops with a message; check `pct config <id> | grep features`.
- Backups: daily `pg_dump` into MinIO (`finima-backups`, 30 days). Also back up the LXC itself with
  Proxmox's vzdump.
