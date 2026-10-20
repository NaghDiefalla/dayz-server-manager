#!/usr/bin/env bash
#=======================================================================================#
# lib/common.sh - shared helpers for the DayZ Linux Server Manager
#
# Sourced by main.sh before every other module. Also runnable on its own to
# show what this module provides.
#=======================================================================================#

# Run-once bootstrap. Being sourced twice (main.sh and a standalone module)
# must stay harmless.
if [ -z "${_DAYZ_COMMON_LOADED:-}" ]; then
	_DAYZ_COMMON_LOADED=1
	SCRIPT_VERSION="2.3.0"
	CONFIG_FILE="config.ini"

	# A failure anywhere in a pipeline must fail the pipeline: several checks
	# read SteamCMD through a pipe, and without this a broken steamcmd.sh would
	# look like a clean run.
	set -o pipefail
fi

# ---------------------------------------------------------------------------
# fn_init_colors
# Sets the ANSI palette used by every status line. Called again after
# config.ini is loaded so the `ansi=off` switch actually works; the palette is
# kept complete even where a colour is not currently used.
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------
fn_init_colors(){
	if [ "${ansi:-}" != "off" ]; then
		default="\e[0m"
		red="\e[31m"
		green="\e[32m"
		yellow="\e[33m"
		lightyellow="\e[93m"
		blue="\e[34m"
		lightblue="\e[94m"
		magenta="\e[35m"
		cyan="\e[36m"
		# carriage return & erase to end of line
		creeol="\r\033[K"
	else
		default="" red="" green="" yellow="" lightyellow=""
		blue="" lightblue="" magenta="" cyan="" creeol=""
	fi
}
fn_init_colors

# ---------------------------------------------------------------------------
# fn_trim
# Strips CR (Windows line endings sneak in through copy-paste) and padding
# whitespace.
# ---------------------------------------------------------------------------
fn_trim(){
	printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# fn_log_monitor
# Appends a timestamped line to ~/monitor.log, giving a readable history of
# starts, crashes and automatic restarts. The log is rotated when it exceeds
# log_max_kb, keeping log_keep previous generations.
# ---------------------------------------------------------------------------
fn_log_monitor(){
	fn_rotate_log "${HOME}/monitor.log"
	{
		printf '%s ' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf '%b\n' "$1"
	} >> "${HOME}/monitor.log"
}

# ---------------------------------------------------------------------------
# fn_rotate_log <file> [max_kb] [keep]
# Size-based log rotation: file -> file.1 -> file.2 ... with the oldest
# generation dropped. Keeps unattended installs (cron, systemd timers) from
# growing log files without bound.
# ---------------------------------------------------------------------------
fn_rotate_log(){
	local file="$1" max_kb="${2:-${log_max_kb:-1024}}" keep="${3:-${log_keep:-3}}"
	local size i
	[ -f "${file}" ] || return 0
	size="$(stat -c %s "${file}" 2>/dev/null || echo 0)"
	[[ "${size}" =~ ^[0-9]+$ ]] || return 0
	[ "$(( size / 1024 ))" -lt "${max_kb}" ] && return 0
	rm -f "${file}.${keep}"
	for (( i=keep-1; i>=1; i-- )); do
		[ -f "${file}.${i}" ] && mv -f "${file}.${i}" "${file}.$(( i + 1 ))"
	done
	mv -f "${file}" "${file}.1"
	: > "${file}"
	printf "[ ${lightblue}INFO${default} ] Rotated %s (over %skB).\n" "${file}" "${max_kb}"
}

# ---------------------------------------------------------------------------
# fn_info / fn_debug
# Verbality control via the log_level knob (quiet|normal|verbose). fn_info
# prints ordinary chatter unless quiet; fn_debug only prints when verbose.
# Warnings and failures always print regardless of the level.
# ---------------------------------------------------------------------------
fn_info(){
	[ "${log_level:-normal}" = "quiet" ] && return 0
	printf "$@"
}

fn_debug(){
	[ "${log_level:-normal}" = "verbose" ] || return 0
	printf "$@"
}

# ---------------------------------------------------------------------------
# fn_disk_free_mb <path>
# Free space in megabytes, empty when it cannot be determined.
# ---------------------------------------------------------------------------
fn_disk_free_mb(){
	df -Pm "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# ---------------------------------------------------------------------------
# fn_require_disk <path> <mb> <what> / fn_warn_disk <path> <mb> <what>
# Pre-flight free-space checks. Downloads and updates that start on a full
# disk fail halfway and leave broken installs; require_ refuses to start,
# warn_ only says so (backups still make sense to attempt).
# ---------------------------------------------------------------------------
fn_require_disk(){
	local path="$1" need="$2" what="$3" free
	free="$(fn_disk_free_mb "${path}")"
	[[ "${free}" =~ ^[0-9]+$ ]] || return 0
	if [ "${free}" -lt "${need}" ]; then
		printf "[ ${red}FAIL${default} ] Not enough disk space for %s: %sMB free, %sMB required.\n" \
			"${what}" "${free}" "${need}"
		printf "\tFree some space or lower min_free_mb in %s.\n" "${CONFIG_FILE}"
		return 1
	fi
	fn_debug "[ DEBUG ] Disk check for %s: %sMB free (need %sMB).\n" "${what}" "${free}" "${need}"
	return 0
}

fn_warn_disk(){
	local path="$1" need="$2" what="$3" free
	free="$(fn_disk_free_mb "${path}")"
	[[ "${free}" =~ ^[0-9]+$ ]] || return 0
	if [ "${free}" -lt "${need}" ]; then
		printf "[ ${yellow}WARN${default} ] Low disk space for %s: %sMB free, %sMB recommended.\n" \
			"${what}" "${free}" "${need}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# fn_discord_notify
# Posts a message to the configured Discord webhook. A missing webhook or a
# failing Discord must never affect the actual work, so this is best-effort.
# ---------------------------------------------------------------------------
fn_discord_notify(){
	[ -n "${discord_webhook_url}" ] || return 0
	curl -sS -H "Content-Type: application/json" -X POST \
		-d "$(jq -nc --arg content "$1" '{content: $content}')" \
		"${discord_webhook_url}" > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# fn_prompt
# Asks a question and echoes the answer (or the default when the user just
# presses Enter). Pass "secret" as the third argument to suppress echo.
# ---------------------------------------------------------------------------
fn_prompt(){
	local prompt="$1" default="$2" secret="${3:-}" answer=""
	if [ "${secret}" = "secret" ]; then
		printf "%s: " "${prompt}" >&2
		read -r -s answer
		printf "\n" >&2
	elif [ -n "${default}" ]; then
		printf "%s [%s]: " "${prompt}" "${default}" >&2
		read -r answer
	else
		printf "%s: " "${prompt}" >&2
		read -r answer
	fi
	printf '%s' "${answer:-${default}}"
}

# ---------------------------------------------------------------------------
# fn_cfg_value
# Reads one key from an ini-style file, tolerating spaces and quotes around
# the value.
# ---------------------------------------------------------------------------
fn_cfg_value(){
	local file="$1" key="$2"
	[ -f "${file}" ] || return 1
	grep -iE "^[[:space:]]*${key}[[:space:]]*=?" "${file}" 2>/dev/null \
		| head -n1 \
		| sed -E "s/^[[:space:]]*${key}[[:space:]]*=?[[:space:]]*//I" \
		| tr -d '";' \
		| sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# fn_set_config_value
# Writes one key into config.ini in place, replacing a commented-out or live
# existing entry instead of appending a duplicate. Values containing
# whitespace or quotes are written double-quoted with escaped quotes, the
# exact form fn_cfg_load reads back.
# ---------------------------------------------------------------------------
fn_set_config_value(){
	local key="$1" value="$2" file="${CONFIG_FILE}"
	local tmp="${file}.tmp"
	[ -f "${file}" ] || touch "${file}"
	if [[ "${value}" =~ [[:space:]\"] ]]; then
		value="\"${value//\"/\\\"}\""
	fi
	if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "${file}"; then
		awk -v k="${key}" -v v="${key}=${value}" '
			$0 ~ "^[[:space:]]*#?[[:space:]]*" k "=" && !done { print v; done=1; next }
			{ print }' "${file}" > "${tmp}" && mv "${tmp}" "${file}"
	else
		printf '%s=%s\n' "${key}" "${value}" >> "${file}"
	fi
	chmod 600 "${file}"
}

# ---------------------------------------------------------------------------
# fn_cfg_expand <value>
# Resolves ${name} references in a config value against the other config
# values first and the environment second. Only plain ${NAME} is expanded -
# no command substitution, no backticks - so a config value can never execute
# anything.
# ---------------------------------------------------------------------------
fn_cfg_expand(){
	local __value="$1" __name __repl
	while [[ "${__value}" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
		__name="${BASH_REMATCH[1]}"
		if [ -n "${DAYZ_CFG[${__name}]+x}" ]; then
			__repl="${DAYZ_CFG[${__name}]}"
		else
			case "${__name}" in
				HOME) __repl="${HOME}" ;;
				*)    __repl="$(printenv "${__name}" 2>/dev/null)" ;;
			esac
		fi
		__value="${__value//\$\{${__name}\}/${__repl}}"
	done
	printf '%s' "${__value}"
}

# ---------------------------------------------------------------------------
# fn_cfg_load [quiet]
# Parses config.ini as DATA and exports every key as a shell variable.
#
# config.ini is deliberately NOT sourced any more: sourcing executed it as
# shell code, so a value containing "$(...)" ran commands and every quote in
# the file had to be backslash-escaped. Parsing as data is both safer and
# more forgiving of hand-edited files. References like ${port} are resolved
# after all keys are known, so line order no longer matters.
#
# Lines that are blank or start with # are skipped. Unparsable lines are
# reported (unless "quiet" is passed) and ignored rather than aborting.
# ---------------------------------------------------------------------------
fn_cfg_load(){
	local __quiet="${1:-}" __line __key __value __name __expanded
	declare -gA DAYZ_CFG=()
	[ -f "${CONFIG_FILE}" ] || return 1

	while IFS= read -r __line || [ -n "${__line}" ]; do
		__line="${__line%$'\r'}"
		__line="$(fn_trim "${__line}")"
		[ -z "${__line}" ] && continue
		case "${__line}" in \#*) continue ;; esac
		if [[ "${__line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
			__key="${BASH_REMATCH[1]}"
			__value="${BASH_REMATCH[2]}"
			# Strip one layer of matching double quotes and unescape quotes.
			if [[ "${__value}" == \"*\" ]]; then
				__value="${__value:1:${#__value}-2}"
				__value="${__value//\\\"/\"}"
			fi
			DAYZ_CFG["${__key}"]="${__value}"
		elif [ -z "${__quiet}" ]; then
			printf "[ ${yellow}WARN${default} ] Ignoring unparsable config line: %s\n" "${__line}"
		fi
		done < "${CONFIG_FILE}"

	for __name in "${!DAYZ_CFG[@]}"; do
		__expanded="$(fn_cfg_expand "${DAYZ_CFG[${__name}]}")"
		printf -v "${__name}" '%s' "${__expanded}"
	done
	return 0
}

# ===========================================================================
# Run locking
#
# One manager-wide run lock (${HOME}/.dayz.runlock) serialises every mutating
# command (start/stop/update/workshop/backup/restore/...) so a once-a-minute
# monitor cannot race a human running `update`, and two cron jobs cannot
# download the same mods at the same time. The lock records the owning PID;
# a lock whose owner is gone is broken on sight instead of blocking forever.
# ===========================================================================

DAYZ_RUN_LOCK="${HOME}/.dayz.runlock"

# fn_run_lock_acquire
# Takes the run lock for this process. On failure prints who holds it and
# returns 1 - commands fail fast instead of queueing behind each other.
fn_run_lock_acquire(){
	local owner
	if mkdir "${DAYZ_RUN_LOCK}" 2>/dev/null; then
		echo "$$" > "${DAYZ_RUN_LOCK}/pid"
		return 0
	fi
	if fn_run_lock_break_if_stale && mkdir "${DAYZ_RUN_LOCK}" 2>/dev/null; then
		echo "$$" > "${DAYZ_RUN_LOCK}/pid"
		return 0
	fi
	owner="$(fn_run_lock_owner)"
	printf "[ ${red}FAIL${default} ] Another manager operation is running (pid %s).\n" "${owner:-unknown}"
	printf "\tWait for it to finish, or remove %s if that process is gone.\n" "${DAYZ_RUN_LOCK}"
	return 1
}

# fn_run_lock_try
# Non-blocking acquire for callers that can skip instead of failing (monitor).
fn_run_lock_try(){
	if mkdir "${DAYZ_RUN_LOCK}" 2>/dev/null; then
		echo "$$" > "${DAYZ_RUN_LOCK}/pid"
		return 0
	fi
	fn_run_lock_break_if_stale || return 1
	mkdir "${DAYZ_RUN_LOCK}" 2>/dev/null || return 1
	echo "$$" > "${DAYZ_RUN_LOCK}/pid"
	return 0
}

# fn_run_lock_release
# Releases the lock only if this process owns it.
fn_run_lock_release(){
	local owner
	owner="$(fn_run_lock_owner)"
	if [ "${owner}" = "$$" ]; then
		rm -rf "${DAYZ_RUN_LOCK}"
	fi
}

fn_run_lock_owner(){
	[ -f "${DAYZ_RUN_LOCK}/pid" ] || return 1
	cat "${DAYZ_RUN_LOCK}/pid" 2>/dev/null
}

# fn_run_lock_break_if_stale
# Removes a lock whose owning process no longer exists (SIGKILL, reboot) or
# which is only half-created. Returns 0 when the lock is now free to take,
# 1 when it is legitimately held by a live process.
fn_run_lock_break_if_stale(){
	local owner
	owner="$(fn_run_lock_owner)" || {
		rm -rf "${DAYZ_RUN_LOCK}"
		return 0
	}
	if [ -z "${owner}" ] || ! kill -0 "${owner}" 2>/dev/null; then
		rm -rf "${DAYZ_RUN_LOCK}"
		return 0
	fi
	return 1
}

# fn_stale_update_lock_sweep
# ${HOME}/.dayzlockupdate means "an update is in flight, monitor stand down".
# Normally it is removed on completion; on SIGKILL or a reboot it survives,
# after which the monitor would skip forever. Anything older than 6 hours is
# presumed dead and swept.
fn_stale_update_lock_sweep(){
	local f="${HOME}/.dayzlockupdate" age
	[ -f "${f}" ] || return 0
	age=$(( $(date +%s) - $(stat -c %Y "${f}" 2>/dev/null || date +%s) ))
	if [ "${age}" -gt 21600 ]; then
		rm -f "${f}"
		printf "[ ${yellow}INFO${default} ] Removed a stale update lock (%sh old).\n" "$(( age / 3600 ))"
	fi
}

# ---------------------------------------------------------------------------
# Standalone: show what this module provides.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	printf '%s\n' \
		"lib/common.sh - shared helpers (colours, logging, prompts, config access)." \
		"This module is sourced by main.sh; run 'main.sh help' for commands."
fi
