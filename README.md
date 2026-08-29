# scmn (v0.7.1)

> A lightweight, zero-daemon Linux service manager built on top of GNU Screen.

`scmn` is a powerful yet simple service manager that supervises background applications using GNU Screen sessions. It provides process monitoring, immediate crash recovery, log management, interactive process attachment, and cron-based watchdog supervision—without requiring a heavy background daemon.

---

## Key Features

- **Zero-Daemon Architecture**: Consumes **0 MB RAM** at idle. Only executes when invoked directly or periodically via cron.
- **Interactive Attach/Detach**: Seamlessly jump into any service's console using native GNU Screen (`Ctrl+A`, then `D` to detach).
- **Service Enable & Disable**: Enable or disable services directly from the CLI (`scmn enable`, `scmn disable`) with optional immediate action (`--now`).
- **Direct Input Injection**: Send commands/input directly to a running service's `stdin` without attaching (`scmn send`).
- **Flexible Restart Policies**:
  - `always`: Continuously loops and restarts the process immediately upon exit.
  - `on-failure`: Restarts only on non-zero exit codes; cleanly exits on `exit 0`.
  - `false`: Runs once and relies on cron checks or manual restarts.
- **Automated Log Management**: Automatically truncates log files exceeding **50 MB** down to 25 MB in-place without breaking active logging descriptors.
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
| `scmn enable <shortname> [--now]` | Enables service in config (uncomments line); starts immediately with `--now` |
| `scmn disable <shortname> [--now]` | Disables service in config (comments out line); stops immediately with `--now` |
| `scmn attach <shortname>` (or `a`) | Attaches directly to the service console (`attach` shows detach instructions, `a` attaches immediately) |
| `scmn send <shortname> "<text>"` | Sends input/command to the service `stdin` |
| `scmn stop <shortname\|--all>` | Gracefully stops service (`SIGTERM`) with `SIGKILL` fallback |
| `scmn restart <shortname\|--all>` | Restarts one or all services |
| `scmn log [shortname] [lines]` | Tails service log (or scmn manager log if shortname omitted) |
| `scmn cron install` | Installs 15-minute watchdog cron job into crontab |
| `scmn cron uninstall` | Removes watchdog cron job from crontab |
| `scmn cron status` | Checks if the watchdog cron job is active |
| `scmn version` (or `-V`, `--version`) | Displays version information |
| `scmn help` (or `-h`, `--help`) | Displays help message |

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

### 4. Custom Log Size Limits
By default, log files are truncated when they exceed **50 MB** (keeping the last 25 MB). You can override this limit via the `MAX_LOG_SIZE_MB` environment variable:

```bash
MAX_LOG_SIZE_MB=100 scmn
```

---

## AI Disclosure

Google Antigravity did the heavy coding.

---

## License

MIT License. Feel free to use and modify!
