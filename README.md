# DayZ Linux Server Manager

Manage a DayZ Standalone dedicated server on Linux: install, update, mods,
backups, crash recovery, RCon and an optional web GUI — from one script.

Originally by **@fiskce / @tootlejack / @thelastnoc / @haywardgg**, with
contributions from **@runtime-legend** (crash diagnostics, workshop retry
logic, Steam API polling, config generation).

## Highlights

- **One command per job** — `start`, `stop`, `update`, `workshop`, `backup`, …
- **Crash supervision** — `monitor` collects diagnostics and restarts a
  crashed server; a per-minute systemd timer is included.
- **Steam-friendly** — SteamCMD sessions and Steam Web API queries are
  cached, batched and rate-limited (see "Steam behaviour" below).
- **Compressed, verified backups with `restore`** — pre-restore snapshots
  make a wrong restore recoverable.
- **Web GUI (Dash + Mantine)** — `dayzweb.py` is included: status, player
  history, mod list and one-click actions, with token auth off localhost.
- **Safe config handling** — `config.ini` is parsed as data, never executed,
  and is git-ignored along with all other secrets and state.

## Requirements

- Linux with bash 4+, `tmux`, `curl`, `jq`, `wget`, `tar`, `awk`, `sed`
  (`main.sh install` names the exact packages for your distribution).
- 32-bit glibc libraries for SteamCMD (`lib32gcc-s1` and friends).
- Optional: `python3` for the player count query, `bercon-cli` for RCon.

## Quick start

```bash
./main.sh setup          # interactive config: Steam account, ports, RCon, web GUI
./main.sh install        # SteamCMD + DayZ server files (also runs automatically)
./main.sh mods add 1559212036
./main.sh workshop       # download and link the mods
./main.sh updateconfig   # rebuild the workshop= launch line
./main.sh start
```

Run `./main.sh help` for the full command list.

## Commands

| Command | Description |
|---|---|
| `setup` | Interactive first-run configuration |
| `status [--json]` | Server status (JSON for scripts/GUI) |
| `start` / `stop` / `restart` | Lifecycle (stop is graceful, 90s grace) |
| `monitor` | Restart the server if it crashed (cron/systemd entry point) |
| `console` | Attach to the server console (tmux) |
| `install` | Install SteamCMD and the server files |
| `update [--force]` | Check for and apply server updates |
| `validate` | Validate server files with SteamCMD |
| `workshop` | Download and link Steam Workshop mods |
| `checkmods` | Flag upstream mod updates for the next start |
| `updateconfig` | Rebuild the `workshop=` launch line |
| `backup` | Compressed, verified backups of mission + server profile |
| `restore [archive]` | Restore a backup (no argument lists the archives) |
| `wipe` | Wipe players and Central Economy storage |
| `cleancache` | Clear SteamCMD/workshop caches (keeps Steam login) |
| `cleanserver` | Delete everything for a fresh start |
| `mods add\|remove\|list\|export\|import` | Manage the mod list (ids or workshop URLs) |
| `players [list]` | Current player count, or names with `list` |
| `rcon <command>` | Send a BattlEye RCon command |
| `web start\|stop\|status` | Control the web GUI |
| `systemd` | Write systemd user units |

## Configuration (`config.ini`)

Created on first run; `setup` fills in the important values. The file is
parsed as plain `key=value` data — values may reference other values with
`${name}` (resolved after loading, so line order does not matter). It is
never executed as shell, and it is git-ignored.

| Key | Default | Meaning |
|---|---|---|
| `steamlogin` | `CHANGEME` | Steam account that owns DayZ |
| `appid` / `dayz_id` | `223350` / `221100` | Server app / DayZ workshop app id |
| `port` | `2302` | Game port (query port lives in `serverDZ.cfg`) |
| `limitFPS` | `60` | Server frame-rate cap |
| `workshop_retries` | `5` | Download attempts per mod |
| `backup_retention_days` | `2` | Delete backups older than this |
| `backup_retention_count` | `10` | Keep at most this many archives per kind |
| `crash_retention_count` | `10` | Keep at most this many crash-log directories |
| `auto_update_on_start` | `1` | Check for server updates on every start |
| `steam_api_cache_ttl` | `900` | Seconds between Steam Web API queries |
| `steam_update_check_interval` | `600` | Seconds between remote build checks |
| `steamcmd_cooldown` | `5` | Minimum seconds between SteamCMD sessions |
| `steamcmd_batch_size` | `8` | Mods downloaded per SteamCMD session |
| `min_free_mb` | `2048` | Refuse updates/downloads below this free space |
| `log_level` | `normal` | `quiet`, `normal` or `verbose` console output |
| `log_max_kb` / `log_keep` | `1024` / `3` | Log rotation size and generations kept |
| `web_bind` / `web_port` | `127.0.0.1` / `8080` | Web GUI bind address / port |
| `web_token` | *(empty)* | Web GUI access token (required off localhost) |
| `discord_webhook_url` | *(empty)* | Discord notifications |

`dayzparameter`, `BEpath`, `profiles`, `workshop` and `servermods` build the
server launch line; `setup` and `updateconfig` maintain them for you.

Numeric knobs are validated on load: out-of-range or non-numeric values are
reported once and reset to their defaults. `STEAMLOGIN=<user>` in the
environment overrides `steamlogin`, so the account name can stay out of the
file entirely.

## Backups and restore

`backup` writes gzip archives of the mission folder and the server profile
into `~/backup/`, verifies each archive after writing, and prunes by age
*and* by count. Restore any archive with:

```bash
./main.sh restore                 # list available archives
./main.sh restore dayzOffline.chernarusplus-2026-10-19-12-00.tar.gz
```

A restore stops the server if needed, takes a **pre-restore snapshot first**
(so a wrong pick is recoverable), detects from the archive contents whether
it is a mission or a profile backup, and restarts the server afterwards if it
was running. Old `.tar` (pre-compression) archives remain restorable.

## Scheduling (systemd)

`./main.sh systemd` writes user units and timers: the server service, a
per-minute crash monitor, a 2-hourly mod-update check and the web GUI.

```bash
systemctl --user daemon-reload
systemctl --user enable --now dayzserver.service
systemctl --user enable --now dayzserver-monitor.timer
systemctl --user enable --now dayzserver-checkmods.timer
sudo loginctl enable-linger "$USER"     # start at boot without logging in
```

## Web GUI (dayzweb.py)

A Dash + Mantine dashboard showing live status, player-count history, the
mod list and recent events, with buttons for start/stop/restart/update/
validate/workshop/checkmods/backup. The buttons run the same `main.sh`
commands as the CLI, so the run locks and pre-flight checks all apply.

```bash
pip3 install -r requirements.txt   # dash, dash-mantine-components, plotly
./main.sh web start                # or: python3 dayzweb.py
```

Security model — pick one:

- **`web_bind=127.0.0.1` (default, recommended):** no token needed; reach it
  with `ssh -L 8080:127.0.0.1:8080 user@server`.
- **Any other bind:** `web_token=` in `config.ini` is **required** — the GUI
  refuses to start without one. Authenticate via the `/login` page, a
  `?token=...` URL, or an `Authorization: Bearer <token>` header. Still put
  it behind a TLS reverse proxy; the GUI itself speaks plain HTTP.

State lives in `~/.dayzweb_history.jsonl` (bounded) and `~/.dayzweb.log`
(rotated by the manager's log rotation).

## Concurrency and locks

- `${HOME}/.dayz.runlock` — one mutating operation at a time. `monitor` skips
  quietly when another operation runs; other commands fail fast and name the
  holder. Stale locks (dead owner) are broken automatically.
- `${HOME}/.dayzlockupdate` — "update in flight, monitor stand down". Removed
  on completion, by exit/signal traps, and swept after 6 hours if a run was
  killed outright.
- `${HOME}/.dayzlockfile` — "the server is supposed to be up"; `monitor`
  restarts the server only while this exists.

## Steam behaviour

Everything that talks to Steam lives in `lib/steam.sh` and follows two rules:
*never spam Steam* and *degrade to cache*.

- SteamCMD runs through one runner that keeps `steamcmd_cooldown` seconds
  between sessions; workshop mods download `steamcmd_batch_size` per session
  and only failures are retried (exponential backoff + jitter, capped).
- Server build checks are cached for `steam_update_check_interval`; the
  `appinfo.vdf` cache is only cleared after a failed check or by `cleancache`.
- Web API queries are cached for `steam_api_cache_ttl`, batched 100 ids per
  request, single-flight (one in-process query at a time), retried with
  exponential backoff and honouring HTTP 429 `Retry-After`. When Steam is
  unreachable the most recent cached answers are served instead of failing.
- To check for updates more often than the cache allows, use
  `./main.sh update --force`.

## Project layout

```
main.sh            entry point: startup, command dispatch
dayzweb.py         web GUI (Dash + Mantine)
requirements.txt   web GUI dependencies
lib/common.sh      colours, logging, prompts, config access, run locking
lib/config.sh      config.ini creation/loading, interactive setup
lib/deps.sh        root/screen checks, packages, dependency check
lib/steam.sh       SteamCMD + Steam Web API (cached, rate-limited)
lib/workshop.sh    workshop mods: download, link, keys, updates
lib/server.sh      start/stop/restart/monitor/backup/restore/wipe
lib/query.sh       status report, A2S player query, BattlEye RCon
lib/web.sh         web GUI control
lib/systemd.sh     systemd user unit generation
```

Every module is a standalone-executable script: run one without arguments to
see what it provides. Mutating module actions require explicit subcommands
(e.g. `lib/steam.sh update`), and the run lock applies wherever `main.sh`
takes it.

## Security notes

- `config.ini` is parsed as data, not executed as shell (it used to be
  sourced). Values cannot run commands.
- `.gitignore` keeps `config.ini` (Steam account, RCon password) and all
  runtime state out of version control; `.gitattributes` pins LF line
  endings so the scripts stay runnable on Linux.
- Generated files containing secrets (`config.ini`, BattlEye config) are
  chmod 600, and `STEAMLOGIN` can keep the account name out of the file.
- RCon commands pass the BattlEye config directory to `bercon-cli`, which
  reads `RConPassword` from `beserver_x64*.cfg` itself — the password never
  appears in `ps` output or the environment.
- The web GUI requires a token on any non-loopback bind and compares it in
  constant time.

## License

MIT — see [LICENSE](LICENSE).
