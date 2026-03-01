# dns24-ddns-docker

Lightweight Docker container for automatic [dns24.ch](https://dns24.ch) dynamic DNS updates.

## Features

- **Multi-type DNS records** — A, AAAA, CNAME, MX, TXT, CAA, SPF, SRV, SSHFP, URL
- **Dynamic + static records** — A/AAAA auto-detect your IP; everything else is pushed from config
- **NS verification** — confirms updates landed on `ns1.dns24.ch` / `ns2.dns24.ch`
- **Retry & recovery** — failed records are retried each cycle with escalating alerts
- **Outage detection** — distinguishes API-down from auth errors using NS health checks
- **Drift detection** — periodically spot-checks records to catch silent changes
- **Discord notifications** — IP changes, errors, outages, recovery, propagation
- **Global propagation tracking** — monitors DNS propagation across multiple resolver networks
- **IPv4 + IPv6** — dual-stack support for AAAA records
- **First-run bootstrap** — auto-creates config with guided setup instructions
- **Zero dependencies** — Alpine-based, ~15MB image

## Quick Start

```bash
git clone https://github.com/M7C7/dns24-ddns-docker.git
cd dns24-ddns-docker
docker-compose up -d
```

On first run, the container creates `config/.env` and waits for you to configure it.

```bash
# Edit credentials
nano config/.env

# Add a domain (one file per domain, subdomains inside)
echo -e "www\nmail" > config/records/example.ch
```

The container auto-detects changes within 30 seconds and starts updating.

## Record Files

Each file in `config/records/` is named after your domain. The filename **is** the domain.

### Basic format (backward compatible)

```
# config/records/example.ch
www
mail
vpn
```

This creates A records for `@.example.ch`, `www.example.ch`, `mail.example.ch`, and `vpn.example.ch` — all pointing to your dynamic IP. The root A record is auto-added unless you use `NOROOT`.

### Extended format

```
# config/records/example.ch
NOROOT

# Dynamic records — IP auto-detected
www
www|AAAA
vpn|A

# Static records — data specified, pushed once and verified
mail|CNAME|mail.provider.com
@|MX|10 mail.provider.com
@|TXT|v=spf1 include:_spf.google.com ~all
_dmarc|TXT|v=DMARC1; p=none; rua=mailto:dmarc@example.ch
@|CAA|0 issue "letsencrypt.org"
```

### Format reference

| Format | Type | Behavior |
|--------|------|----------|
| `www` | A | Dynamic — auto IP |
| `@\|A` | A | Dynamic — explicit root |
| `www\|AAAA` | AAAA | Dynamic — auto IPv6 |
| `mail\|CNAME\|target.com` | CNAME | Static — pushed once, verified via NS |
| `@\|MX\|10 mx.host.com` | MX | Static |
| `@\|TXT\|v=spf1 ...` | TXT | Static |
| `_dmarc\|TXT\|v=DMARC1; ...` | TXT | Static |
| `@\|CAA\|0 issue "le.org"` | CAA | Static |
| `_sip\|SRV\|0 5 5060 sip.example.ch` | SRV | Static |
| `NOROOT` | — | Skip auto root A record |

**Dynamic records** (A, AAAA without explicit data) are updated every time your IP changes.

**Static records** (everything else, or A/AAAA with explicit data) are pushed on startup and re-pushed if NS verification shows they're missing or wrong.

### NOROOT behavior

By default, a root A record (`@.example.ch`) is auto-added for every domain file. Add `NOROOT` to skip this. You can still explicitly add `@|MX|...` or `@|TXT|...` — NOROOT only suppresses the auto root A record.

## How It Works

Each cycle (default: every 30 seconds):

1. **Detect current IP** (IPv4, optionally IPv6 if AAAA records exist)
2. **IP changed?** → Push all dynamic records (A/AAAA) to dns24 API
3. **IP unchanged?** → Skip API calls
4. **Process pending list:**
   - **Failed** records → retry API call
   - **Unconfirmed** records → query `ns1/ns2.dns24.ch` to confirm
   - **Static** records → verify via NS, push if missing/wrong
5. **Every Nth cycle:** Spot-check a random record against NS (drift detection)

### Outage detection

When API calls fail, the container checks nameserver reachability:

| Condition | Diagnosis | Action |
|-----------|-----------|--------|
| API fails, NS responds | Auth error or partial outage | Retry, warn after 2 failures |
| API fails, NS also down | dns24.ch is down | Queue updates, alert at 2 and every 5 failures |
| API recovers | Back online | Push all queued updates, send recovery notification |

### NS verification

After every update, records are verified against `ns1.dns24.ch` and `ns2.dns24.ch` using `dig`. This confirms the update actually landed, not just that the API accepted it.

### Drift detection

Every N cycles (configurable), a random record is checked against the authoritative nameserver. If the NS returns an unexpected value (manual change, silent rollback), all dynamic records are re-pushed and a Discord alert is sent.

## Synology DSM (Container Manager / Docker)

### Option 1 — Use the prebuilt image

You can download the image directly in Synology Container Manager.

Docker Hub repository:  
https://hub.docker.com/r/m7c7/dns24-ddns

Or pull it via SSH:

```bash
docker pull m7c7/dns24-ddns:latest
```

Create a new container from `m7c7/dns24-ddns:latest`.

#### Volume mapping (required)

Map a persistent host directory to `/config` inside the container.

Example:

- Host path: `/volume1/docker/dns24-ddns/config`
- Container path: `/config`

The `/config` directory contains:

- `.env` (credentials and settings)
- `records/` (one file per domain)
- `meta/` (runtime state, IP history, retry queue, outage counter, etc.)

If this directory is not mapped, configuration and runtime data will be lost after a restart.

#### Restart policy

Set the restart policy to:

```
Restart automatically (unless stopped)
```

After starting the container:

1. Open `/volume1/docker/dns24-ddns/config`
2. Edit the generated `.env` file and add your DNS24 credentials
3. Create your domain files inside `config/records/`

The container detects configuration changes automatically (within ~30 seconds) and begins updating.

---

### Option 2 — Deploy via SSH and docker-compose

Connect to your NAS and deploy manually:

```bash
ssh user@your-nas
cd /volume1/docker
git clone https://github.com/M7C7/dns24-ddns-docker.git
cd dns24-ddns-docker
sudo docker-compose up -d --build
sudo docker-compose logs -f --tail=100
```

This process:

- Clones the repository
- Builds the image locally
- Applies the volume mapping defined in `docker-compose.yml`
- Starts the container in detached mode
- Displays the last 100 log lines for verification

On first startup, the container creates `config/.env` and waits for valid credentials.

After saving your credentials, the next cycle:

- Detects your current IPv4 (and IPv6 if configured)
- Pushes dynamic records to dns24
- Verifies them against `ns1.dns24.ch` and `ns2.dns24.ch`
- Starts propagation tracking if enabled

## Usage

| Command | Description |
|---------|-------------|
| `docker-compose up -d` | Start in background |
| `docker-compose logs -f` | Follow live logs |
| `docker-compose down` | Stop |
| `docker-compose up --build` | Rebuild and start |
| `docker run --rm -v ./config:/config ddns-updater --test` | Full validation test |
| `docker run --rm -v ./config:/config ddns-updater --test-prop` | Propagation snapshot |

## Settings Reference

All settings in `config/.env`. Only `DNS24_USER` and `DNS24_PASS` are required.

### Credentials

| Setting | Default | Description |
|---------|---------|-------------|
| `DNS24_USER` | — | dns24.ch username (email) |
| `DNS24_PASS` | — | dns24.ch password (use single quotes for special chars) |
| `DNS24_API_URL` | `http://dyn.dns24.ch/update` | API endpoint |

### Discord

| Setting | Default | Description |
|---------|---------|-------------|
| `DISCORD_WEBHOOK` | — | Main notifications (IP changes, errors, outages) |
| `DISCORD_WEBHOOK_PROPAGATION` | same as main | Separate channel for propagation tracking |
| `DISCORD_NOTIFY_STARTUP` | `true` | Notification on container start |
| `DISCORD_NOTIFY_UNCHANGED` | `false` | Notify every cycle even when IP hasn't changed |

### Timing

| Setting | Default | Description |
|---------|---------|-------------|
| `CHECK_INTERVAL` | `30` | Seconds between IP checks |
| `RESOLVER_TIMEOUT` | `5` | Timeout for public IP resolvers |
| `DNS24_TIMEOUT` | `10` | Timeout for dns24 API calls |

### IP Resolution

| Setting | Default | Description |
|---------|---------|-------------|
| `SELF_HOSTED_RESOLVER` | — | Your own IP resolver URL (checked first) |
| `FORCE_IPV4` | `true` | Force IPv4 for curl |
| `PUBLIC_RESOLVERS` | ifconfig.me, icanhazip.com, api.ipify.org, checkip.amazonaws.com | Comma-separated list |

### Verification

| Setting | Default | Description |
|---------|---------|-------------|
| `NS1` | `ns1.dns24.ch` | Primary authoritative nameserver |
| `NS2` | `ns2.dns24.ch` | Secondary authoritative nameserver |
| `DRIFT_CHECK_INTERVAL` | `10` | Check a random record every N cycles |

### Propagation

| Setting | Default | Description |
|---------|---------|-------------|
| `PROPAGATION_ENABLED` | `true` | Enable global propagation tracking |
| `PROPAGATION_INTERVAL` | `30` | Seconds between propagation rounds |
| `PROPAGATION_MAX_ROUNDS` | `10` | Max rounds before giving up |
| `PROPAGATION_ZONES` | see below | Comma-separated resolver list |

**Default zones:**

| Resolver | Type | IP |
|----------|------|----|
| Cloudflare | Anycast | 1.1.1.1 |
| Google DNS | Anycast | 8.8.8.8 |
| OpenDNS | Anycast | 208.67.222.222 |

> Anycast resolvers test independent cache pools. You can add geo-pinned resolvers via the `PROPAGATION_ZONES` setting.

### Logging

| Setting | Default | Description |
|---------|---------|-------------|
| `LOG_LEVEL` | `info` | Log verbosity |
| `KEEP_IP_HISTORY` | `true` | Log IP changes to history file |
| `IP_HISTORY_MAX_LINES` | `1000` | Max history lines (0 = unlimited) |

## Test Mode

```bash
docker run --rm -v $(pwd)/config:/config ddns-updater --test
```

Validates everything without making changes:
- Credentials and API connectivity
- Record file parsing with type detection
- IP resolution (IPv4 + IPv6 if AAAA configured)
- NS reachability (`ns1.dns24.ch`, `ns2.dns24.ch`)
- NS spot-check for existing records
- Pending retry queue status
- Discord webhook connectivity
- Propagation snapshot

## File Structure

```
dns24-ddns-docker/
├── Dockerfile
├── docker-compose.yml
├── entrypoint.sh               Bootstrapping, validation, settings display
├── .env.example                Config template (baked into image)
├── .gitattributes              Force LF line endings
├── script/
│   └── ddns-updater.sh         DDNS engine
├── config/                     Mounted at runtime
│   ├── .env                    Your settings (auto-created on first run)
│   ├── records/
│   │   └── example.ch          One file per domain
│   └── meta/                   Auto-populated runtime data
│       ├── ipholder.txt        Current IPv4
│       ├── ipholder_v6.txt     Current IPv6 (if AAAA used)
│       ├── iphistory.txt       IP change log
│       ├── pending.list        Failed/unconfirmed record queue
│       ├── outage_counter      Consecutive API failure count
│       └── cycle_counter       Current cycle number (for drift checks)
└── README.md
```

## Building & Publishing

### Build locally

```bash
docker build -t ddns-updater .
docker run -d --name ddns-updater \
  --restart unless-stopped \
  -v $(pwd)/config:/config \
  --dns 1.1.1.1 --dns 8.8.8.8 \
  ddns-updater
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Container loops "Waiting for config" | Edit `config/.env` with real credentials |
| `CRLF` / `bash\r` errors | Run `git add --renormalize .` or re-clone |
| DNS24 auth errors | Check username/password, use single quotes for special chars |
| AAAA records skipped | No IPv6 available from resolvers — check connectivity |
| Static records not updating | Check NS verification in logs — records only push if NS shows mismatch |
| All updates failing | Check `config/meta/outage_counter` — may be dns24 outage |
| Drift alert fired | A record changed outside the updater — re-pushed automatically |

## Discord Notification Types

| Event | Color | When |
|-------|-------|------|
| IP changed, all confirmed | 🟢 Green | Every IP change |
| IP changed, some failed | 🟡 Yellow | Partial failure |
| IP changed, all failed | 🔴 Red | Total failure |
| IPv6 changed | 🔷 Blue | IPv6 address change detected |
| IPv6 unavailable | 🟡 Yellow | AAAA configured but no IPv6 |
| NS verified | 🟢 Green | Records confirmed on ns1/ns2 |
| Static records checked | 🔵 Blue | Static record verification results |
| Retry queue | 🟢/🟡 Green/Yellow | Failed records retried |
| Pending queue | 🟠 Orange | Records still awaiting retry |
| dns24 API issues (2-4 fails) | 🟡 Yellow | Early warning |
| dns24 down (5+ fails) | 🔴 Red | Extended outage |
| dns24 recovered | 🟢 Green | After outage clears |
| Drift detected | 🟡 Yellow | NS returns unexpected value |
| Propagation complete | 🟢 Green | All zones confirmed |
| Propagation tracking | 🟠 Orange | Round-by-round updates |

## License

MIT
