#!/usr/bin/env python3
"""
dayzweb.py - web GUI for the DayZ Linux Server Manager (Dash + Mantine).

Shows server status, player-count history, the mod list and recent events,
and can start/stop/restart/update the server. It drives the exact same
'main.sh' commands as the CLI, so the run locks and safety checks all apply.

Security model:
  * Bind 127.0.0.1 (default): no token needed - reach it through an SSH
    tunnel. This is the recommended setup.
  * Any other web_bind: a web_token is REQUIRED (refuses to start without
    one). Every request must carry either ?token=..., a
    'Authorization: Bearer <token>' header, or a session created via /login.

Run via 'main.sh web start' (preferred) or 'python3 dayzweb.py'.
Dependencies: pip3 install -r requirements.txt
"""

import hmac
import json
import os
import secrets
import subprocess
import sys
import threading
import time
from pathlib import Path

# --- dependencies, with an actionable error ---------------------------------
try:
    import plotly.graph_objs as go
    import dash_mantine_components as dmc
    from dash import Dash, Input, Output, callback_context, dcc, html
except ImportError as exc:  # pragma: no cover
    sys.exit(
        "dayzweb.py: missing dependency (%s).\n"
        "Install the web GUI requirements with:\n\n"
        "    pip3 install -r requirements.txt\n" % exc
    )

# --- environment and config --------------------------------------------------
WORKDIR = Path(os.environ.get("DAYZ_WORKDIR", str(Path.home())))
MANAGER_DIR = Path(os.environ.get("DAYZ_MANAGER_DIR", str(Path(__file__).resolve().parent)))
MAIN_SH = Path(os.environ.get("DAYZ_MAIN", str(MANAGER_DIR / "main.sh")))
HISTORY_FILE = Path(os.environ.get("DAYZWEB_HISTORY", str(WORKDIR / ".dayzweb_history.jsonl")))
MONITOR_LOG = WORKDIR / "monitor.log"
WORKSHOP_CFG = WORKDIR / "workshop.cfg"

REFRESH_SECONDS = 10
HISTORY_MIN_INTERVAL = 20      # seconds between history samples
HISTORY_MAX_POINTS = 2880      # ~16h at one sample per 20s
ACTIONS = {
    "btn-start": "start",
    "btn-stop": "stop",
    "btn-restart": "restart",
    "btn-update": "update",
    "btn-validate": "validate",
    "btn-workshop": "workshop",
    "btn-checkmods": "checkmods",
    "btn-backup": "backup",
}
ACTION_TIMEOUT = 3600


def load_config() -> dict:
    """Reads config.ini as data (same rules as fn_cfg_load in lib/common.sh):
    key=value lines, # comments, optional surrounding double quotes. Values
    are never executed."""
    path = WORKDIR / "config.ini"
    values = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key.replace("_", "").isalnum() or key[0].isdigit():
            continue
        value = value.strip()
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            value = value[1:-1].replace('\\"', '"')
        values[key] = value
    return values


CFG = load_config()
BIND = os.environ.get("DAYZWEB_BIND", CFG.get("web_bind", "127.0.0.1"))
PORT = int(os.environ.get("DAYZWEB_PORT", CFG.get("web_port", "8080")))
TOKEN = (os.environ.get("DAYZWEB_TOKEN", CFG.get("web_token", "")) or "").strip()

if TOKEN == "" and BIND not in ("127.0.0.1", "localhost", "::1"):
    sys.exit(
        "dayzweb.py: web_bind=%s is reachable from the network, so web_token is\n"
        "required. Set web_token= in config.ini (any long random string), or bind\n"
        "to 127.0.0.1 and use an SSH tunnel.\n" % BIND
    )

# --- manager interaction -----------------------------------------------------
JOB = {"name": None, "started": 0.0, "done": True, "rc": 0, "output": ""}
JOB_LOCK = threading.Lock()
_history_last_ts = 0.0


def run_manager(*args, timeout=ACTION_TIMEOUT):
    """Runs one main.sh command in the manager's working directory."""
    cmd = ["bash", str(MAIN_SH), *args]
    try:
        proc = subprocess.run(
            cmd, cwd=str(WORKDIR), capture_output=True, text=True, timeout=timeout
        )
        return proc.returncode, (proc.stdout + proc.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timed out after %ss" % timeout
    except OSError as exc:
        return 126, "could not run %s: %s" % (MAIN_SH, exc)


def fetch_status() -> dict:
    rc, out = run_manager("status", "--json", timeout=60)
    if rc == 0 and out:
        try:
            return json.loads(out[out.index("{"): out.rindex("}") + 1])
        except (ValueError, json.JSONDecodeError):
            pass
    return {"error": out or "status command failed (rc=%s)" % rc}


def record_history(status: dict) -> None:
    """Appends a sample for the player chart, at most once per
    HISTORY_MIN_INTERVAL seconds, bounded to HISTORY_MAX_POINTS."""
    global _history_last_ts
    now = time.time()
    if now - _history_last_ts < HISTORY_MIN_INTERVAL:
        return
    _history_last_ts = now
    entry = {
        "ts": int(now),
        "players": status.get("players") or 0,
        "running": bool(status.get("running")),
    }
    try:
        with HISTORY_FILE.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
        lines = HISTORY_FILE.read_text(encoding="utf-8").splitlines()
        if len(lines) > HISTORY_MAX_POINTS * 3 // 2:
            HISTORY_FILE.write_text("\n".join(lines[-HISTORY_MAX_POINTS:]) + "\n", encoding="utf-8")
    except OSError:
        pass


def read_history() -> list:
    try:
        lines = HISTORY_FILE.read_text(encoding="utf-8").splitlines()[-HISTORY_MAX_POINTS:]
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def read_mods() -> list:
    mods = []
    try:
        for raw in WORKSHOP_CFG.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            mods.append(line)
    except OSError:
        pass
    return mods


def read_log_tail(n=80) -> str:
    try:
        return "\n".join(MONITOR_LOG.read_text(encoding="utf-8", errors="replace").splitlines()[-n:])
    except OSError:
        return "(monitor.log not found yet)"


def start_job(name: str):
    with JOB_LOCK:
        if not JOB["done"]:
            return False
        JOB.update(name=name, started=time.time(), done=False, rc=0, output="")
    threading.Thread(target=_run_job, args=(name,), daemon=True).start()
    return True


def _run_job(name: str):
    rc, out = run_manager(name)
    with JOB_LOCK:
        JOB.update(done=True, rc=rc, output=out[-4000:])


# --- authentication ----------------------------------------------------------
app = Dash(__name__, title="DayZ Server Manager")
server = app.server
server.secret_key = os.environ.get("DAYZWEB_SECRET") or secrets.token_hex(16)

LOGIN_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>DayZ Server Manager - login</title></head>
<body style="font-family: sans-serif; background: #1a1b1e; color: #c1c2c5; padding: 3rem;">
  <div style="max-width: 22rem; margin: 10vh auto; background: #25262b; padding: 2rem; border-radius: 0.5rem;">
    <h2>DayZ Server Manager</h2>
    <form method="post">
      <input name="token" type="password" placeholder="access token"
             style="width: 100%; padding: 0.6rem; margin: 0.5rem 0; border-radius: 0.25rem; border: 1px solid #373a40; background: #1a1b1e; color: #c1c2c5;">
      <button type="submit" style="width: 100%; padding: 0.6rem; border: 0; border-radius: 0.25rem; background: #228be6; color: white;">
        Sign in
      </button>
    </form>
    {{ERROR}}
  </div>
</body></html>
"""

PUBLIC_PATHS = ("/login", "/favicon.ico")


@server.before_request
def _guard():
    from flask import redirect, request, session

    path = request.path
    if path.startswith(PUBLIC_PATHS) or path.startswith("/assets") \
            or path.startswith("/_dash-component-suites"):
        return None
    if not TOKEN:
        return None  # localhost-only mode
    supplied = request.args.get("token", "")
    if supplied and hmac.compare_digest(supplied, TOKEN):
        session["auth"] = True
    header = request.headers.get("Authorization", "")
    authed = session.get("auth") is True or hmac.compare_digest(header, "Bearer " + TOKEN)
    if authed:
        return None
    return redirect("/login")


@server.route("/login", methods=["GET", "POST"])
def _login():
    from flask import redirect, request, session

    if not TOKEN:
        return redirect("/")
    error = ""
    if request.method == "POST":
        if hmac.compare_digest(request.form.get("token", ""), TOKEN):
            session["auth"] = True
            return redirect("/")
        error = "<p style='color: #fa5252;'>Invalid token.</p>"
    return LOGIN_PAGE.replace("{{ERROR}}", error)


# --- layout ------------------------------------------------------------------
def stat_card(title: str, comp_id: str):
    return dmc.Paper(
        [
            dmc.Text(title, size="sm", style={"color": "#909296"}),
            dmc.Text(id=comp_id, size="xl", style={"fontWeight": 700}),
        ],
        p="md",
        radius="md",
        withBorder=True,
    )


layout = dmc.MantineProvider(
    dmc.Container(
        [
            html.Div(
                [
                    dmc.Title("DayZ Server Manager", order=2),
                    dmc.Badge(id="state-badge", children="...", color="gray"),
                ],
                style={"display": "flex", "justifyContent": "space-between", "alignItems": "center"},
            ),
            dmc.Text(id="status-line", size="sm", style={"color": "#909296"}, mt=4),
            dmc.SimpleGrid(
                cols=4,
                mt="md",
                children=[
                    stat_card("State", "card-state"),
                    stat_card("Uptime", "card-uptime"),
                    stat_card("Build", "card-build"),
                    stat_card("Players", "card-players"),
                    stat_card("Mods", "card-mods"),
                    stat_card("Mod updates", "card-updates"),
                    stat_card("Last exit", "card-exit"),
                    stat_card("Game port", "card-port"),
                ],
            ),
            dmc.Paper(
                [
                    dmc.Title("Players (recent)", order=4),
                    dcc.Graph(id="players-chart"),
                ],
                p="md",
                radius="md",
                withBorder=True,
                mt="md",
            ),
            dmc.SimpleGrid(
                cols=2,
                mt="md",
                children=[
                    dmc.Paper(
                        [
                            dmc.Title("Configured mods", order=4),
                            dmc.ScrollArea(
                                dmc.Table(
                                    html.Tbody(id="mods-table"),
                                    highlightOnHover=True,
                                ),
                                style={"height": 280},
                            ),
                        ],
                        p="md",
                        radius="md",
                        withBorder=True,
                    ),
                    dmc.Paper(
                        [
                            dmc.Title("Recent events (monitor.log)", order=4),
                            dmc.ScrollArea(
                                html.Pre(
                                    id="log-tail",
                                    style={"whiteSpace": "pre-wrap", "fontSize": "0.8rem"},
                                ),
                                style={"height": 280},
                            ),
                        ],
                        p="md",
                        radius="md",
                        withBorder=True,
                    ),
                ],
            ),
            dmc.Paper(
                [
                    dmc.Title("Actions", order=4),
                    dmc.Text(
                        "These run the same main.sh commands as the CLI; one action at a time.",
                        size="sm",
                        style={"color": "#909296"},
                    ),
                    dmc.Group(
                        mt="sm",
                        children=[
                            dmc.Button("Start", id="btn-start", color="green"),
                            dmc.Button("Stop", id="btn-stop", color="red"),
                            dmc.Button("Restart", id="btn-restart", color="orange"),
                            dmc.Button("Update", id="btn-update"),
                            dmc.Button("Validate", id="btn-validate", variant="outline"),
                            dmc.Button("Workshop sync", id="btn-workshop", variant="outline"),
                            dmc.Button("Check mod updates", id="btn-checkmods", variant="outline"),
                            dmc.Button("Backup", id="btn-backup", variant="outline"),
                        ],
                    ),
                    html.Div(id="action-alert", style={"marginTop": "0.75rem"}),
                ],
                p="md",
                radius="md",
                withBorder=True,
                mt="md",
            ),
            dcc.Interval(id="refresh-tick", interval=REFRESH_SECONDS * 1000),
            dcc.Store(id="job-store"),
        ],
        size="xl",
        py="md",
    )
)

app.layout = layout


# --- callbacks ---------------------------------------------------------------
def build_chart(history: list):
    fig = go.Figure()
    if history:
        xs = [time.strftime("%H:%M", time.localtime(e["ts"])) for e in history]
        ys = [e.get("players") or 0 for e in history]
        fig.add_trace(
            go.Scatter(x=xs, y=ys, mode="lines", name="players", fill="tozeroy",
                       line=dict(width=2, color="#228be6"))
        )
    fig.update_layout(
        height=260,
        margin=dict(l=30, r=10, t=10, b=30),
        paper_bgcolor="rgba(0,0,0,0)",
        plot_bgcolor="rgba(0,0,0,0)",
        showlegend=False,
    )
    return fig


def fmt_uptime(seconds) -> str:
    try:
        seconds = int(seconds or 0)
    except (TypeError, ValueError):
        return "-"
    return "%dh %dm" % (seconds // 3600, (seconds % 3600) // 60)


@app.callback(
    Output("state-badge", "children"),
    Output("state-badge", "color"),
    Output("card-state", "children"),
    Output("card-uptime", "children"),
    Output("card-build", "children"),
    Output("card-players", "children"),
    Output("card-mods", "children"),
    Output("card-updates", "children"),
    Output("card-exit", "children"),
    Output("card-port", "children"),
    Output("status-line", "children"),
    Output("players-chart", "figure"),
    Output("mods-table", "children"),
    Output("log-tail", "children"),
    Output("action-alert", "children"),
    Input("refresh-tick", "n_intervals"),
)
def refresh(_n):
    status = fetch_status()
    record_history(status)

    running = bool(status.get("running"))
    badge = ("running", "green") if running else ("stopped", "red")
    if "error" in status:
        badge = ("status error", "orange")

    mods = read_mods()
    mod_rows = [html.Tr([html.Td(line)]) for line in mods] or [html.Tr([html.Td("(none)")])]

    alert = []
    with JOB_LOCK:
        job = dict(JOB)
    if job["name"]:
        if not job["done"]:
            elapsed = int(time.time() - job["started"])
            alert = [dmc.Alert(
                "Running '%s' for %ds..." % (job["name"], elapsed),
                title="Action in progress", color="blue")]
        else:
            tail = job["output"][-1500:]
            alert = [dmc.Alert(
                html.Pre(tail, style={"whiteSpace": "pre-wrap", "margin": 0}),
                title="%s finished (rc=%s)" % (job["name"], job["rc"]),
                color="green" if job["rc"] == 0 else "red")]

    return (
        badge[0],
        badge[1],
        "running" if running else "stopped",
        fmt_uptime(status.get("uptime_seconds")) if running else "-",
        str(status.get("build") or "unknown"),
        str(status.get("players") if status.get("players") is not None else "-"),
        str(status.get("mod_count", 0)),
        "pending" if status.get("update_pending") else "up to date",
        str(status.get("last_exit_code") or "-"),
        str(status.get("port") or "-"),
        "manager v%s - as of %s" % (status.get("version", "?"), time.strftime("%H:%M:%S")),
        build_chart(read_history()),
        mod_rows,
        read_log_tail(),
        alert,
    )


@app.callback(
    Output("job-store", "data"),
    [Input(btn, "n_clicks") for btn in ACTIONS],
    prevent_initial_call=True,
)
def on_action(*_clicks):
    ctx = callback_context
    if not ctx.triggered:
        return {}
    btn_id = ctx.triggered[0]["prop_id"].split(".")[0]
    name = ACTIONS.get(btn_id)
    if not name:
        return {}
    started = start_job(name)
    return {"name": name, "started": started, "ts": time.time()}


# --- entry point -------------------------------------------------------------
def main():
    run = getattr(app, "run", None) or app.run_server
    print("DayZ web GUI on http://%s:%s (token auth: %s)"
          % (BIND, PORT, "on" if TOKEN else "off (localhost only)"))
    run(host=BIND, port=PORT, debug=False)


if __name__ == "__main__":
    main()
