#!/usr/bin/env bash
#=======================================================================================#
# lib/web.sh - the web GUI (dayzweb.py: Dash + Mantine)
#
# Also runnable on its own: 'lib/web.sh {start|stop|status}'.
#=======================================================================================#

if [ -z "${_DAYZ_COMMON_LOADED:-}" ]; then
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# ---------------------------------------------------------------------------
# fn_web_script
# Echoes the dayzweb.py to run: the copy vendored next to main.sh first,
# falling back to ~/dayzweb.py for installs that predate the vendoring.
# ---------------------------------------------------------------------------
fn_web_script(){
	local root
	root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
	if [ -f "${root}/dayzweb.py" ]; then
		printf '%s' "${root}/dayzweb.py"
	elif [ -f "${HOME}/dayzweb.py" ]; then
		printf '%s' "${HOME}/dayzweb.py"
	fi
}

# ---------------------------------------------------------------------------
# fn_web_dayz
# start|stop|status for the web GUI. A pidfile tracks the process; a pidfile
# left behind by a killed process is cleaned up rather than trusted.
#
# Security: a non-loopback web_bind requires web_token to be set - the GUI
# then refuses to start without one. On 127.0.0.1 the token is optional
# (use an SSH tunnel to reach it remotely).
# ---------------------------------------------------------------------------
fn_web_dayz(){
	local action="${1:-status}"
	local pidfile="${HOME}/.dayzweb.pid"
	local script pid=""
	script="$(fn_web_script)"
	[ -f "${pidfile}" ] && pid="$(cat "${pidfile}" 2>/dev/null)"

	# A pidfile left behind by a killed process would otherwise make the GUI
	# look permanently "running".
	if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then
		rm -f "${pidfile}"
		pid=""
	fi

	case "${action}" in
		start)
			if [ -n "${pid}" ]; then
				printf "[ ${yellow}INFO${default} ] Web GUI already running (pid %s).\n" "${pid}"
				return 0
			fi
			if [ -z "${script}" ] || [ ! -f "${script}" ]; then
				printf "[ ${red}FAIL${default} ] dayzweb.py not found (looked next to main.sh and in %s).\n" "${HOME}"
				return 1
			fi
			command -v python3 &>/dev/null || {
				printf "[ ${red}FAIL${default} ] python3 is required for the web GUI.\n"
				return 1
			}
			python3 -c 'import dash, dash_mantine_components' 2>/dev/null || {
				printf "[ ${red}FAIL${default} ] The web GUI needs Dash and dash-mantine-components.\n"
				printf "[ ${lightblue}INFO${default} ] Install them with:\n\n\tpip3 install -r %s/requirements.txt\n\n" \
					"$(dirname "${script}")"
				return 1
			}
			if [ "${web_bind:-127.0.0.1}" != "127.0.0.1" ] && [ "${web_bind}" != "localhost" ] \
				&& [ -z "${web_token:-}" ]; then
				printf "[ ${red}FAIL${default} ] web_bind=%s exposes the GUI on the network; web_token is required.\n" "${web_bind}"
				printf "\tSet web_token= in %s (e.g. web_token=%s) or bind to 127.0.0.1.\n" \
					"${CONFIG_FILE}" "$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
				return 1
			fi

			fn_rotate_log "${HOME}/dayzweb.log"
			nohup python3 "${script}" >> "${HOME}/dayzweb.log" 2>&1 &
			echo $! > "${pidfile}"
			sleep 1
			if kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
				printf "[ ${green}OK${default} ] Web GUI started on ${cyan}http://%s:%s${default}\n" "${web_bind}" "${web_port}"
				if [ "${web_bind}" = "127.0.0.1" ]; then
					printf "[ ${lightblue}TIP${default} ] Reach it remotely with: ssh -L %s:127.0.0.1:%s %s@<server>\n" \
						"${web_port}" "${web_port}" "$(whoami)"
				fi
			else
				rm -f "${pidfile}"
				printf "[ ${red}FAIL${default} ] Web GUI failed to start. See %s\n" "${HOME}/dayzweb.log"
				return 1
			fi
			;;
		stop)
			if [ -z "${pid}" ]; then
				printf "[ ${yellow}INFO${default} ] Web GUI is not running.\n"
				return 0
			fi
			kill "${pid}" 2>/dev/null
			rm -f "${pidfile}"
			printf "[ ${green}OK${default} ] Web GUI stopped.\n"
			;;
		status)
			if [ -n "${pid}" ]; then
				printf "[ ${green}OK${default} ] Web GUI running (pid %s) on http://%s:%s\n" "${pid}" "${web_bind}" "${web_port}"
			else
				printf "[ ${yellow}INFO${default} ] Web GUI is not running.\n"
			fi
			;;
		*)
			printf "[ ${red}FAIL${default} ] Usage: %s web {start|stop|status}\n" "$0"
			return 1
			;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Standalone: control the web GUI.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
	fn_apply_defaults
	fn_web_dayz "$@"
fi
