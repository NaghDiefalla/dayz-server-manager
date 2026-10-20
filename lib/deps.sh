#!/usr/bin/env bash
#=======================================================================================#
# lib/deps.sh - environment checks: root, screen, package manager, dependencies
#
# Also runnable on its own: 'lib/deps.sh' runs the dependency check.
#=======================================================================================#

if [ -z "${_DAYZ_COMMON_LOADED:-}" ]; then
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# ---------------------------------------------------------------------------
# fn_checkroot_dayz
# Running the server as root leaves root-owned files all over the install and
# gives a game server far more privilege than it needs, so this is refused.
#
# DAYZ_ALLOW_ROOT=1 overrides the check. It exists for containers and CI, where
# there is no other user to switch to; it is not a supported way to run a real
# server.
# ---------------------------------------------------------------------------
fn_checkroot_dayz(){
	if [ "$(id -u)" -eq 0 ]; then
		if [ "${DAYZ_ALLOW_ROOT:-0}" = "1" ]; then
			printf "[ ${yellow}WARN${default} ] Running as root because DAYZ_ALLOW_ROOT=1 is set.\n"
			return 0
		fi
		printf "[ ${red}FAIL${default} ] ${yellow}Do NOT run this script as root!\n"
		printf "\tSwitch to the dayz user, or set DAYZ_ALLOW_ROOT=1 if you are in a container.${default}\n"
		exit 1
	fi
}

# ---------------------------------------------------------------------------
# fn_checkscreen
# The server runs inside a tmux session, and tmux cannot nest inside screen.
# ---------------------------------------------------------------------------
fn_checkscreen(){
	if [ -n "${STY}" ]; then
		printf "[ ${red}FAIL${default} ] The Script creates a tmux session when starting the server.\n"
		printf "\tIt is not possible to run a tmux session inside screen session\n"
		exit 1
	fi
}

# ---------------------------------------------------------------------------
# fn_detect_pkg_manager
# Sets pkg_manager and pkg_install_cmd for the running distribution. The old
# check assumed dpkg, so the dependency check hard-failed on Arch and Fedora
# even though the instructions it printed named pacman and dnf.
# ---------------------------------------------------------------------------
fn_detect_pkg_manager(){
	if command -v apt-get &>/dev/null; then
		pkg_manager="apt"; pkg_install_cmd="sudo apt install -y"
	elif command -v dnf &>/dev/null; then
		pkg_manager="dnf"; pkg_install_cmd="sudo dnf install -y"
	elif command -v yum &>/dev/null; then
		pkg_manager="yum"; pkg_install_cmd="sudo yum install -y"
	elif command -v pacman &>/dev/null; then
		pkg_manager="pacman"; pkg_install_cmd="sudo pacman -S --needed"
	elif command -v zypper &>/dev/null; then
		pkg_manager="zypper"; pkg_install_cmd="sudo zypper install -y"
	else
		pkg_manager="unknown"; pkg_install_cmd=""
	fi
}

# ---------------------------------------------------------------------------
# fn_pkg_name
# Maps a logical dependency to this distribution's package name.
# ---------------------------------------------------------------------------
fn_pkg_name(){
	case "$1:${pkg_manager}" in
		lib32gcc:apt)     echo "lib32gcc-s1" ;;
		lib32gcc:dnf)     echo "glibc.i686 libstdc++.i686" ;;
		lib32gcc:yum)     echo "glibc.i686 libstdc++.i686" ;;
		lib32gcc:pacman)  echo "lib32-gcc-libs" ;;
		lib32gcc:zypper)  echo "glibc-32bit libstdc++6-32bit" ;;
		lib32gcc:*)       echo "lib32gcc" ;;
		*)                echo "$1" ;;
	esac
}

# ---------------------------------------------------------------------------
# fn_have_lib32
# Best-effort check for the 32-bit runtime SteamCMD needs. Each package manager
# is queried in its own language; an unrecognised distribution is reported as a
# warning rather than a hard failure, because refusing to run on a system we
# simply cannot introspect is worse than letting SteamCMD speak for itself.
# ---------------------------------------------------------------------------
fn_have_lib32(){
	case "${pkg_manager}" in
		apt)    [[ "$(dpkg-query -W -f='${Status}' lib32gcc-s1 2>/dev/null)" == *"ok installed"* ]] ;;
		dnf|yum) rpm -q glibc.i686 &>/dev/null ;;
		pacman) pacman -Qq lib32-gcc-libs &>/dev/null ;;
		zypper) rpm -q glibc-32bit &>/dev/null ;;
		*)      return 2 ;;
	esac
}

# ---------------------------------------------------------------------------
# check_dependencies
# Verifies the tools this run actually needs.
#
# The 32-bit runtime is only required to execute SteamCMD and the server
# binary, so it is checked only for the commands that do that. Refusing to
# print `status` because a library the command never touches is missing is
# just an obstacle.
#
# Reads the global ${getopt} (the requested command) to decide how thorough
# to be.
# ---------------------------------------------------------------------------
check_dependencies(){
	local missing_tools=()
	local tools=("tmux" "curl" "jq" "wget" "tar" "awk" "sed")
	local tool lib32_status needs_runtime=0

	case "${getopt}" in
		i|install|st|start|r|restart|u|update|v|validate|ws|workshop|m|monitor)
			needs_runtime=1 ;;
	esac

	fn_detect_pkg_manager

	for tool in "${tools[@]}"; do
		if ! command -v "$tool" &>/dev/null; then
			missing_tools+=("$(fn_pkg_name "$tool")")
		fi
	done

	if [ "${needs_runtime}" = "0" ]; then
		if [ "${#missing_tools[@]}" -ne 0 ]; then
			printf "[ ${red}ERROR${default} ] Missing dependencies: ${yellow}%s${default}\n" "${missing_tools[*]}"
			exit 1
		fi
		return 0
	fi

	fn_have_lib32
	lib32_status=$?
	if [ "${lib32_status}" -eq 1 ]; then
		missing_tools+=("$(fn_pkg_name lib32gcc)")
	elif [ "${lib32_status}" -eq 2 ]; then
		printf "[ ${yellow}WARN${default} ] Unrecognised package manager; cannot verify the 32-bit runtime.\n"
		printf "\tSteamCMD needs 32-bit gcc/glibc libraries. Install them if it fails to start.\n"
	fi

	if [ "${#missing_tools[@]}" -ne 0 ]; then
		printf "[ ${red}ERROR${default} ] Missing dependencies: ${yellow}%s${default}\n" "${missing_tools[*]}"
		if [ -n "${pkg_install_cmd}" ]; then
			printf "[ ${lightblue}INFO${default} ] Install them with:\n\n\t%s %s\n\n" \
				"${pkg_install_cmd}" "${missing_tools[*]}"
		else
			printf "[ ${lightblue}INFO${default} ] Install them with your distribution's package manager.\n"
		fi
		exit 1
	fi

	printf "[ ${green}OK${default} ] All required tools are installed.\n"

	# Optional tools: their features degrade quietly without them, so say so
	# once instead of letting 'players' and 'status' simply return nothing.
	local optional missing_optional=()
	for optional in python3 gzip; do
		command -v "${optional}" &>/dev/null || missing_optional+=("${optional}")
	done
	if [ "${#missing_optional[@]}" -ne 0 ]; then
		printf "[ ${yellow}WARN${default} ] Optional tools missing: ${yellow}%s${default}\n" "${missing_optional[*]}"
		printf "\tWithout python3 the player queries degrade; without gzip rotated logs stay uncompressed.\n"
	fi
}

# ---------------------------------------------------------------------------
# Standalone: run the dependency check for a full install.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	printf '%s\n' "lib/deps.sh - running dependency check (as if for 'install')..."
	getopt="install"
	check_dependencies
fi
