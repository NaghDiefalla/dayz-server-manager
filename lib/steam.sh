#!/usr/bin/env bash
#=======================================================================================#
# lib/steam.sh - SteamCMD and Steam Web API access
#
# Everything that talks to Steam lives here. Two rules apply throughout:
#
#   * Never spam Steam. SteamCMD sessions are rate-limited to one login per
#     steamcmd_cooldown seconds, Web API queries are cached for
#     steam_api_cache_ttl seconds, remote build checks for
#     steam_update_check_interval seconds, and retries use exponential
#     backoff instead of tight loops.
#   * Degrade to cache. When Steam is unreachable the most recent known
#     answer is served instead of failing the whole run.
#
# Also runnable on its own: 'lib/steam.sh install|update|validate|cleancache'.
#=======================================================================================#

if [ -z "${_DAYZ_COMMON_LOADED:-}" ]; then
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# ---------------------------------------------------------------------------
# fn_steamcmd_run
# The single entry point for SteamCMD: adds the install dir and login, and
# keeps a minimum gap between sessions so back-to-back calls from scripts and
# cron jobs cannot hammer Steam's login servers.
# ---------------------------------------------------------------------------
fn_steamcmd_run(){
	local stamp="${HOME}/.steamcmd_last_run"
	local gap="${steamcmd_cooldown:-5}"
	local now last wait_s
	now="$(date +%s)"
	if [ -f "${stamp}" ]; then
		last="$(cat "${stamp}" 2>/dev/null)"
		[[ "${last}" =~ ^[0-9]+$ ]] || last=0
		wait_s=$(( gap - (now - last) ))
		if [ "${wait_s}" -gt 0 ]; then
			sleep "${wait_s}"
		fi
	fi
	date +%s > "${stamp}"
	"${HOME}/steamcmd/steamcmd.sh" +force_install_dir "${HOME}/serverfiles" \
		+login "${steamlogin}" "$@"
}

# ---------------------------------------------------------------------------
# fn_runupdate_dayz / fn_runvalidate_dayz
# Thin wrappers so call sites read as intent.
# ---------------------------------------------------------------------------
fn_runupdate_dayz(){
	fn_steamcmd_run +app_update "${appid}" +quit
}

fn_runvalidate_dayz(){
	fn_steamcmd_run +app_update "${appid}" validate +quit
}

# ---------------------------------------------------------------------------
# fn_validate_dayz
# Validates the server files. With the server running this is a
# stop-validate-workshop-start cycle; when it is stopped the validation runs
# directly.
# ---------------------------------------------------------------------------
fn_validate_dayz(){
	# The old version read ${dayzstatus} without refreshing it first, so on a
	# direct `validate` the variable was unset and it took the "server running"
	# branch against a stopped server.
	fn_status_dayz
	if [ "${dayzstatus}" == "0" ]; then
		fn_runvalidate_dayz
		return $?
	fi

	date > "${HOME}/.dayzlockupdate"
	DAYZ_UPDATE_LOCK_HELD=1
	fn_stop_dayz
	fn_runvalidate_dayz
	fn_workshop_mods
	rm -f "${HOME}/.dayzlockupdate"
	DAYZ_UPDATE_LOCK_HELD=0
	fn_start_dayz
}

# ===========================================================================
# Steam Web API client (ISteamRemoteStorage/GetPublishedFileDetails)
#
# Cache file ~/.steam_api_cache.json:
#   {"<id>": {"t": <time_updated>, "f": <fetched_at epoch>}}
#
# Entries younger than steam_api_cache_ttl are served from cache; only stale
# ids are sent to Steam. Queries are single-flight (one process at a time)
# and retried with exponential backoff, honouring HTTP 429 Retry-After.
# ===========================================================================

DAYZ_STEAM_API_URL="https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
DAYZ_STEAM_API_BATCH=100

fn_steam_api_cache_init(){
	local cache="${HOME}/.steam_api_cache.json"
	[ -f "${cache}" ] || echo "{}" > "${cache}"
}

# ---------------------------------------------------------------------------
# fn_steam_api_cache_update <now>
# Merges "id<TAB>time_updated<TAB>title" lines on stdin into the cache.
# The title is kept so mod names can be resolved without a download.
# ---------------------------------------------------------------------------
fn_steam_api_cache_update(){
	local now="$1" updates
	updates="$(jq -Rn --argjson now "${now}" \
		'[inputs | select(length > 0) | split("\t")
		  | {key: .[0], value: {t: (.[1] | tonumber), n: (.[2] // ""), f: $now}}]
		 | from_entries')"
	[ -n "${updates}" ] && [ "${updates}" != "null" ] || return 0
	jq --argjson updates "${updates}" '. * $updates' "${HOME}/.steam_api_cache.json" \
		> "${HOME}/.steam_api_cache.json.tmp" \
		&& mv "${HOME}/.steam_api_cache.json.tmp" "${HOME}/.steam_api_cache.json"
}

# ---------------------------------------------------------------------------
# fn_steam_api_lock / fn_steam_api_unlock
# Single-flight guard: concurrent monitor/checkmods runs must not fire
# parallel API queries. Locks older than 120s are presumed crashed and broken.
# ---------------------------------------------------------------------------
fn_steam_api_lock(){
	local lock="${HOME}/.steam_api.lock"
	local tries=0 age
	while ! mkdir "${lock}" 2>/dev/null; do
		age=$(( $(date +%s) - $(stat -c %Y "${lock}" 2>/dev/null || date +%s) ))
		if [ "${age}" -gt 120 ]; then
			rmdir "${lock}" 2>/dev/null
			continue
		fi
		tries=$(( tries + 1 ))
		[ "${tries}" -ge 30 ] && return 1
		sleep 2
	done
	return 0
}

fn_steam_api_unlock(){
	rmdir "${HOME}/.steam_api.lock" 2>/dev/null
}

# ---------------------------------------------------------------------------
# fn_steam_api_fetch <id> [<id> ...]
# Prints "id<TAB>time_updated<TAB>title" for every id Steam resolved. Retries
# 4xx/5xx that are worth waiting out with exponential backoff plus jitter,
# and honours Retry-After on 429. Returns 1 when no batch could be fetched.
# ---------------------------------------------------------------------------
fn_steam_api_fetch(){
	[ "$#" -gt 0 ] || return 0
	local -a ids=("$@") batch
	local i j id attempt max_attempts=4 backoff retry_after http_code ok=0
	local body headers
	body="$(mktemp -t dayz-steam-api-body.XXXXXX 2>/dev/null)" || return 1
	headers="$(mktemp -t dayz-steam-api-hdr.XXXXXX 2>/dev/null)" || { rm -f "${body}"; return 1; }

	for (( i=0; i < ${#ids[@]}; i+=DAYZ_STEAM_API_BATCH )); do
		batch=( "${ids[@]:i:DAYZ_STEAM_API_BATCH}" )
		ok=0
		for (( attempt=1; attempt<=max_attempts; attempt++ )); do
			local -a curl_args=(-sS --max-time 25 -X POST "${DAYZ_STEAM_API_URL}"
				-D "${headers}" -o "${body}" -w '%{http_code}'
				-d "itemcount=${#batch[@]}")
			j=0
			for id in "${batch[@]}"; do
				curl_args+=(-d "publishedfileids[${j}]=${id}")
				j=$(( j + 1 ))
			done

			http_code="$(curl "${curl_args[@]}" 2>/dev/null)" || http_code=000

			if [ "${http_code}" = "200" ] && [ -s "${body}" ]; then
				jq -r '.response.publishedfiledetails[]?
					| select(.result == 1)
					| "\(.publishedfileid)\t\(.time_updated // 0)\t\((.title // "") | gsub("[\\t\\n\\r]"; " "))"' \
					"${body}" 2>/dev/null
				ok=1
				break
			fi

			# 429 and 5xx are worth waiting out; anything else will not
			# improve by asking again.
			case "${http_code}" in
				429|5*) ;;
				*) break ;;
			esac
			[ "${attempt}" -ge "${max_attempts}" ] && break

			backoff=$(( (2 ** (attempt - 1)) * 5 + RANDOM % 5 ))
			retry_after="$(grep -i '^retry-after:' "${headers}" 2>/dev/null | tr -dc '0-9')"
			if [ -n "${retry_after}" ] && [ "${retry_after}" -lt 300 ]; then
				backoff="${retry_after}"
			fi
			printf "[ ${yellow}WARN${default} ] Steam API returned HTTP %s; retrying in %ss (%s/%s).\n" \
				"${http_code}" "${backoff}" "${attempt}" "${max_attempts}" >&2
			sleep "${backoff}"
		done
	done

	rm -f "${body}" "${headers}"
	[ "${ok}" = "1" ]
}

# ---------------------------------------------------------------------------
# fn_steam_workshop_details [--force] <id> [<id> ...]
# Prints "id<TAB>time_updated" for each requested id. Ids fetched within
# steam_api_cache_ttl are answered from cache; only the rest go to Steam.
# --force ignores the cache age (use right after downloads). Returns 1 only
# when no answer (cached or fresh) could be produced for a requested id.
# ---------------------------------------------------------------------------
fn_steam_workshop_details(){
	local force=0
	if [ "${1:-}" = "--force" ]; then force=1; shift; fi
	[ "$#" -gt 0 ] || return 0

	fn_steam_api_cache_init
	local cache="${HOME}/.steam_api_cache.json"
	local now ttl fetched stale_ids=() id
	now="$(date +%s)"
	ttl="${steam_api_cache_ttl:-900}"

	for id in "$@"; do
		if [ "${force}" = "0" ]; then
			fetched="$(jq -r --arg id "${id}" '.[$id].f // 0' "${cache}" 2>/dev/null)"
			if [[ "${fetched}" =~ ^[0-9]+$ ]] && [ "${fetched}" -gt 0 ] \
				&& [ $(( now - fetched )) -lt "${ttl}" ] \
				&& [ "$(jq -r --arg id "${id}" '.[$id].t // 0' "${cache}" 2>/dev/null)" -gt 0 ]; then
				continue
			fi
		fi
		stale_ids+=("${id}")
	done

	local fetch_ok=1
	if [ "${#stale_ids[@]}" -gt 0 ]; then
		if fn_steam_api_lock; then
			local fetched_lines
			if fetched_lines="$(fn_steam_api_fetch "${stale_ids[@]}")" && [ -n "${fetched_lines}" ]; then
				fn_steam_api_cache_update "${now}" <<< "${fetched_lines}"
				fetch_ok=0
			fi
			fn_steam_api_unlock
		fi
	fi

	# Print the best-known value for every requested id.
	local entry missing=0
	for id in "$@"; do
		entry="$(jq -r --arg id "${id}" '.[$id] // empty | "\($id)\t\(.t // 0)"' "${cache}" 2>/dev/null)"
		if [ -n "${entry}" ]; then
			printf '%s\n' "${entry}"
		else
			missing=$(( missing + 1 ))
		fi
	done
	[ "${missing}" -eq 0 ] || [ "${fetch_ok}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# fn_steam_workshop_name <id>
# Echoes the mod title cached from the Steam Web API (empty when unknown).
# Call fn_steam_workshop_details first to fill the cache for unknown ids.
# ---------------------------------------------------------------------------
fn_steam_workshop_name(){
	local id="$1"
	fn_steam_api_cache_init
	jq -r --arg id "${id}" '.[$id].n // empty' "${HOME}/.steam_api_cache.json" 2>/dev/null
}

# ---------------------------------------------------------------------------
# fn_refresh_remote_timestamps [--force] <id> [<id> ...]
# Records the current upstream time_updated for each id so `checkmods`
# compares against reality rather than reporting the same updates again on
# its next run. --force bypasses the API cache (used right after downloads,
# when we know our local copies are new).
# ---------------------------------------------------------------------------
fn_refresh_remote_timestamps(){
	local -a force_args=()
	if [ "${1:-}" = "--force" ]; then force_args+=(--force); shift; fi
	local remote_ts="${HOME}/mod_remote_timestamps.json"
	[ -f "${remote_ts}" ] || echo "{}" > "${remote_ts}"
	[ "$#" -gt 0 ] || return 0

	local details updates
	details="$(fn_steam_workshop_details "${force_args[@]}" "$@")" || {
		printf "[ ${yellow}WARN${default} ] Steam API unreachable; update baseline not refreshed.\n"
		return 1
	}
	[ -n "${details}" ] || return 1

	updates="$(printf '%s\n' "${details}" | jq -Rn '
		[inputs | select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber)}]
		| from_entries')"
	[ -n "${updates}" ] && [ "${updates}" != "null" ] || return 1

	jq --argjson updates "${updates}" '. * $updates' "${remote_ts}" > "${remote_ts}.tmp" \
		&& mv "${remote_ts}.tmp" "${remote_ts}"
}

# ===========================================================================
# Server install / update / validate
# ===========================================================================

# ---------------------------------------------------------------------------
# fn_install_dayz
# Installs SteamCMD and the DayZ server files on first run.
# ---------------------------------------------------------------------------
fn_install_dayz(){
	if [ ! -f "${HOME}/steamcmd/steamcmd.sh" ]; then
		mkdir ${HOME}/steamcmd &> /dev/null
		curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar zxf - -C steamcmd
		printf "[ ${yellow}STEAM${default} ] Steamcmd installed\n"
	else
		printf "[ ${lightblue}STEAM${default} ] Steamcmd already installed\n"
	fi
	if [ ! -f "${HOME}/serverfiles/DayZServer" ]; then
		mkdir ${HOME}/serverfiles &> /dev/null
		mkdir ${HOME}/serverprofile &> /dev/null
		printf "[ ${yellow}DayZ${default} ] Downloading DayZ Server-Files!\n"
		fn_runvalidate_dayz
		if [ ! -f "${HOME}/serverfiles/${config}" ]; then
			printf "\n[ ${lightblue}TIP${default} ] Run '${lightyellow}%s setup${default}' now to write %s and configure RCon.\n\n" \
				"$0" "${config}"
		fi
	else
		printf "[ ${lightblue}DayZ${default} ] The Server is already installed.\n"
		fn_opt_usage 0
	fi
}

# ---------------------------------------------------------------------------
# fn_update_dayz
# Compares the installed build with the published one and updates when they
# differ.
#
# The check result is cached for steam_update_check_interval seconds, so a
# monitor/cron loop cannot make SteamCMD re-fetch app metadata on every run.
# appinfo.vdf is only cleared as a recovery step after a failed check - the
# old unconditional delete forced a full metadata re-download every single
# check, which was slow and a needless load on Steam.
#
# Pass --force to bypass the check cache (e.g. a manual 'update' before a
# scheduled restart).
# ---------------------------------------------------------------------------
fn_update_dayz(){
	local appmanifestfile="${HOME}/serverfiles/steamapps/appmanifest_${appid}.acf"
	local check_cache="${HOME}/.build_check_cache"
	local currentbuild availablebuild cached_build cached_at now force=0

	[ "${1:-}" = "--force" ] && force=1

	printf "[ ... ] Checking for update: SteamCMD"

	if [ -f "${appmanifestfile}" ]; then
		currentbuild="$(grep buildid "${appmanifestfile}" | tr '[:blank:]"' ' ' | tr -s ' ' | cut -d ' ' -f3)"
	fi

	now="$(date +%s)"
	availablebuild=""
	if [ "${force}" = "0" ] && [ -f "${check_cache}" ]; then
		read -r cached_build cached_at < "${check_cache}" || true
		if [[ "${cached_at}" =~ ^[0-9]+$ ]] && [ $(( now - cached_at )) -lt "${steam_update_check_interval:-600}" ]; then
			availablebuild="${cached_build}"
			printf "\r[ ${green}OK${default} ] Checking for update: SteamCMD (cached %ss ago)\n" \
				"$(( now - cached_at ))"
		fi
	fi

	if [ -z "${availablebuild}" ]; then
		availablebuild="$(fn_steamcmd_run +app_info_update 1 +app_info_print "${appid}" +quit \
			| sed -n '/branch/,$p' | grep -m 1 buildid | tr -cd '[:digit:]')"

		if [ -z "${availablebuild}" ]; then
			# A wedged appinfo cache is the usual cause. Clear it and retry
			# once instead of making the user run `cleancache` first.
			rm -f "${HOME}/Steam/appcache/appinfo.vdf"
			sleep 2
			availablebuild="$(fn_steamcmd_run +app_info_update 1 +app_info_print "${appid}" +quit \
				| sed -n '/branch/,$p' | grep -m 1 buildid | tr -cd '[:digit:]')"
		fi

		if [ -z "${availablebuild}" ]; then
			printf "\r[ ${red}FAIL${default} ] Checking for update: SteamCMD returned no version info.\n"
			printf "[ ${lightblue}TIP${default} ] Try '%s cleancache' if this keeps happening.\n" "$0"
			return 1
		fi
		printf '\n%s %s\n' "${availablebuild}" "${now}" > "${check_cache}"
		printf "\r[ ${green}OK${default} ] Checking for update: SteamCMD\n"
	fi

	if [ "${currentbuild}" = "${availablebuild}" ]; then
		printf "[ ${green}OK${default} ] No update available (build ${green}%s${default}).\n" "${currentbuild}"
		return 0
	fi

	printf "[ ${green}OK${default} ] Update available.\n"
	printf "\tCurrent build:   ${red}%s${default}\n" "${currentbuild:-unknown}"
	printf "\tAvailable build: ${green}%s${default}\n" "${availablebuild}"
	printf "\thttps://steamdb.info/app/%s/\n\n" "${appid}"

	# Never start an update that cannot finish: a download dying on a full
	# disk leaves a broken install.
	fn_require_disk "${HOME}/serverfiles" "${min_free_mb:-2048}" "the server update" || return 1

	# The lockfile stops the monitor restarting the server mid-update.
	date > "${HOME}/.dayzlockupdate"
	DAYZ_UPDATE_LOCK_HELD=1
	fn_log_monitor "Server update ${currentbuild:-unknown} -> ${availablebuild} starting."

	fn_status_dayz
	local was_running=0
	if [ "${dayzstatus}" != "0" ]; then
		was_running=1
		fn_stop_dayz
	fi

	fn_runupdate_dayz
	fn_workshop_mods
	rm -f "${HOME}/.dayzlockupdate"
	DAYZ_UPDATE_LOCK_HELD=0
	fn_log_monitor "Server updated to build ${availablebuild}."
	fn_discord_notify "DayZ server updated to build ${availablebuild}."

	if [ "${was_running}" = "1" ]; then
		fn_start_dayz
	fi
	return 0
}

# ---------------------------------------------------------------------------
# fn_clean_dayz
# Clears SteamCMD and workshop download caches. This is the only place
# appinfo.vdf is removed proactively - it exists precisely for the rare case
# where SteamCMD's cached metadata has gone stale.
# ---------------------------------------------------------------------------
fn_clean_dayz(){
	printf "[ ${magenta}...${default} ] Clearing SteamCMD caches (login is preserved)...\n"
	rm -f "${HOME}/Steam/appcache/appinfo.vdf" "${HOME}/Steam/appcache/packageinfo.vdf"
	rm -rf "${HOME}/serverfiles/steamapps/downloading"
	rm -rf "${HOME}/serverfiles/steamapps/workshop/downloads"
	rm -rf "${HOME}/serverfiles/steamapps/workshop/temp"
	rm -f "${HOME}/serverfiles/steamapps/workshop/appworkshop_${dayz_id}.acf"
	rm -f "${HOME}/.build_check_cache" "${HOME}/.steam_api_cache.json"
	printf "[ ${green}OK${default} ] Caches cleared. Steam login preserved.\n"
	return 0
}

# ---------------------------------------------------------------------------
# Standalone: explicit subcommands only, so a bare run never mutates anything.
#   lib/steam.sh install|update|validate|cleancache
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
	fn_apply_defaults
	case "${1:-}" in
		install)    fn_install_dayz ;;
		update)     shift; fn_update_dayz "$@" ;;
		validate)   fn_validate_dayz ;;
		cleancache) fn_clean_dayz ;;
		*) printf '%s\n' \
			"lib/steam.sh - SteamCMD and Steam Web API (cached, rate-limited)." \
			"Usage: lib/steam.sh {install|update|validate|cleancache}" ;;
	esac
fi
