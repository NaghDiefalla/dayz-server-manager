#!/usr/bin/env bash
#=======================================================================================#
# lib/query.sh - status reporting: A2S player query, BattlEye RCon, status view
#
# Also runnable on its own: 'lib/query.sh status' shows the server status,
# 'lib/query.sh players' the current player count.
#=======================================================================================#

if [ -z "${_DAYZ_COMMON_LOADED:-}" ]; then
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# ---------------------------------------------------------------------------
# fn_query_port
# The Steam query port from serverDZ.cfg (27016 when unset).
# ---------------------------------------------------------------------------
fn_query_port(){
	local qp
	qp="$(fn_cfg_value "${HOME}/serverfiles/${config}" "steamQueryPort")"
	printf '%s' "${qp:-27016}"
}

# ---------------------------------------------------------------------------
# fn_a2s_players
# Queries the local A2S_INFO endpoint and prints the player count. Needs
# python3 for binary-safe UDP; returns 1 when the server does not answer.
# ---------------------------------------------------------------------------
fn_a2s_players(){
	local qport="$1"
	command -v python3 &>/dev/null || return 1
	python3 - "${qport}" <<'PYEOF' 2>/dev/null
import socket, struct, sys

port = int(sys.argv[1])
REQ = b"\xff\xff\xff\xffTSource Engine Query\x00"

try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2.0)
    s.sendto(REQ, ("127.0.0.1", port))
    data, _ = s.recvfrom(4096)

    # Modern servers answer a bare A2S_INFO with a challenge (header 'A') that
    # must be echoed back before they send the real reply.
    if len(data) > 4 and data[4:5] == b"A":
        s.sendto(REQ + data[5:9], ("127.0.0.1", port))
        data, _ = s.recvfrom(4096)

    if len(data) < 5 or data[4:5] != b"I":
        sys.exit(1)

    # Header(4) + type(1) + protocol(1), then four null-terminated strings:
    # name, map, folder, game. Then app id (short), then players.
    i = 6
    for _ in range(4):
        end = data.index(b"\x00", i)
        i = end + 1
    i += 2  # app id
    print(struct.unpack_from("<B", data, i)[0])
except Exception:
    sys.exit(1)
PYEOF
}

# ---------------------------------------------------------------------------
# fn_a2s_player_list
# Prints one "name (score pts, minutes online)" line per connected player via
# A2S_PLAYER. Needs python3; returns 1 when the server does not answer.
# ---------------------------------------------------------------------------
fn_a2s_player_list(){
	local qport="$1"
	command -v python3 &>/dev/null || return 1
	python3 - "${qport}" <<'PYEOF' 2>/dev/null
import socket, struct, sys

port = int(sys.argv[1])
REQ = b"\xff\xff\xff\xffU\xff\xff\xff\xff"


def query(req):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2.0)
    s.sendto(req, ("127.0.0.1", port))
    data, _ = s.recvfrom(65535)
    if len(data) > 4 and data[4:5] == b"A":
        s.sendto(req + data[5:9], ("127.0.0.1", port))
        data, _ = s.recvfrom(65535)
    return data


try:
    data = query(REQ)
    if len(data) < 6 or data[4:5] != b"D":
        sys.exit(1)
    count = data[5]
    i = 6
    for _ in range(count):
        if i + 5 > len(data):
            break
        i += 1  # player index
        end = data.index(b"\x00", i)
        name = data[i:end].decode("utf-8", "replace")
        i = end + 1
        score, duration = struct.unpack_from("<if", data, i)
        i += 8
        print(f"{name} ({int(score)} pts, {int(duration // 60)} min)")
except Exception:
    sys.exit(1)
PYEOF
}

# ---------------------------------------------------------------------------
# fn_players_dayz [list]
# 'players' prints the player count; 'players list' names everyone connected.
# ---------------------------------------------------------------------------
fn_players_dayz(){
	local qport
	qport="$(fn_query_port)"
	case "${1:-}" in
		list|--list|-l)
			local players
			players="$(fn_a2s_player_list "${qport}")" || {
				printf "[ ${yellow}INFO${default} ] Server did not answer the query.\n"
				return 1
			}
			if [ -z "${players}" ]; then
				printf "[ ${lightblue}INFO${default} ] No players connected.\n"
				return 0
			fi
			printf "\n${lightyellow}Players online${default}\n"
			printf '%s\n' "${players}" | sed 's/^/  /'
			printf "\n"
			;;
		*)
			fn_a2s_players "${qport}" || {
				printf "[ ${yellow}INFO${default} ] Server did not answer the query.\n"
				return 1
			}
			;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# fn_be_cfg
# Path of the active BattlEye server config. The server regenerates
# beserver_x64_active_*.cfg on launch, so the newest one wins; the static
# beserver_x64.cfg is the fallback before the first start.
# ---------------------------------------------------------------------------
fn_be_cfg(){
	local active
	active="$(find "${HOME}/serverfiles/battleye" -maxdepth 1 -name 'beserver_x64_active_*.cfg' \
		-printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
	if [ -n "${active}" ]; then
		printf '%s' "${active}"
	elif [ -f "${HOME}/serverfiles/battleye/beserver_x64.cfg" ]; then
		printf '%s' "${HOME}/serverfiles/battleye/beserver_x64.cfg"
	else
		return 1
	fi
}

# ---------------------------------------------------------------------------
# fn_rcon_dayz
# Sends a BattlEye RCon command through bercon-cli.
# ---------------------------------------------------------------------------
fn_rcon_dayz(){
	if [ "$#" -eq 0 ]; then
		printf "[ ${red}FAIL${default} ] Usage: %s rcon <command>    e.g. %s rcon players\n" "$0" "$0"
		return 1
	fi

	if ! command -v bercon-cli &>/dev/null; then
		printf "[ ${red}FAIL${default} ] bercon-cli is not installed.\n"
		printf "[ ${lightblue}INFO${default} ] Install it with:\n\n"
		printf "\tsudo curl -L -o /usr/local/bin/bercon-cli \\\\\n"
		printf "\t  https://github.com/WoozyMasta/bercon-cli/releases/latest/download/bercon-cli-linux-amd64\n"
		printf "\tsudo chmod +x /usr/local/bin/bercon-cli\n\n"
		return 1
	fi

	local be_cfg rcon_port rcon_pass
	be_cfg="$(fn_be_cfg)" || {
		printf "[ ${red}FAIL${default} ] No BattlEye config found. Start the server once, or run '%s setup'.\n" "$0"
		return 1
	}
	rcon_port="$(fn_cfg_value "${be_cfg}" "RConPort")"
	rcon_pass="$(fn_cfg_value "${be_cfg}" "RConPassword")"

	if [ -z "${rcon_pass}" ]; then
		printf "[ ${red}FAIL${default} ] No RConPassword set in %s\n" "${be_cfg}"
		printf "[ ${lightblue}TIP${default} ] Run '%s setup' to configure RCon.\n" "$0"
		return 1
	fi
	: "${rcon_port:=2306}"

	# The password stays out of argv (visible to every user via ps) and out of
	# the environment: bercon-cli reads RConIP/RConPort/RConPassword straight
	# from beserver_x64*.cfg via --server-cfg, which also keeps port and
	# password in one place.
	bercon-cli --server-cfg "${HOME}/serverfiles/battleye" "$@"
}

# ---------------------------------------------------------------------------
# fn_status_dayz_report
# Human-readable status, or JSON with --json for the web GUI and scripts.
# ---------------------------------------------------------------------------
fn_status_dayz_report(){
	local as_json=0
	[ "${1:-}" = "--json" ] && as_json=1

	fn_status_dayz
	local running="false" uptime=0 build="" mods=0 pending="false" last_exit="" players=""
	[ "${dayzstatus}" != "0" ] && running="true"
	uptime="$(fn_server_uptime)"
	[ "${running}" = "false" ] && uptime=0

	local manifest="${HOME}/serverfiles/steamapps/appmanifest_${appid}.acf"
	if [ -f "${manifest}" ]; then
		build="$(grep buildid "${manifest}" | tr '[:blank:]"' ' ' | tr -s ' ' | cut -d ' ' -f3)"
	fi
	mods="$(fn_read_workshop_ids | wc -l | tr -d ' ')"
	[ -f "${HOME}/update_pending" ] && pending="true"
	[ -f "${HOME}/last_exit_code" ] && last_exit="$(tr -dc '0-9' < "${HOME}/last_exit_code")"
	[ "${running}" = "true" ] && players="$(fn_a2s_players "$(fn_query_port)" 2>/dev/null || true)"

	if [ "${as_json}" = "1" ]; then
		jq -nc \
			--argjson running "${running}" \
			--argjson uptime "${uptime}" \
			--arg build "${build}" \
			--argjson mods "${mods:-0}" \
			--argjson pending "${pending}" \
			--arg last_exit "${last_exit}" \
			--arg players "${players}" \
			--arg version "${SCRIPT_VERSION}" \
			--argjson port "${port}" \
			'{
				running: $running,
				uptime_seconds: $uptime,
				build: $build,
				mod_count: $mods,
				update_pending: $pending,
				last_exit_code: $last_exit,
				players: (if $players == "" then null else ($players | tonumber) end),
				port: $port,
				version: $version
			}'
		return 0
	fi

	printf "\n${lightyellow}DayZ Server Status${default}\n"
	if [ "${running}" = "true" ]; then
		printf "  State:      ${green}running${default} (%dh %dm)\n" "$(( uptime / 3600 ))" "$(( (uptime % 3600) / 60 ))"
	else
		printf "  State:      ${red}stopped${default}\n"
	fi
	printf "  Game port:  %s\n" "${port}"
	printf "  Query port: %s\n" "$(fn_query_port)"
	printf "  Build:      %s\n" "${build:-unknown}"
	printf "  Mods:       %s\n" "${mods}"
	[ -n "${players}" ] && printf "  Players:    %s\n" "${players}"
	if [ "${pending}" = "true" ]; then
		printf "  Updates:    ${yellow}mod updates pending${default} (applied on next start)\n"
	else
		printf "  Updates:    ${green}up to date${default}\n"
	fi
	[ -n "${last_exit}" ] && [ "${running}" = "false" ] && printf "  Last exit:  %s\n" "${last_exit}"
	printf "  Manager:    v%s\n\n" "${SCRIPT_VERSION}"
	return 0
}

# ---------------------------------------------------------------------------
# Standalone: status (default) or players.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/server.sh"
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workshop.sh"
	fn_apply_defaults
	case "${1:-status}" in
		players|p) shift; fn_players_dayz "$@" ;;
		*)         fn_status_dayz_report "$@" ;;
	esac
fi
