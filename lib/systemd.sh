#!/usr/bin/env bash
#=======================================================================================#
# lib/systemd.sh - generates the systemd user units (server, monitor, checkmods, web)
#
# Also runnable on its own: 'lib/systemd.sh install' writes the units.
#=======================================================================================#

if [ -z "${_DAYZ_COMMON_LOADED:-}" ]; then
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# ---------------------------------------------------------------------------
# fn_systemd_dayz
# Writes user-level units and timers into ~/.config/systemd/user.
#
# The units always invoke the top-level main.sh, wherever this module is
# called from: the old code baked in "$0", so 'lib/systemd.sh install'
# generated units whose ExecStart pointed at a module that only prints usage.
# The checkmods timer runs every 2 hours - combined with the API cache in
# lib/steam.sh this stays well inside Steam's rate limits even if the timer
# is tightened up.
# ---------------------------------------------------------------------------
fn_systemd_dayz(){
	local unit_dir="${HOME}/.config/systemd/user"
	local script_path web_script
	script_path="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/main.sh"
	if [ ! -f "${script_path}" ]; then
		script_path="$(readlink -f "$0")"
	fi
	web_script="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/dayzweb.py"
	[ -f "${web_script}" ] || web_script="${HOME}/dayzweb.py"
	mkdir -p "${unit_dir}"

	cat > "${unit_dir}/dayzserver.service" <<EOF
[Unit]
Description=DayZ Standalone Server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
NoNewPrivileges=yes
PrivateTmp=yes
WorkingDirectory=${HOME}
ExecStart="${script_path}" start
ExecStop="${script_path}" stop
TimeoutStartSec=1800
TimeoutStopSec=120
# The server itself runs inside tmux (outside this unit's control), so a
# MemoryMax here would only limit the start/stop commands, not the server.
# Limit the server in tmux or with a DayZ-side setting instead.

[Install]
WantedBy=default.target
EOF

	cat > "${unit_dir}/dayzserver-monitor.service" <<EOF
[Unit]
Description=DayZ server crash monitor
After=dayzserver.service

[Service]
Type=oneshot
NoNewPrivileges=yes
PrivateTmp=yes
Nice=5
WorkingDirectory=${HOME}
ExecStart="${script_path}" monitor
EOF

	cat > "${unit_dir}/dayzserver-monitor.timer" <<EOF
[Unit]
Description=Run the DayZ crash monitor every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
RandomizedDelaySec=5s

[Install]
WantedBy=timers.target
EOF

	cat > "${unit_dir}/dayzserver-checkmods.service" <<EOF
[Unit]
Description=Check the Steam Workshop for DayZ mod updates

[Service]
Type=oneshot
NoNewPrivileges=yes
PrivateTmp=yes
Nice=5
WorkingDirectory=${HOME}
ExecStart="${script_path}" checkmods
EOF

	cat > "${unit_dir}/dayzserver-checkmods.timer" <<EOF
[Unit]
Description=Check for DayZ mod updates every 2 hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=2h
AccuracySec=1min
RandomizedDelaySec=2min

[Install]
WantedBy=timers.target
EOF

	cat > "${unit_dir}/dayzweb.service" <<EOF
[Unit]
Description=DayZ Server Manager web GUI
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
LockPersonality=yes
RestrictSUIDSGID=yes
WorkingDirectory=${HOME}
ExecStart=/usr/bin/env python3 ${web_script}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

	printf "[ ${green}OK${default} ] Wrote systemd user units to %s\n\n" "${unit_dir}"
	printf "${lightyellow}Enable them with${default}\n"
	printf "  systemctl --user daemon-reload\n"
	printf "  systemctl --user enable --now dayzserver.service\n"
	printf "  systemctl --user enable --now dayzserver-monitor.timer\n"
	printf "  systemctl --user enable --now dayzserver-checkmods.timer\n"
	printf "  systemctl --user enable --now dayzweb.service        # optional web GUI\n\n"
	printf "${lightyellow}So they start at boot without you logged in${default}\n"
	printf "  sudo loginctl enable-linger %s\n\n" "$(whoami)"
	return 0
}

# ---------------------------------------------------------------------------
# Standalone: 'lib/systemd.sh install' writes the units.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	case "${1:-}" in
		install|write) fn_systemd_dayz ;;
		*) printf '%s\n' \
			"lib/systemd.sh - generates the systemd user units." \
			"Usage: lib/systemd.sh install      (same as 'main.sh systemd')" ;;
	esac
fi
