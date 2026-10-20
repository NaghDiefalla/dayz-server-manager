# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.3.0] - 2026-10-19

### Added
- `dayzweb.py`: web GUI built with Dash + dash-mantine-components. Live
  status cards, player-count history chart, mod list, monitor.log tail and
  action buttons (start/stop/restart/update/validate/workshop/checkmods/
  backup) that run the same `main.sh` commands as the CLI. Token auth via
  `/login`, `?token=` or `Authorization: Bearer`; required on any non-loopback
  bind, optional on localhost. `requirements.txt` included.
- Config validation: numeric knobs are range-checked on load; invalid values
  warn once and reset to defaults (`fn_cfg_validate`).
- Log management: `log_level` (quiet/normal/verbose), size-based rotation
  (`log_max_kb`, `log_keep`) for `monitor.log` and `dayzweb.log`.
- Crash diagnostics now classify the likely cause (OOM, native crash, exit
  codes 134/137/139) into `cause.txt`, report it in `monitor.log` and the
  Discord alert, and prune old crash directories (`crash_retention_count`).
- Pre-flight disk checks (`min_free_mb`): updates and workshop downloads
  refuse to start on a too-full disk; backups only warn. `python3` is
  reported as an optional dependency by `check_dependencies`.
- Mod management: `mods export`/`mods import` for sharing mod lists, workshop
  URLs accepted in `workshop.cfg` and on `mods add`, names resolved from the
  cached Steam API at add time, and `players list` shows connected player
  names via A2S_PLAYER.

### Changed
- RCon commands pass the BattlEye directory to `bercon-cli --server-cfg`,
  which reads `RConPassword` from `beserver_x64*.cfg` itself: the password
  no longer appears in `ps` output or the environment.
- `STEAMLOGIN` in the environment overrides `steamlogin` from `config.ini`,
  so the account name can stay out of the file.
- The web GUI runs the `dayzweb.py` vendored in the repository (the old
  `~/dayzweb.py` fallback is kept); the systemd unit and `web` command both
  resolve it automatically.
- The Steam Web API cache now also stores workshop titles for name
  resolution.

## [2.2.0] - 2026-10-19

### Added
- `restore` command: restores mission or serverprofile backups, detects the
  archive kind from its contents, and takes a pre-restore snapshot so a wrong
  choice is recoverable. `restore` without arguments lists the archives.
- Backup archives are gzip-compressed, verified after writing, and pruned by
  age *and* by count (`backup_retention_count`, default 10 per kind).
- Manager-wide run lock (`~/.dayz.runlock`): mutating commands are
  serialised, `monitor` skips quietly while another operation runs, and
  stale locks (dead owner) are broken automatically.
- Exit/signal traps that remove `.dayzlockupdate` when a run is killed, plus
  a 6-hour stale sweep for locks orphaned by SIGKILL or a reboot.
- `.gitignore` (secrets and runtime state stay out of version control) and
  `.gitattributes` (LF endings enforced).
- README, LICENSE (MIT) and this changelog.

### Changed
- `config.ini` is now parsed as data instead of being sourced as shell.
  Values can no longer execute commands, `${name}` references resolve
  regardless of line order, and the generated file needs no quote escaping.
- Generated systemd units invoke the top-level `main.sh` no matter which
  module writes them, gain sandboxing (`NoNewPrivileges`, `PrivateTmp`,
  `ProtectSystem=full` for the web GUI) and `RandomizedDelaySec` on timers.

### Fixed
- `lib/systemd.sh install` baked `lib/systemd.sh` into `ExecStart`, producing
  units whose start/stop commands only printed usage.

## [2.1.0] - 2026-10-19

### Changed
- Modularised the single-script manager into `main.sh` + `lib/*.sh`; every
  module is a standalone-executable Linux script.
- Steam access rewritten around two rules: never spam Steam, degrade to
  cache. SteamCMD sessions are rate-limited (`steamcmd_cooldown`) and workshop
  mods download in batches (`steamcmd_batch_size`) with only failures retried
  using exponential backoff with jitter.
- Steam Web API queries are cached (`steam_api_cache_ttl`), batched 100 ids
  per request, single-flight, retried with backoff and honouring HTTP 429
  `Retry-After`.
- Server build checks are cached (`steam_update_check_interval`); `update
  --force` bypasses the cache.

### Fixed
- `appinfo.vdf` was deleted on every update check, forcing SteamCMD to
  re-download app metadata each time. It is now cleared only after a failed
  check or by `cleancache`.
- `ansi=off` in `config.ini` is honoured (colours were initialised before the
  config was loaded).
- Already-current workshop mods are no longer reported as download failures.

## [2.0.0] - unrecorded

Community fork contributions: crash diagnostics collection, workshop retry
logic, Steam API update polling, interactive config generation, status JSON
output, web GUI and systemd integration. See git history for details.

## [1.x] - unrecorded

Original releases by @fiskce, @tootlejack, @thelastnoc and @haywardgg.
