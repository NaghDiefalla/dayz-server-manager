#!/usr/bin/env bash
#=======================================================================================#
# lib/config.sh - config.ini creation, loading, defaults and interactive setup
#
# Also runnable on its own: 'lib/config.sh setup' runs the interactive setup.
#=======================================================================================#

if [ -z "${_DAYZ_COMMON_LOADED:-}" ]; then
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# Default content of the config.ini file
# Default content of the config.ini file. Kept literal (quoted heredoc) so the
# file is written exactly as it reads - values are parsed as data at load time
# (fn_cfg_load), never executed as shell.
DEFAULT_CONFIG="$(cat <<'EOF'
# DayZ SteamID
appid=223350
dayz_id=221100
#stable=223350
#exp_branch=1042420

# Game Port (Not Steam QueryPort. Add/Change that in your serverDZ.cfg file)
port=2302

# Limit the server frame rate. Lower values reduce CPU load.
limitFPS=60

# How many times to retry a single Steam Workshop mod download before giving
# up. Large mods (the DayZ-Expansion-Bundle in particular) regularly time out
# on the first attempt.
workshop_retries=5

# How many days of backups to keep before they are deleted.
backup_retention_days=2

# How many backup archives of each kind (mission, serverprofile) to keep at
# most, regardless of age.
backup_retention_count=10

# How many crash-log directories to keep at most.
crash_retention_count=10

# Check for and apply DayZ server updates every time the server starts.
# Set to 0 if you would rather update only via the 'update' command or cron.
auto_update_on_start=1

# --- Steam rate limiting -------------------------------------------------
# Minimum seconds between Steam Web API queries (mod update checks). Cached
# answers within this window are served without touching Steam.
steam_api_cache_ttl=900

# Minimum seconds between remote server-build checks with SteamCMD. Stops a
# frequent monitor/cron loop from re-fetching Steam app metadata constantly.
steam_update_check_interval=600

# Minimum seconds between two SteamCMD sessions (each is a full login).
steamcmd_cooldown=5

# How many mods to download per SteamCMD session. One session per batch
# instead of one login per mod keeps the login servers happy.
steamcmd_batch_size=8

# --- Pre-flight checks ---------------------------------------------------
# Refuse updates and mod downloads when free disk space is below this many
# megabytes. Backups only warn. A download that starts on a full disk fails
# halfway and leaves a broken install.
min_free_mb=2048

# --- Logging -------------------------------------------------------------
# Verbosity of console output: normal, quiet (warnings and errors only) or
# verbose (adds debug detail). Useful for cron/systemd runs.
log_level=normal

# Rotate a log file when it exceeds this size (kB), keeping log_keep
# previous generations.
log_max_kb=1024
log_keep=3

# Web GUI. Bind to 127.0.0.1 to keep it reachable only from this machine
# (recommended - use an SSH tunnel or a reverse proxy with HTTPS to reach it
# remotely). Set to 0.0.0.0 to expose it on the network.
web_bind=127.0.0.1
web_port=8080

# Access token for the web GUI. REQUIRED whenever web_bind is not
# 127.0.0.1 - the GUI refuses to start without one on a reachable bind.
# Leave empty for tokenless access on localhost only.
web_token=

# IMPORTANT PARAMETERS
steamlogin=CHANGEME
config=serverDZ.cfg
BEpath="-BEpath=${HOME}/serverfiles/battleye/"
profiles="-profiles=${HOME}/serverprofile/"
# optional - just remove the # to enable
#logs="-dologs -adminlog -netlog"

# Discord Notifications.
discord_webhook_url=""

# DayZ Mods from Steam Workshop
# Edit the workshop.cfg and add one Mod Number per line.
# To enable mods, remove the # below and list the Mods like this: "@mod1;@mod2;@spaces work". Lowercase only.
#workshop=""
# To enable serverside mods, remove the # below and list the Mods like this: "@servermod1;@server mod2". Lowercase only.
#servermods=""

# modify carefully! server won't start if syntax is corrupt!
dayzparameter=" -config=${config} -port=${port} -limitFPS=${limitFPS} -freezecheck ${BEpath} ${profiles} ${logs}"
EOF
)"

# ---------------------------------------------------------------------------
# fn_ensure_config
# Writes the default config.ini when none exists. Returns 2 in that case, so
# the caller can tell "created, run setup" apart from a real load failure.
# ---------------------------------------------------------------------------
fn_ensure_config(){
	if [ ! -f "${CONFIG_FILE}" ]; then
		printf "[ ${yellow}Warning${default} ] ${CONFIG_FILE} file not found.\n"
		printf '%s\n' "${DEFAULT_CONFIG}" > "${CONFIG_FILE}"
		printf "[ ${green}Fixed${default} ] Default ${lightyellow}${CONFIG_FILE}${default} created.\n"
		printf "[ ${lightblue}TIP${default} ] Run '${lightyellow}$0 setup${default}' to fill it in interactively.\n"
		chmod 600 "${CONFIG_FILE}"
		return 2
	fi
	return 0
}

# ---------------------------------------------------------------------------
# fn_load_config
# Sources config.ini and refuses to continue while steamlogin is a
# placeholder. Returns 1 on failure; prints the same guidance as before.
# ---------------------------------------------------------------------------
fn_load_config(){
	printf "[ ${green}Success${default} ] Config file found. Reading values...\n"
	# Parsed as data, never executed as shell - see fn_cfg_load in lib/common.sh.
	fn_cfg_load || return 1
	printf "[ ${green}Finished${default} ] Configuration file loaded.\n"
	chmod 600 "${CONFIG_FILE}"

	# The Steam account may come from the environment instead of the file, so
	# config.ini can stay free of account names. The environment wins.
	if [ -n "${STEAMLOGIN:-}" ]; then
		steamlogin="${STEAMLOGIN}"
	fi

	# Check if steamlogin is set to CHANGEME
	if [ "${steamlogin:-}" = "CHANGEME" ]; then
		printf "[ ${red}Error${default} ] The ${lightyellow}steamlogin${default} value in ${CONFIG_FILE} is still '${lightyellow}CHANGEME${default}'.\n"
		printf "[ ${red}Error${default} ] Set it to your Steam username, or run '${lightyellow}$0 setup${default}'.\n"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# fn_apply_defaults
# Fall back to sane values for settings added after a user wrote their
# config.ini. Upgrading the script must never require rewriting the config, so
# every option introduced in a later version gets its default here.
# ---------------------------------------------------------------------------
fn_apply_defaults(){
	: "${appid:=223350}"
	: "${dayz_id:=221100}"
	: "${port:=2301}"
	: "${limitFPS:=60}"
	: "${workshop_retries:=5}"
	: "${backup_retention_days:=2}"
	: "${backup_retention_count:=10}"
	: "${crash_retention_count:=10}"
	: "${min_free_mb:=2048}"
	: "${log_level:=normal}"
	: "${log_max_kb:=1024}"
	: "${log_keep:=3}"
	: "${auto_update_on_start:=1}"
	: "${steam_api_cache_ttl:=900}"
	: "${steam_update_check_interval:=600}"
	: "${steamcmd_cooldown:=5}"
	: "${steamcmd_batch_size:=8}"
	: "${web_bind:=127.0.0.1}"
	: "${web_port:=8080}"
	: "${web_token:=}"
	: "${discord_webhook_url:=}"
	: "${workshop:=}"
	: "${servermods:=}"
	: "${config:=serverDZ.cfg}"

	fn_cfg_validate
}

# ---------------------------------------------------------------------------
# fn_cfg_validate
# Sanity-checks the knobs after loading. A hand-edited config with port=abc
# or steamcmd_batch_size=-1 must not explode later inside arithmetic, so
# invalid values are reported once and reset to their defaults.
# ---------------------------------------------------------------------------
fn_cfg_validate(){
	local entry name def min max value
	# name:default:min:max
	local specs=(
		"port:2302:1:65535"
		"limitFPS:60:1:1000"
		"workshop_retries:5:1:50"
		"backup_retention_days:2:1:3650"
		"backup_retention_count:10:1:1000"
		"crash_retention_count:10:1:1000"
		"auto_update_on_start:1:0:1"
		"steam_api_cache_ttl:900:0:86400"
		"steam_update_check_interval:600:0:86400"
		"steamcmd_cooldown:5:0:3600"
		"steamcmd_batch_size:8:1:100"
		"min_free_mb:2048:0:1048576"
		"log_max_kb:1024:16:1048576"
		"log_keep:3:1:50"
		"web_port:8080:1:65535"
	)
	for entry in "${specs[@]}"; do
		IFS=':' read -r name def min max <<< "${entry}"
		value="${!name}"
		if ! [[ "${value}" =~ ^[0-9]+$ ]] || [ "${value}" -lt "${min}" ] || [ "${value}" -gt "${max}" ]; then
			printf "[ ${yellow}WARN${default} ] Invalid %s='%s' (allowed: %s-%s); using %s.\n" \
				"${name}" "${value}" "${min}" "${max}" "${def}"
			printf -v "${name}" '%s' "${def}"
		fi
	done
	case "${log_level}" in
		quiet|normal|verbose) ;;
		*)
			printf "[ ${yellow}WARN${default} ] Invalid log_level='%s' (allowed: quiet|normal|verbose); using normal.\n" \
				"${log_level}"
			log_level="normal"
			;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# fn_setup_dayz
# Interactive first-run configuration: Steam account, ports, RCon, web GUI
# and the generated serverDZ.cfg / BattlEye config.
# ---------------------------------------------------------------------------
fn_setup_dayz(){
	local setup_incomplete=0
	printf "\n${lightyellow}DayZ Server Manager - setup${default}\n"
	printf "Press Enter to accept the value in brackets.\n\n"

	# config.ini has to exist before we can edit it in place.
	if [ ! -f "${CONFIG_FILE}" ]; then
		printf '%s\n' "${DEFAULT_CONFIG}" > "${CONFIG_FILE}"
		chmod 600 "${CONFIG_FILE}"
	fi
	# Values already configured become the defaults, so re-running setup to
	# change one thing does not mean retyping everything. Parsed as data (the
	# config is never executed), quietly so setup's output stays clean.
	fn_cfg_load quiet 2>/dev/null || true

	printf "${cyan}Steam${default}\n"
	local new_login
	new_login="$(fn_prompt "  Steam username (must own DayZ)" "${steamlogin:-}")"
	if [ -z "${new_login}" ] || [ "${new_login}" = "CHANGEME" ]; then
		printf "[ ${red}FAIL${default} ] A Steam username is required.\n"
		return 1
	fi
	fn_set_config_value "steamlogin" "${new_login}"
	printf "  ${lightblue}Note${default}: SteamCMD asks for your password and Steam Guard code on first use.\n"
	printf "  It is never stored in %s.\n\n" "${CONFIG_FILE}"

	printf "${cyan}Ports${default}\n"
	local game_port query_port rcon_port
	game_port="$(fn_prompt "  Game port" "${port:-2301}")"
	query_port="$(fn_prompt "  Steam query port" "27016")"
	rcon_port="$(fn_prompt "  BattlEye RCon port" "2306")"
	if [ "${rcon_port}" = "${game_port}" ]; then
		printf "[ ${red}FAIL${default} ] The RCon port must differ from the game port.\n"
		return 1
	fi
	fn_set_config_value "port" "${game_port}"
	printf "\n"

	printf "${cyan}Server${default}\n"
	local hostname max_players rcon_pass
	hostname="$(fn_prompt "  Server name" "My DayZ Server")"
	max_players="$(fn_prompt "  Max players" "60")"
	rcon_pass="$(fn_prompt "  RCon password (leave blank to generate one)" "" secret)"
	if [ -z "${rcon_pass}" ]; then
		rcon_pass="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
		printf "  Generated RCon password: ${lightyellow}%s${default}\n" "${rcon_pass}"
	fi
	printf "\n"

	printf "${cyan}Web GUI${default}\n"
	local enable_web bind
	enable_web="$(fn_prompt "  Enable the web GUI? [y/N]" "n")"
	case "${enable_web}" in
		[Yy]*)
			bind="$(fn_prompt "  Bind address (127.0.0.1 keeps it local-only)" "127.0.0.1")"
			fn_set_config_value "web_bind" "${bind}"
			fn_set_config_value "web_port" "$(fn_prompt "  Web port" "8080")"
			if [ "${bind}" != "127.0.0.1" ] && [ "${bind}" != "localhost" ]; then
				printf "  [ ${yellow}WARN${default} ] %s exposes the GUI on the network over plain HTTP.\n" "${bind}"
				printf "  Put it behind a reverse proxy with HTTPS before using it that way.\n"
			fi
			;;
	esac
	printf "\n"

	# --- serverDZ.cfg ---------------------------------------------------
	local dz_cfg="${HOME}/serverfiles/${config:-serverDZ.cfg}"
	if [ -d "${HOME}/serverfiles" ]; then
		[ -f "${dz_cfg}" ] && cp -f "${dz_cfg}" "${dz_cfg}.bak.$(date +%Y%m%d-%H%M%S)"
		cat > "${dz_cfg}" <<EOF
hostname = "${hostname}";
password = "";
passwordAdmin = "";
maxPlayers = ${max_players};
verifySignatures = 2;
forceSameBuild = 1;
disableVoN = 0;
vonCodecQuality = 20;
disable3rdPerson = 0;
disableCrosshair = 0;
serverTime = "SystemTime";
serverTimeAcceleration = 12;
serverNightTimeAcceleration = 1;
serverTimePersistent = 0;
guaranteedUpdates = 1;
loginQueueConcurrentPlayers = 5;
loginQueueMaxPlayers = 500;
instanceId = 1;
storageAutoFix = 1;
steamQueryPort = ${query_port};

class Missions
{
    class DayZ
    {
        template = "dayzOffline.chernarusplus";
    };
};
EOF
		printf "[ ${green}OK${default} ] Wrote %s\n" "${dz_cfg}"
	else
		printf "[ ${yellow}SKIP${default} ] Server files are not installed yet, so %s and the\n" "${config:-serverDZ.cfg}"
		printf "\t BattlEye config cannot be written yet. Run '${lightyellow}%s install${default}' first,\n" "$0"
		printf "\t then run '${lightyellow}%s setup${default}' again to write them.\n" "$0"
		setup_incomplete=1
	fi

	# --- BattlEye -------------------------------------------------------
	local be_dir="${HOME}/serverfiles/battleye"
	if [ -d "${HOME}/serverfiles" ]; then
		mkdir -p "${be_dir}"
		cat > "${be_dir}/beserver_x64.cfg" <<EOF
RConPassword ${rcon_pass}
RConPort ${rcon_port}
RestrictRCon 0
EOF
		chmod 600 "${be_dir}/beserver_x64.cfg"
		# The server regenerates its active config from this one on launch, so
		# stale generated copies would otherwise keep the old password alive.
		rm -f "${be_dir}"/beserver_x64_active_*.cfg
		printf "[ ${green}OK${default} ] Wrote %s\n" "${be_dir}/beserver_x64.cfg"
	fi

	touch "${HOME}/workshop.cfg"
	chmod 600 "${HOME}/workshop.cfg"

	printf "\n[ ${green}DONE${default} ] Setup complete.\n\n"
	printf "${lightyellow}Next steps${default}\n"
	if [ "${setup_incomplete:-0}" = "1" ]; then
		printf "  1. %s install          # download the server files\n" "$0"
		printf "  2. %s setup            # write serverDZ.cfg and the RCon config\n" "$0"
		printf "  3. %s mods add <id>    # add Steam Workshop mods (optional)\n" "$0"
		printf "  4. %s start            # start the server\n\n" "$0"
	else
		printf "  1. %s mods add <id>    # add Steam Workshop mods (optional)\n" "$0"
		printf "  2. %s start            # start the server\n\n" "$0"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Standalone: 'lib/config.sh setup' runs the interactive setup.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	case "${1:-}" in
		setup) fn_setup_dayz ;;
		*)     printf '%s\n' \
			"lib/config.sh - config.ini creation, loading and interactive setup." \
			"Usage: lib/config.sh setup      (same as 'main.sh setup')" ;;
	esac
fi
