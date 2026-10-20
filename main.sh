#!/usr/bin/env bash
#=======================================================================================#
#     Authors:  @fiskce / @tootlejack / @thelastnoc / @haywardgg
#     Contributors: @runtime-legend (community fork: crash diagnostics, workshop
#                   retry logic, Steam API update polling, config generation)
#=======================================================================================#
#
#                       DayZ Standalone Linux Server Manager
#
#     main.sh is the entry point and command dispatcher. The implementation
#     lives in the lib/ modules:
#
#       lib/common.sh    colours, logging, prompts, config access
#       lib/config.sh    config.ini creation/loading, interactive setup
#       lib/deps.sh      root/screen checks, packages, dependency check
#       lib/steam.sh     SteamCMD + Steam Web API (cached, rate-limited)
#       lib/workshop.sh  Steam Workshop mods: download, link, keys, updates
#       lib/server.sh    start/stop/restart/monitor/backup/wipe/clean
#       lib/query.sh     status report, A2S player query, BattlEye RCon
#       lib/web.sh       the optional web GUI
#       lib/systemd.sh   systemd user unit generation
#
#     Every module is a standalone-executable script on Linux and prints its
#     own help when run directly.
#=======================================================================================#

### NO NEED TO EDIT ANYTHING IN THIS FILE ###
### Changes should be made in config.ini ###

# A failure anywhere in a pipeline must fail the pipeline: several checks below
# read SteamCMD through a pipe, and without this a broken steamcmd.sh would look
# like a clean run.
set -o pipefail

# --- load the modules ----------------------------------------------------
DAYZ_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
for _module in common config deps steam workshop server query web systemd; do
	. "${DAYZ_ROOT}/lib/${_module}.sh"
done
unset _module

# --- lock state and cleanup on exit/signals -------------------------------
# A killed run must not leave .dayzlockupdate behind (the monitor stands down
# while it exists), and the run lock must only ever be released by its owner.
DAYZ_UPDATE_LOCK_HELD=0

fn_locks_release(){
	if [ "${DAYZ_UPDATE_LOCK_HELD}" = "1" ]; then
		rm -f "${HOME}/.dayzlockupdate"
	fi
	fn_run_lock_release
}
trap 'fn_locks_release' EXIT
trap 'fn_locks_release; exit 130' INT
trap 'fn_locks_release; exit 143' TERM
trap 'fn_locks_release; exit 129' HUP

# Work out which command was asked for before anything else runs.
#
# Some commands must work in states where config.ini is absent, incomplete or
# points at a server that was never installed: `setup` is what creates a valid
# config in the first place, `cleanserver` only deletes files, and `version`
# and `help` answer without touching the server at all. Those skip the setup
# gates below and the auto-install gate further down.
getopt="$1"
case "${getopt}" in
    cs|cleanserver|setup|version|--version|-v|help|--help|-h) maintenance_mode=1 ;;
    *)                                                       maintenance_mode=0 ;;
esac

if [ "${maintenance_mode}" != "1" ]; then
    fn_ensure_config
    _config_state=$?
    if [ "${_config_state}" -eq 2 ]; then
        exit 1
    fi
    fn_load_config || exit 1
fi

# Colours are re-initialised after config.ini is loaded so `ansi=off` works.
fn_init_colors
fn_apply_defaults

# ---------------------------------------------------------------------------
# commands - the table printed by fn_opt_usage; "short|long|description".
# ---------------------------------------------------------------------------
commands=(
	"setup|setup|Interactive first-run configuration (start here)."
	"stat|status|Show server status. Add --json for machine-readable output."
	"st|start|Start the server."
	"sp|stop|Stop the server."
	"r|restart|Restart the server."
	"m|monitor|Check server status and restart it if it crashed."
	"c|console|Attach to the server console."
	"i|install|Install SteamCMD and the DayZ server files."
	"u|update|Check for and apply server updates. Add --force to skip the check cache."
	"v|validate|Validate the server files with SteamCMD."
	"ws|workshop|Download and link Steam Workshop mods."
	"chm|checkmods|Check the workshop for mod updates; flag them for the next start."
	"uc|updateconfig|Rebuild the workshop= launch line in config.ini."
	"b|backup|Create compressed backups of the mission and server profile."
	"rs|restore|Restore a backup. Without arguments lists the available archives."
	"wi|wipe|Wipe server data (players and storage)."
	"cc|cleancache|Clear SteamCMD and workshop caches (keeps your Steam login)."
	"cs|cleanserver|Delete the installed server, mods and config for a fresh start."
	"mods|mods|Manage mods: mods add|remove|list|export|import [id|url|file]."
	"p|players|Show the current player count. Add 'list' for player names."
	"rc|rcon|Send a BattlEye RCon command, e.g. rcon players."
	"web|web|Control the web GUI: web start|stop|status."
	"sd|systemd|Write systemd user units for the server, monitor and GUI."
)

# ---------------------------------------------------------------------------
# fn_opt_usage
# Prints the command table. Exits 0 when the user asked for help and non-zero
# only when it is shown because of a mistake - cron and systemd read the exit
# status, and the old code reported failure on every successful run.
# ---------------------------------------------------------------------------
fn_opt_usage(){
	local entry short long desc
	printf "\n${lightyellow}DayZ Linux Server Manager${default} v${SCRIPT_VERSION}\n"
	printf "\nUsage:${lightblue} $0 [command]${default}\n\n"
	printf "${lightyellow}Commands${default}\n"
	# Columns are aligned with printf padding rather than `column`, which is not
	# installed on minimal systems and containers.
	for entry in "${commands[@]}"; do
		IFS='|' read -r short long desc <<< "${entry}"
		printf "  ${cyan}%-14s${default}%-6s %s\n" "${long}" "${short}" "${desc}"
	done
	printf "\n"
	return "${1:-0}"
}

# ---------------------------------------------------------------------------
# fn_dispatch
# Maps a command (long name or short alias) to its function, forwarding any
# remaining arguments. Returns 127 for an unknown command so the caller can
# tell "no such command" apart from "the command failed".
# ---------------------------------------------------------------------------
fn_dispatch(){
	local cmd="$1"
	shift || true
	case "${cmd}" in
		setup)         fn_setup_dayz "$@" ;;
		stat|status)   fn_status_dayz_report "$@" ;;
		st|start)      fn_start_dayz "$@" ;;
		sp|stop)       fn_stop_dayz "$@" ;;
		r|restart)     fn_restart_dayz "$@" ;;
		m|monitor)     fn_monitor_dayz "$@" ;;
		c|console)     fn_console_dayz "$@" ;;
		i|install)     fn_install_dayz "$@" ;;
		u|update)      fn_update_dayz "$@" ;;
		v|validate)    fn_validate_dayz "$@" ;;
		ws|workshop)   fn_workshop_mods "$@" ;;
		chm|checkmods) fn_check_mods "$@" ;;
		uc|updateconfig) fn_update_workshop_line "$@" ;;
		b|backup)      fn_backup_dayz "$@" ;;
		rs|restore)    fn_restore_dayz "$@" ;;
		wi|wipe)       fn_wipe_dayz "$@" ;;
		cc|cleancache) fn_clean_dayz "$@" ;;
		cs|cleanserver) fn_clean_server "$@" ;;
		mods)          fn_mods_dayz "$@" ;;
		p|players)     fn_players_dayz "$@" ;;
		rc|rcon)       fn_rcon_dayz "$@" ;;
		web)           fn_web_dayz "$@" ;;
		sd|systemd)    fn_systemd_dayz "$@" ;;
		help|--help|-h)          fn_opt_usage 0 ;;
		version|--version|-v)    printf "DayZ Linux Server Manager v%s\n" "${SCRIPT_VERSION}" ;;
		*)             return 127 ;;
	esac
}

#=======================================================================================#
#                                        Startup                                        #
#=======================================================================================#

fn_checkroot_dayz
fn_checkscreen

# help and version answer without needing dependencies or an installed server.
case "${getopt}" in
	help|--help|-h|version|--version|-v)
		fn_dispatch "${getopt}"
		exit $?
		;;
esac

check_dependencies

# --- run lock: one mutating operation at a time ---------------------------
# The once-a-minute `monitor` skips quietly when something else is going on;
# every other mutating command fails fast with a pointer to the holder.
case "${getopt}" in
	m|monitor)
		if ! fn_run_lock_try; then
			printf "[ ${lightblue}INFO${default} ] Another manager operation is running; skipping this check.\n"
			exit 0
		fi
		;;
	setup|st|start|sp|stop|r|restart|u|update|v|validate|ws|workshop|chm|checkmods|uc|updateconfig|b|backup|rs|restore|wi|wipe|i|install|cc|cleancache|cs|cleanserver|mods)
		fn_run_lock_acquire || exit 1
		;;
esac

fn_stale_update_lock_sweep

if [ "${maintenance_mode}" != "1" ]; then
	if [ ! -f "${HOME}/steamcmd/steamcmd.sh" ] || [ ! -f "${HOME}/serverfiles/DayZServer" ]; then
		printf "[ ${yellow}INFO${default} ] No SteamCMD and/or server files found.\n"
		# $0 is this script; the old code chmod'd "${HOME}/dayzserver", a path
		# that has never existed - the file is dayzserver.sh.
		chmod u+x "$0" 2>/dev/null
		fn_install_dayz
		if [ -f "${HOME}/steamcmd/steamcmd.sh" ] && [ -f "${HOME}/serverfiles/DayZServer" ]; then
			fn_opt_usage 0
		fi
		exit 0
	fi
fi

if [ -z "${getopt}" ]; then
	fn_opt_usage 0
	exit 0
fi

fn_dispatch "$@"
status=$?

if [ "${status}" -eq 127 ]; then
	printf "${red}Unknown command${default}: %s %s\n" "$0" "${getopt}"
	fn_opt_usage 1
	exit 1
fi

exit "${status}"
