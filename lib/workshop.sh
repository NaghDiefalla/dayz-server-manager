#!/usr/bin/env bash
#=======================================================================================#
# lib/workshop.sh - Steam Workshop mods: download, link, keys, config, updates
#
# Also runnable on its own: 'lib/workshop.sh sync' downloads and links the mods
# listed in ~/workshop.cfg (same as 'main.sh workshop').
#=======================================================================================#

if [ -z "${_DAYZ_COMMON_LOADED:-}" ]; then
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# ---------------------------------------------------------------------------
# fn_workshop_line_id <line>
# Extracts the published file id from a workshop.cfg line. Accepts a bare id
# or a pasted steamcommunity.com workshop URL.
# ---------------------------------------------------------------------------
fn_workshop_line_id(){
	printf '%s' "$1" | grep -oE '[0-9]{6,}' | head -n1
}

# ---------------------------------------------------------------------------
# fn_read_workshop_ids
# Prints the mod ids listed in workshop.cfg, one per line, skipping comments
# and unparsable lines. Bare ids and workshop URLs are both accepted.
# ---------------------------------------------------------------------------
fn_read_workshop_ids(){
	local workshop_cfg="${HOME}/workshop.cfg"
	local line mod_id
	[ -f "${workshop_cfg}" ] || return 0
	while IFS= read -r line || [ -n "${line}" ]; do
		line="$(fn_trim "${line}")"
		[ -z "${line}" ] && continue
		case "${line}" in \#*) continue ;; esac
		mod_id="$(fn_workshop_line_id "${line}")"
		[ -n "${mod_id}" ] && printf '%s\n' "${mod_id}"
	done < "${workshop_cfg}"
}

# ---------------------------------------------------------------------------
# fn_mod_link_name
# Maps a mod name to its @folder form: lowercase, spaces to underscores.
# ---------------------------------------------------------------------------
fn_mod_link_name(){
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_'
}

# ---------------------------------------------------------------------------
# fn_workshop_download_batch <log> <id> [<id> ...]
# One SteamCMD session downloading every listed item. Batching keeps the
# number of Steam logins at one per group instead of one per mod.
# ---------------------------------------------------------------------------
fn_workshop_download_batch(){
	local log="$1"; shift
	local -a args=()
	local id
	for id in "$@"; do
		args+=(+workshop_download_item "${dayz_id}" "${id}" validate)
	done
	: > "${log}"
	fn_steamcmd_run "${args[@]}" +quit 2>&1 | tee "${log}"
}

# ---------------------------------------------------------------------------
# fn_workshop_download_ok <log> <id> <workshopfolder>
# A mod counts as downloaded when its meta.cpp exists and the session log
# either confirms the item or at least reports no failure for it. Demanding
# the "Success" line alone rejected items SteamCMD skipped because they were
# already current; accepting meta.cpp alone would accept a failed update of
# an older copy, so the error markers still veto.
# ---------------------------------------------------------------------------
fn_workshop_download_ok(){
	local log="$1" id="$2" folder="$3"
	[ -f "${folder}/${id}/meta.cpp" ] || return 1
	grep -q "Success. Downloaded item ${id}" "${log}" && return 0
	! grep -qE "ERROR!.*${id}|Timeout downloading item ${id}" "${log}"
}

# ---------------------------------------------------------------------------
# fn_workshop_mods
# Downloads every mod in workshop.cfg and links it into serverfiles/@name.
#
# Mods are downloaded in batches of steamcmd_batch_size items per SteamCMD
# session and only failed items are retried, with exponential backoff plus
# jitter. A 20-mod sync therefore costs 3 logins instead of 20, and a flaky
# connection no longer restarts the whole list from scratch.
# ---------------------------------------------------------------------------
fn_workshop_mods(){
	local workshop_cfg="${HOME}/workshop.cfg"
	local workshopfolder="${HOME}/serverfiles/steamapps/workshop/content/${dayz_id}"
	local timestamp_file="${HOME}/mod_timestamps.json"
	local -a workshopID=()
	local updated_workshop_cfg=""
	local failed=0

	if [ ! -f "${workshop_cfg}" ]; then
		touch "${workshop_cfg}"
		chmod 600 "${workshop_cfg}"
	fi
	[ -f "${timestamp_file}" ] || echo "{}" > "${timestamp_file}"

	mapfile -t workshopID < "${workshop_cfg}"
	if [ "${#workshopID[@]}" -eq 0 ]; then
		printf "[ ${lightblue}INFO${default} ] No mods listed in workshop.cfg; nothing to download.\n"
		return 0
	fi

	printf "[ ${green}DayZ${default} ] Downloading Steam Workshop mods...\n"

	# Never start downloads that cannot finish on a full disk.
	fn_require_disk "${HOME}/serverfiles" "${min_free_mb:-2048}" "workshop downloads" || return 1

	# --- parse workshop.cfg, keeping comment lines verbatim ---------------
	local line mod_id name_from_cfg
	local -a pending=()
	local -A names_by_id=()

	for line in "${workshopID[@]}"; do
		line="$(fn_trim "${line}")"
		[ -z "${line}" ] && continue
		case "${line}" in \#*) updated_workshop_cfg+="${line}"$'\n'; continue ;; esac

		mod_id="$(fn_workshop_line_id "${line}")"
		if [ -z "${mod_id}" ]; then
			printf "[ ${yellow}WARN${default} ] Skipping unparsable workshop.cfg line: %s\n" "${line}"
			continue
		fi

		# "cut -f2-" returns the whole field when the line is just an id, so an
		# id-only line would otherwise look like it already carries a name.
		name_from_cfg="$(fn_trim "$(printf '%s' "${line}" | cut -d' ' -f2-)")"
		[ "${name_from_cfg}" = "${mod_id}" ] && name_from_cfg=""

		pending+=("${mod_id}")
		names_by_id["${mod_id}"]="${name_from_cfg}"
	done

	# --- download phase: batched sessions, retries for failures only ------
	local batch_size="${steamcmd_batch_size:-8}"
	local max_attempts="${workshop_retries:-5}"
	local attempt idx n backoff id steamcmd_log
	local -a remaining=( "${pending[@]}" ) batch failed_batch

	for (( attempt=1; attempt<=max_attempts && ${#remaining[@]} > 0; attempt++ )); do
		failed_batch=()
		for (( idx=0; idx < ${#remaining[@]}; idx+=batch_size )); do
			batch=( "${remaining[@]:idx:batch_size}" )
			steamcmd_log="$(mktemp -t dayz-steamcmd.XXXXXX.log 2>/dev/null)" || steamcmd_log="${HOME}/.steamcmd_last.log"
			n=$(( idx / batch_size + 1 ))
			fn_info "[ ${lightblue}INFO${default} ] Downloading %s mod(s) - attempt %s/%s, batch %s\n" \
				"${#batch[@]}" "${attempt}" "${max_attempts}" "${n}"

			fn_workshop_download_batch "${steamcmd_log}" "${batch[@]}"

			for id in "${batch[@]}"; do
				if fn_workshop_download_ok "${steamcmd_log}" "${id}" "${workshopfolder}"; then
					printf "[ ${green}OK${default} ] Mod ${cyan}%s${default} downloaded.\n" "${id}"
				else
					printf "[ ${yellow}WARN${default} ] Mod %s incomplete; queued for retry.\n" "${id}"
					failed_batch+=("${id}")
				fi
			done
			rm -f "${steamcmd_log}"
		done

		remaining=( "${failed_batch[@]}" )
		if [ "${#remaining[@]}" -gt 0 ] && [ "${attempt}" -lt "${max_attempts}" ]; then
			backoff=$(( (2 ** (attempt - 1)) * 5 + RANDOM % 5 ))
			[ "${backoff}" -gt 120 ] && backoff=120
			printf "[ ${yellow}WARN${default} ] %s mod(s) not ready; retrying in %ss.\n" "${#remaining[@]}" "${backoff}"
			sleep "${backoff}"
		fi
	done

	# --- post-processing: names, symlinks, timestamps, workshop.cfg -------
	local meta_file resolved_name link_name desired_link stale
	local mod_last_modified prev_timestamp
	for mod_id in "${pending[@]}"; do
		meta_file="${workshopfolder}/${mod_id}/meta.cpp"
		if [ ! -f "${meta_file}" ]; then
			printf "[ ${red}FAIL${default} ] Mod %s could not be downloaded after %s attempts.\n" \
				"${mod_id}" "${max_attempts}"
			failed=$(( failed + 1 ))
			# Keep the line exactly as it was: overwriting a good name with
			# "Unknown" would lose information the next run needs.
			updated_workshop_cfg+="${mod_id}${names_by_id[${mod_id}]:+ }${names_by_id[${mod_id}]}"$'\n'
			continue
		fi

		# Name priority: meta.cpp, then whatever workshop.cfg already had, then
		# the bare id. The grep is anchored to a real `name = "..."` field so it
		# cannot match `picture`, `logo` or a `name` substring elsewhere.
		resolved_name=""
		if [ -f "${meta_file}" ]; then
			resolved_name="$(grep -E '^[[:space:]]*name[[:space:]]*=' "${meta_file}" | head -n1 | cut -d '"' -f2)"
		fi
		[ -z "${resolved_name}" ] && resolved_name="${names_by_id[${mod_id}]}"
		if [ -z "${resolved_name}" ]; then
			resolved_name="${mod_id}"
			printf "[ ${yellow}WARN${default} ] No name found for mod %s; using its id.\n" "${mod_id}"
		fi

		link_name="$(fn_mod_link_name "${resolved_name}")"
		desired_link="${HOME}/serverfiles/@${link_name}"

		# Drop symlinks that point at this mod under a different name - left
		# behind when a mod author renames a mod, or by an earlier run that
		# could not read meta.cpp.
		for stale in "${HOME}/serverfiles/@"*; do
			[ -L "${stale}" ] || continue
			[ "$(readlink "${stale}")" = "${workshopfolder}/${mod_id}" ] || continue
			if [ "${stale}" != "${desired_link}" ]; then
				printf "[ ${lightblue}INFO${default} ] Removing stale symlink %s\n" "$(basename "${stale}")"
				rm -f "${stale}"
			fi
		done

		if [ ! -e "${desired_link}" ]; then
			ln -s "${workshopfolder}/${mod_id}" "${desired_link}"
			fn_info "[ ${green}OK${default} ] Linked ${cyan}@%s${default}\n" "${link_name}"
		fi

		# Update detection, and a Discord ping when a mod actually changed.
		if [ -f "${meta_file}" ]; then
			mod_last_modified="$(date -r "${meta_file}" +%s 2>/dev/null || echo 0)"
			prev_timestamp="$(jq -r --arg mod "${mod_id}" '.[$mod] // 0' "${timestamp_file}" 2>/dev/null || echo 0)"

			# prev_timestamp of 0 means we have never seen this mod, so this is
			# a first install rather than an update - staying quiet here avoids
			# one webhook per mod on a fresh server.
			if [ "${mod_last_modified}" -gt "${prev_timestamp}" ] && [ "${prev_timestamp}" -gt 0 ]; then
				fn_discord_notify "Mod '${resolved_name}' (ID: ${mod_id}) has been updated."
			fi

			jq --arg mod "${mod_id}" --argjson time "${mod_last_modified}" '.[$mod] = $time' \
				"${timestamp_file}" > "${timestamp_file}.tmp" && mv "${timestamp_file}.tmp" "${timestamp_file}"
		fi

		updated_workshop_cfg+="${mod_id} ${resolved_name}"$'\n'
	done

	# Write resolved names back so the next run has them as a fallback.
	if [ -n "${updated_workshop_cfg}" ]; then
		printf '%s' "${updated_workshop_cfg}" > "${workshop_cfg}"
		printf "[ ${green}OK${default} ] workshop.cfg updated with mod names.\n"
	fi

	fn_copy_mod_keys

	if [ "${failed}" -gt 0 ]; then
		printf "[ ${red}FAIL${default} ] %s mod(s) failed to download. The server may reject clients.\n" "${failed}"
		return 1
	fi
	# Record what we now hold so `checkmods` compares against reality rather
	# than reporting the same updates again on its next run. --force because
	# our copies are known-fresh right after a download.
	local -a refreshed_ids=()
	mapfile -t refreshed_ids < <(fn_read_workshop_ids)
	[ "${#refreshed_ids[@]}" -gt 0 ] && fn_refresh_remote_timestamps --force "${refreshed_ids[@]}" || true
	rm -f "${HOME}/update_pending"

	printf "[ ${green}OK${default} ] All workshop mods are ready.\n"
	return 0
}

# ---------------------------------------------------------------------------
# fn_copy_mod_keys
# Copies every *.bikey found in the mods into the server keys folder so
# clients can verify signatures.
# ---------------------------------------------------------------------------
fn_copy_mod_keys(){
	local moddir keydir
	mkdir -p "${HOME}/serverfiles/keys"
	printf "[ ${green}DayZ${default} ] Copying mod keys into the server keys folder...\n"

	# Mods are symlinks into the workshop content directory, and find does not
	# follow symlinks unless asked (-L). Walking the @ links explicitly also
	# keeps us from recursing into serverfiles/keys itself.
	for moddir in "${HOME}/serverfiles/@"*; do
		[ -e "${moddir}" ] || continue
		while IFS= read -r keydir; do
			[ -d "${keydir}" ] || continue
			find -L "${keydir}" -maxdepth 1 -type f -iname '*.bikey' \
				-exec cp -u {} "${HOME}/serverfiles/keys/" \; 2>/dev/null
		done < <(find -L "${moddir}/" -maxdepth 2 -type d \( -iname 'keys' -o -iname 'key' \) 2>/dev/null)
	done
}

# ---------------------------------------------------------------------------
# fn_check_mods
# Compares the mods we hold with the workshop and flags an update_pending
# marker when anything is newer upstream. The Steam side of this is served
# from the API cache whenever possible (see lib/steam.sh), so a tight cron
# schedule does not turn into API spam.
# ---------------------------------------------------------------------------
fn_check_mods(){
	local remote_ts="${HOME}/mod_remote_timestamps.json"
	local flag_file="${HOME}/update_pending"
	local -a mod_ids=()
	mapfile -t mod_ids < <(fn_read_workshop_ids)

	if [ "${#mod_ids[@]}" -eq 0 ]; then
		printf "[ ${lightblue}INFO${default} ] No mods configured; nothing to check.\n"
		return 0
	fi

	[ -f "${remote_ts}" ] || echo "{}" > "${remote_ts}"

	local details
	details="$(fn_steam_workshop_details "${mod_ids[@]}")" || {
		printf "[ ${yellow}WARN${default} ] Steam API unreachable; skipping check.\n"
		return 1
	}

	local -a updated_mods=()
	local pid tupdated stored
	while IFS=$'\t' read -r pid tupdated; do
		[ -z "${pid}" ] && continue
		stored="$(jq -r --arg p "${pid}" '.[$p] // 0' "${remote_ts}")"
		# A baseline of 0 means this mod has never been recorded. Treat that as
		# "needs downloading" so a newly added mod is picked up rather than
		# silently ignored until it happens to be updated upstream.
		if [ "${tupdated}" -gt "${stored}" ]; then
			updated_mods+=("${pid}")
		fi
	done <<< "${details}"

	if [ "${#updated_mods[@]}" -eq 0 ]; then
		printf "[ ${green}OK${default} ] All mods are up to date.\n"
		rm -f "${flag_file}"
		return 0
	fi

	date > "${flag_file}"
	printf "[ ${yellow}DayZ${default} ] %s mod update(s) available; flagged for the next start.\n" "${#updated_mods[@]}"
	local m
	for m in "${updated_mods[@]}"; do
		printf "  - %s\n" "${m}"
	done
	fn_discord_notify "DayZ mod updates available: $(printf '%s, ' "${updated_mods[@]}" | sed 's/, $//'). They will be applied on the next restart."
	return 0
}

# ---------------------------------------------------------------------------
# fn_update_workshop_line
# Rebuilds the workshop= launch line in config.ini from the installed mods.
# ---------------------------------------------------------------------------
fn_update_workshop_line(){
	local workshopfolder="${HOME}/serverfiles/steamapps/workshop/content/${dayz_id}"
	local -a parts=() skipped=()
	local line mod_id name link_name

	if [ ! -f "${CONFIG_FILE}" ]; then
		printf "[ ${red}FAIL${default} ] %s not found.\n" "${CONFIG_FILE}"
		return 1
	fi

	while IFS= read -r line || [ -n "${line}" ]; do
		line="$(fn_trim "${line}")"
		[ -z "${line}" ] && continue
		case "${line}" in \#*) continue ;; esac

		mod_id="$(fn_workshop_line_id "${line}")"
		[ -n "${mod_id}" ] || continue
		name="$(fn_trim "$(printf '%s' "${line}" | cut -d' ' -f2-)")"
		[ "${name}" = "${mod_id}" ] && name=""

		if [ -z "${name}" ]; then
			skipped+=("${mod_id} (no resolved name - run 'workshop' first)")
			continue
		fi

		link_name="$(fn_mod_link_name "${name}")"
		if [ ! -e "${HOME}/serverfiles/@${link_name}" ]; then
			skipped+=("${mod_id} (@${link_name} is not installed)")
			continue
		fi
		parts+=("@${link_name}")
	done < "${HOME}/workshop.cfg"

	local mod_line
	mod_line="$(IFS=';'; printf '%s' "${parts[*]}")"

	# Replace any existing workshop= line, commented out or not, and append one
	# if the config has none.
	local tmp="${CONFIG_FILE}.tmp"
	if grep -qE '^[[:space:]]*#?[[:space:]]*workshop=' "${CONFIG_FILE}"; then
		awk -v repl="workshop=\"${mod_line}\"" '
			/^[[:space:]]*#?[[:space:]]*workshop=/ && !done { print repl; done=1; next }
			{ print }' "${CONFIG_FILE}" > "${tmp}" && mv "${tmp}" "${CONFIG_FILE}"
	else
		printf 'workshop="%s"\n' "${mod_line}" >> "${CONFIG_FILE}"
	fi
	chmod 600 "${CONFIG_FILE}"

	if [ "${#parts[@]}" -eq 0 ]; then
		printf "[ ${yellow}WARN${default} ] No installed mods found; workshop= set to empty.\n"
	else
		printf "[ ${green}OK${default} ] workshop= set to ${cyan}%s${default}\n" "${mod_line}"
	fi
	local sk
	for sk in "${skipped[@]}"; do
		printf "[ ${yellow}SKIP${default} ] %s\n" "${sk}"
	done
	return 0
}

# ---------------------------------------------------------------------------
# fn_mods_dayz
# Manages workshop.cfg: add, remove, list.
# ---------------------------------------------------------------------------
fn_mods_dayz(){
	local action="${1:-list}"
	shift || true
	local workshop_cfg="${HOME}/workshop.cfg"
	touch "${workshop_cfg}"

	case "${action}" in
		add)
			[ "$#" -gt 0 ] || { printf "[ ${red}FAIL${default} ] Usage: %s mods add <id|url> [...]\n" "$0"; return 1; }
			local arg mod_id added=0 existing_ids mod_name
			for arg in "$@"; do
				# Accept a bare id or any pasted workshop URL.
				mod_id="$(fn_workshop_line_id "${arg}")"
				if [ -z "${mod_id}" ]; then
					printf "[ ${yellow}SKIP${default} ] Could not find a mod id in '%s'\n" "${arg}"
					continue
				fi
				# Capture the id list first: piping it into `grep -q` lets grep
				# exit on the first match and SIGPIPE the producer, and pipefail
				# then reports the whole pipeline as failed.
				existing_ids="$(fn_read_workshop_ids)"
				if printf '%s\n' "${existing_ids}" | grep -qx "${mod_id}"; then
					printf "[ ${lightblue}INFO${default} ] Mod %s is already listed.\n" "${mod_id}"
					continue
				fi
				# Resolve the name right away from the cached Steam API so
				# 'updateconfig' can see @folder names before the first download.
				mod_name="$(fn_steam_workshop_name "${mod_id}")"
				if [ -z "${mod_name}" ]; then
					fn_steam_workshop_details "${mod_id}" > /dev/null 2>&1 || true
					mod_name="$(fn_steam_workshop_name "${mod_id}")"
				fi
				if [ -n "${mod_name}" ]; then
					printf '%s %s\n' "${mod_id}" "${mod_name}" >> "${workshop_cfg}"
					printf "[ ${green}OK${default} ] Added mod %s (${cyan}%s${default})\n" "${mod_id}" "${mod_name}"
				else
					printf '%s\n' "${mod_id}" >> "${workshop_cfg}"
					printf "[ ${green}OK${default} ] Added mod %s (name unknown; resolved on first download)\n" "${mod_id}"
				fi
				added=$(( added + 1 ))
			done
			if [ "${added}" -gt 0 ]; then
				printf "[ ${lightblue}TIP${default} ] Run '%s workshop' to download, then '%s updateconfig'.\n" "$0" "$0"
			fi
			;;
		remove|rm)
			[ "$#" -gt 0 ] || { printf "[ ${red}FAIL${default} ] Usage: %s mods remove <id> [...]\n" "$0"; return 1; }
			local tmp="${workshop_cfg}.tmp" arg2 mod_id2 rline
			for arg2 in "$@"; do
				mod_id2="$(fn_workshop_line_id "${arg2}")"
				[ -n "${mod_id2}" ] || continue
				# Compare extracted ids so URL lines match like bare ids do;
				# comments are always kept.
				while IFS= read -r rline || [ -n "${rline}" ]; do
					case "$(fn_trim "${rline}")" in
						\#*) printf '%s\n' "${rline}" ;;
						*) [ "$(fn_workshop_line_id "${rline}")" = "${mod_id2}" ] || printf '%s\n' "${rline}" ;;
					esac
				done < "${workshop_cfg}" > "${tmp}" && mv "${tmp}" "${workshop_cfg}"
				printf "[ ${green}OK${default} ] Removed mod %s from workshop.cfg\n" "${mod_id2}"
			done
			printf "[ ${lightblue}TIP${default} ] Run '%s updateconfig' so the launch line matches.\n" "$0"
			printf "[ ${lightblue}NOTE${default} ] The downloaded files and the @symlink are left in place.\n"
			;;
		list|ls)
			local line count=0
			printf "\n${lightyellow}Configured mods${default}\n"
			while IFS= read -r line || [ -n "${line}" ]; do
				line="$(fn_trim "${line}")"
				[ -z "${line}" ] && continue
				case "${line}" in \#*) continue ;; esac
				printf "  %s\n" "${line}"
				count=$(( count + 1 ))
			done < "${workshop_cfg}"
			[ "${count}" -eq 0 ] && printf "  (none)\n"
			printf "\n"
			;;
		export)
			# mods export [file] - prints or writes the mod list in a form
			# 'mods import' (or another server) can consume directly.
			local export_file="${1:-}" eline
			if [ -z "${export_file}" ]; then
				while IFS= read -r eline || [ -n "${eline}" ]; do
					eline="$(fn_trim "${eline}")"
					[ -z "${eline}" ] && continue
					case "${eline}" in \#*) continue ;; esac
					printf '%s\n' "${eline}"
				done < "${workshop_cfg}"
				return 0
			fi
			: > "${export_file}"
			while IFS= read -r eline || [ -n "${eline}" ]; do
				eline="$(fn_trim "${eline}")"
				[ -z "${eline}" ] && continue
				case "${eline}" in \#*) continue ;; esac
				printf '%s\n' "${eline}" >> "${export_file}"
			done < "${workshop_cfg}"
			printf "[ ${green}OK${default} ] Exported mod list to %s\n" "${export_file}"
			;;
		import)
			# mods import <file> - merges ids from an exported list, skipping
			# anything already configured.
			[ "$#" -gt 0 ] || { printf "[ ${red}FAIL${default} ] Usage: %s mods import <file>\n" "$0"; return 1; }
			local import_file="$1" iline iid iname existing_ids imported=0
			if [ ! -f "${import_file}" ]; then
				printf "[ ${red}FAIL${default} ] Import file not found: %s\n" "${import_file}"
				return 1
			fi
			existing_ids="$(fn_read_workshop_ids)"
			while IFS= read -r iline || [ -n "${iline}" ]; do
				iline="$(fn_trim "${iline}")"
				[ -z "${iline}" ] && continue
				case "${iline}" in \#*) continue ;; esac
				iid="$(fn_workshop_line_id "${iline}")"
				[ -n "${iid}" ] || continue
				if printf '%s\n' "${existing_ids}" | grep -qx "${iid}"; then
					continue
				fi
				iname="$(fn_trim "$(printf '%s' "${iline}" | cut -d' ' -f2-)")"
				[ "${iname}" = "${iid}" ] && iname=""
				printf '%s%s\n' "${iid}" "${iname:+ }${iname}" >> "${workshop_cfg}"
				existing_ids+="${iid}"$'\n'
				printf "[ ${green}OK${default} ] Imported mod %s\n" "${iid}"
				imported=$(( imported + 1 ))
			done < "${import_file}"
			if [ "${imported}" -gt 0 ]; then
				printf "[ ${lightblue}TIP${default} ] Run '%s workshop' to download, then '%s updateconfig'.\n" "$0" "$0"
			else
				printf "[ ${lightblue}INFO${default} ] Nothing new to import.\n"
			fi
			;;
		*)
			printf "[ ${red}FAIL${default} ] Usage: %s mods {add|remove|list|export|import} [id|url|file]\n" "$0"
			return 1
			;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Standalone: explicit subcommands only, so a bare run never mutates anything.
#   lib/workshop.sh sync|check|updateconfig|mods <add|remove|list> ...
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/steam.sh"
	fn_apply_defaults
	case "${1:-}" in
		sync|workshop)   fn_workshop_mods ;;
		check|checkmods) fn_check_mods ;;
		updateconfig)    fn_update_workshop_line ;;
		mods)            shift; fn_mods_dayz "$@" ;;
		*) printf '%s\n' \
			"lib/workshop.sh - Steam Workshop mods: download, link, keys, updates." \
			"Usage: lib/workshop.sh {sync|check|updateconfig|mods <add|remove|list|export|import>}" ;;
	esac
fi
