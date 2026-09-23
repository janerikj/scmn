# scmn (v1.0.0)

> A lightweight, zero-daemon Linux service manager built on top of GNU Screen.

`scmn` is a powerful yet simple service manager that supervises background applications using GNU Screen sessions. It provides process monitoring, immediate crash recovery, log management, interactive process attachment, and cron-based watchdog supervision—without requiring a heavy background daemon.

---

## Key Features

- **Zero-Daemon Architecture**: Consumes **0 MB RAM** at idle. Only executes when invoked directly or periodically via cron.
- **Docker Integration**: Services launched via `docker run` are tracked by a `scmn.service` label (injected automatically) plus a deterministic `--name`. `stop`/`restart`/`reload` also stops and removes the underlying containers — no orphaned containers left behind when the screen session dies.
- **Interactive Attach/Detach**: Seamlessly jump into any service's console using native GNU Screen (`Ctrl+A`, then `D` to detach).
- **Smart Config Sync (`reload`)**: Hot-reloads configuration—starts missing services, restarts changed services, and stops disabled/removed services without unnecessary restarts.
- **Config Validation (`check`)**: Validates syntax, duplicate names, paths, executables, and restart policies before deployment.
- **Service Enable & Disable**: Enable or disable services directly from the CLI (`scmn enable`, `scmn disable`) with optional immediate action (`--now`).
- **Direct Input Injection**: Send commands/input directly to a running service's `stdin` without attaching (`scmn send`).
- **Flexible Restart Policies**:
  - `always`: Continuously loops and restarts the process immediately upon exit.
  - `on-failure`: Restarts only on non-zero exit codes; cleanly exits on `exit 0`.
  - `false`: Runs once and relies on cron checks or manual restarts.
- **Automated Log Management & Clearing**: Automatically truncates log files exceeding **50 MB** down to 25 MB in-place, and supports clearing logs on demand (`scmn log clear`).
- **Status Metrics & Health Detection**: Real-time overview of process state (`RUNNING` in green, `RESTARTING` in yellow for crash loops, `STOPPED` in red, `DISABLED` in gray), PID, memory usage (RAM), uptime, restart policy, and logfile paths.
- **Central Event Logging**: Records meaningful state changes, restarts, stops, and truncations to `~/.config/scmn/scmn.log` while keeping routine cron checks silent.
- **Cron Watchdog**: Built-in commands to install/uninstall a 15-minute cron watchdog to ensure long-term availability.

---

## Requirements

- **Linux / Unix**
- **GNU Screen** (`screen`)
- **Bash 4.0+**
- Standard utilities (`grep`, `awk`, `ps`, `tail`, `crontab`)

---

## Quick Start

### 1. Make `scmn` executable
```bash
chmod +x scmn
```

### 2. Create Configuration File
Create `~/.config/scmn/scmn.conf` (or `./scmn.conf` in your project folder):

```bash
# Format: shortname | directory | command | logfile | env | auto_restart

# Web service running from /var/www with environment variables
webserver | /var/www | python3 -m http.server $PORT | /var/log/web.log | PORT=8080 | always

# Worker job that only restarts on crash/error
worker | /app | python3 worker.py | /var/log/worker.log | NODE_ENV=production | on-failure

# Background ping utility without logging
ping_bot | - | ping -i 2 1.1.1.1 | none | - | false
```

### 3. Start Services & Check Status
```bash
# Start all configured services
./scmn

# View status
./scmn status
```

---

## Command Reference

| Command | Description |
| :--- | :--- |
| `scmn [start] [shortname]` | Starts missing services (or a single specified service) |
| `scmn status` (or `ls`) | Displays table with service status, PID, RAM, Uptime, and config |
| `scmn status <shortname>` | Detailed status page for one service: screen session + workload process (or container) RAM & uptime |
| `scmn reload` | Syncs running services with config (starts missing, restarts changed, stops disabled/removed) |
| `scmn check` | Validates configuration file syntax, paths, binaries, and policies |
| `scmn enable <shortname> [--now]` | Enables service in config (uncomments line); starts immediately with `--now` |
| `scmn disable <shortname> [--now]` | Disables service in config (comments out line); stops immediately with `--now` |
| `scmn attach <shortname>` (or `a`) | Attaches directly to the service console |
| `scmn send <shortname> "<text>"` | Sends input/command to the service `stdin` |
| `scmn stop <shortname\|--all>` | Gracefully stops service (`SIGTERM`) with `SIGKILL` fallback |
| `scmn restart <shortname\|--all>` | Restarts one or all services |
| `scmn log [shortname] [lines]` | Tails service log (or scmn manager log if shortname omitted) |
| `scmn log clear [name\|--all]` | Clears service log, all logs (`--all`), or scmn manager log |
| `scmn cron install` | Installs 15-minute watchdog cron job into crontab |
| `scmn cron uninstall` | Removes watchdog cron job from crontab |
| `scmn cron status` | Checks if the watchdog cron job is active |
| `scmn docker orphans [--clean]` | Lists/cleans orphaned docker containers | 
| `scmn version` (or `-V`, `--version`) | Displays version information |
| `scmn help` (or `-h`, `--help`) | Displays help message |

> **Cron watchdog & PATH:** the memo `scmn cron install` creates run every 15 minutes as a bare `cron` job, whose environment has a minimal PATH (`/usr/bin:/bin`). `scmn` therefore prepends `~/.local/bin` and `~/bin` to `PATH` at startup, so services using tools installed outside the system dirs start correctly. If a service command cannot be resolved at start, `scmn` prints a clear `Command not found` error instead of silently cycling in `RESTARTING`.

---

## Configuration File Reference

`scmn` searches for configuration files in the following order:
1. Specified via `-c /path/to/file.conf` or `--config /path/to/file.conf`
2. Specified via `SCMN_CONF` environment variable
3. `./scmn.conf` (current working directory)
4. `~/.config/scmn/scmn.conf` (recommended user location)
5. `/etc/scmn/scmn.conf` (system-wide location)

### Syntax:
```text
shortname | directory | command | logfile | env | auto_restart
```

- **`shortname`**: Unique identifier for the service session.
- **`directory`**: Working directory where the command executes (`-` or empty for current dir).
- **`command`**: Full shell command to execute.
- **`logfile`**: Path to log file (`none`, `off`, or `-` to disable file logging).
- **`env`**: Optional environment variables (`PORT=8080 NODE_ENV=production` or `-`).
- **`auto_restart`**: Restart policy inside Screen:
  - `always` (or `true`): Always restarts immediately upon exit.
  - `on-failure` (or `fail`): Restarts immediately only if exit code is non-zero.
  - `false` (or `no`): No immediate restart loop.

Lines starting with `#` and matching the syntax above are treated as disabled services; other lines starting with `#`, as well as empty lines, are ignored.

---

## Tips & Advanced Usage

### 1. Service Dependencies & Startup Delay (`sleep`)
Services start sequentially from top to bottom as listed in `scmn.conf`. If a service requires a preceding service (e.g. a database) to be fully initialized first, prepend a sleep command:

```text
# Starts after a 3-second delay to allow database readiness
api_server | /app | sleep 3 && node server.js | /var/log/api.log | - | always
```

### 2. Running Services with `sudo` / Root Privileges
There are two ways to handle commands requiring elevated permissions:

#### Approach A: Run `scmn` under `sudo` (Recommended for root daemons)
```bash
sudo scmn start
sudo scmn status
sudo scmn cron install
```
All spawned screens and processes inherit root permissions cleanly without password prompts.

#### Approach B: User-level `scmn` with `sudo` in command
If running `scmn` as a non-root user, configure `NOPASSWD` in `/etc/sudoers` for that specific command:
```text
your_username ALL=(ALL) NOPASSWD: /usr/bin/python3
```
Without `NOPASSWD`, service will hang waiting. Use `attach` to access the console and enter password. 

### 3. Detaching from a Screen Session
When connected to a service via `scmn attach <shortname>`:
- Press **`Ctrl + A`**, then press **`D`** to detach cleanly without stopping the service.
- If the service session is already attached elsewhere (e.g. a dropped SSH connection left it stuck as "attached"), `scmn attach <shortname>` refuses with an explanation — use `scmn attach --force <shortname>` to detach the other end and take over.

### 4. Custom Log Size Limits
By default, log files are truncated when they exceed **50 MB** (keeping the last 25 MB). You can override this limit via the `MAX_LOG_SIZE_MB` environment variable:

```bash
MAX_LOG_SIZE_MB=100 scmn
```

### 5. Python Applications in a Virtualenv
`scmn` runs an arbitrary shell command in a screen session, so a virtualenv works out of the box — point the command at the venv's own binary instead of activating it (the `directory` column is used as the working directory, and the `env` column can export `VIRTUAL_ENV` for apps that read it):

```text
# Recommended: call the venv binary directly (no activation needed)
myapp | /home/jej/myapp | .venv/bin/python main.py | /tmp/myapp.log | VIRTUAL_ENV=/home/jej/myapp/.venv | always
# Or for a venv-installed entry point / console script
api   | /home/jej/api  | .venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000 | /tmp/api.log | - | always
```

Activation inside the command also works (restart loops run in a shell, so `source` + `&&` is fine):

```text
myapp | /home/jej/myapp | source .venv/bin/activate && python main.py | /tmp/myapp.log | - | on-failure
```

### 6. Environment Variables from a `.env` File
Keep passwords and API keys out of `scmn.conf`, where they also leak into `.state` and the logs. Instead, put them in a `.env` file in the service's working directory: `scmn` loads it into the service's shell before the command runs, and the command references the variables (e.g. `${DB_PASSWORD}`) so status and logs show names, not secrets.

- Syntax: `KEY=value` or `export KEY=…`, `#` comments, quote values containing spaces.
- Exported **inside the screen session only** — never into scmn's own process, `.state`, or the event log.
- The `env` column (5th) is exported after and overrides `.env` values.
- `scmn` warns if `.env` is group/other-readable; `chmod 600` silences it.

### 7. Console Status Bar & Scrollback Buffer
When attaching to a service (`scmn attach <shortname>`), `scmn` displays a status bar at the bottom of the screen with the service name, detach shortcut (`Ctrl+A D`), hostname, and time. Sessions automatically run in **UTF-8 mode (`-U`)** with **1000 lines of scrollback buffer in RAM** (customizable via `SCMN_SCROLLBACK=5000`). To enable scrollback and copy mode: press `Ctrl+A Esc`.

### 8. Docker-based Services (`docker run`)
`docker run` does **not** run your application as a child of the `docker run` client — the container executes under the Docker daemon (`dockerd`). Killing the screen session only kills the client, so the container would keep running. `scmn` therefore treats docker services specially:

- On **start**, `scmn` automatically injects a tracking label `--label scmn.service=<shortname>` and, when the command lacks an explicit `--name`, a deterministic `--name scmn_<shortname>` (lowercased). Label-based tracking means containers are findable even if they end up with random names (e.g. leftovers started before docker support existed).
- On **stop / restart / reload**, `scmn` also stops and removes the containers belonging to the service (`docker stop`, then `docker rm -f`), matched by label or name.
- If the screen session is gone but a container still runs, `scmn status` shows the service as **`ORPHANED`** with the container ID as its PID (instead of `STOPPED`).
- **Self-healing supervision**: for *foreground* containers (no `-d`), `scmn start`/`scmn reload`/cron and `scmn attach` automatically re-create the supervising screen session with `docker attach` when the container still runs but its session was lost (e.g. after a `docker.service` restart) — so status returns to `RUNNING` and attach keeps working. Detached (`docker run -d`) services intentionally stay unsupervised.
- **Detach vs. stop while attached**: normal supervision runs the attached `docker run` client. `Ctrl+A D` detaches without touching the container; `Ctrl+C` forwards SIGINT to the container's main process (Docker's default signal proxy) and therefore **stops the service** (status `STOPPED`) — restart it with `scmn start <shortname>`. In a restored `docker attach --sig-proxy=false` session, `Ctrl+C` only kills the supervising client, leaving the container running (`RESTORABLE`).
- Docker services are **never wrapped in a restart loop** (running `docker run` again while the container lives would collide on `--name` and fail forever). Use the Docker **`--restart`** policy in the command to control restarts — e.g. `docker run --restart unless-stopped --name mybot myimage:latest`.
- `scmn status` for a running docker service reports the **container's** memory and uptime (via `docker stats`/`docker inspect`), not the `docker run` client's.

Recommended docker service definition (loops and restart policies are handled by Docker):

```text
mybot | /app | docker run --restart unless-stopped --name mybot myimage:latest | /var/log/mybot.log | - | no
```

**`scmn docker orphans [--clean]`** lists running containers in one block per container (NAME/STATUS/CONTAINER/IMAGE/NOTE), with these statuses:
- **MANAGED** — container of a *currently configured* service with a live screen session (healthy).
- **ORPHANED (RESTORABLE)** — container of a *currently configured* service whose screen session is gone (e.g. the `docker run` client exited when the engine restarted the container). The engine keeps the container running and `scmn start`/`scmn attach` re-attach supervision. **`--clean` never removes these.**
- **ORPHANED** — container of a service **no longer in the config** (renamed/removed), carrying a `scmn.service` label or `scmn_` name; `--clean` stops and removes these automatically.
- **UNTRACKED** — no scmn label/name at all; these are probably unrelated containers and are never touched without an interactive per-container confirmation.

Containers owned by currently configured services are therefore always safe from `--clean`, even if an engine restart has temporarily detached their screen session.

> These notes apply to plain `docker run` / `docker container run`. Compose-style stacks (`docker compose up`) are not tracked per-service; stop the stack with `docker compose down`.

---

## AI Disclosure

Google Antigravity did the heavy coding.

Assisted and reviewed by big pickle (opencode).

---

## License

MIT License. Feel free to use and modify!
