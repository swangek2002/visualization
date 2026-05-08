#!/bin/bash
# ============================================================
# VNC Manager — called by Flask API, all operations non-blocking
# ============================================================
# Usage:
#   ./vnc_manager.sh start COMPUTE_NODE APP   — full setup (deploy + VNC + tunnel + websockify)
#   ./vnc_manager.sh switch APP               — switch app on existing session
#   ./vnc_manager.sh stop                     — tear down everything
#   ./vnc_manager.sh status                   — print current state
# ============================================================

ACTION=${1:?"Usage: vnc_manager.sh {start|switch|stop|status} [args...]"}

PROJECT_DIR="/home/swangek/visualization"
STATE_FILE="${PROJECT_DIR}/.vnc_state.json"
LOG_FILE="${PROJECT_DIR}/.vnc_manager.log"
VNC_DISPLAY=1
VNC_PORT=$((5900 + VNC_DISPLAY))
LOCAL_VNC_PORT=5901
WEBSOCKET_PORT=6080

# Redirect all output to log
exec > >(tee -a "${LOG_FILE}") 2>&1
echo ""
echo "=== $(date) === vnc_manager.sh ${@} ==="

resolve_app() {
    local app=$1
    case ${app} in
      slicer)
        APP_LABEL="3D Slicer 5.8.1"
        APP_CMD="/nas/longleaf/rhel9/apps/slicer/5.8.1/Slicer"
        APP_WINDOW="Slicer"
        ;;
      fsleyes)
        APP_LABEL="FSLeyes (FSL 6.0.7)"
        APP_CMD="source /nas/longleaf/rhel9/apps/fsl/6.0.7/fsl/etc/fslconf/fsl.sh; /nas/longleaf/rhel9/apps/fsl/6.0.7/fsl/bin/fsleyes"
        APP_WINDOW="FSLeyes"
        ;;
      freeview)
        APP_LABEL="Freeview (FreeSurfer 8.2.0)"
        APP_CMD="export FREESURFER_HOME=/nas/longleaf/apps/freesurfer/8.2.0/freesurfer; source /nas/longleaf/apps/freesurfer/8.2.0/freesurfer/SetUpFreeSurfer.sh; /nas/longleaf/apps/freesurfer/8.2.0/freesurfer/bin/freeview"
        APP_WINDOW="freeview"
        ;;
      itksnap)
        APP_LABEL="ITK-SNAP 4.2.2"
        APP_CMD="/nas/longleaf/apps/itksnap/4.2.2/bin/itksnap"
        APP_WINDOW="ITK-SNAP"
        ;;
      desktop)
        APP_LABEL="Longleaf Desktop"
        APP_CMD="xfce4-session || /etc/X11/xinit/xinitrc || xterm"
        APP_WINDOW="Desktop"
        ;;
      *)
        echo "ERROR: Unknown app '${app}'"
        exit 1
        ;;
    esac
}

deploy_and_start_vnc() {
    local node=$1
    local app=$2
    resolve_app "${app}"

    local escaped_cmd=$(printf '%s' "${APP_CMD}" | sed "s/'/'\\\\''/g")
    local escaped_win=$(printf '%s' "${APP_WINDOW}" | sed "s/'/'\\\\''/g")

    echo "[1/4] Deploying scripts to Longleaf for ${APP_LABEL}..."
    ssh longleaf "mkdir -p ~/.vnc"

    # Deploy maximize script via stdin pipe (avoids quoting issues with regex)
    cat << 'PYEOF' | ssh longleaf "cat > ~/.vnc/maximize_app.py"
#!/usr/bin/env python3
"""Continuously monitor screen size and keep target window fullscreen."""
import subprocess, time, sys, os

TARGET = sys.argv[1] if len(sys.argv) > 1 else 'Slicer'
XDOTOOL = os.path.expanduser('~/miniconda3/bin/xdotool')

def get_screen_size():
    try:
        r = subprocess.run(['xdpyinfo'], capture_output=True, text=True, timeout=3)
        for line in r.stdout.split('\n'):
            if 'dimensions:' in line:
                dim = line.split(':')[1].strip().split()[0]
                w, h = dim.split('x')
                return int(w), int(h)
    except: pass
    return 1920, 1080

def find_best_window():
    try:
        r = subprocess.run([XDOTOOL, 'search', '--name', TARGET],
                          capture_output=True, text=True, timeout=5)
        wids = [w.strip() for w in r.stdout.strip().split('\n') if w.strip()]
        if not wids: return None
        best_wid, best_area = None, 0
        for wid in wids:
            try:
                g = subprocess.run([XDOTOOL, 'getwindowgeometry', '--shell', wid],
                                  capture_output=True, text=True, timeout=3)
                info = dict(line.split('=', 1) for line in g.stdout.strip().split('\n') if '=' in line)
                area = int(info.get('WIDTH', 0)) * int(info.get('HEIGHT', 0))
                if area > best_area: best_area, best_wid = area, wid
            except: pass
        return best_wid
    except: return None

def maximize_to(wid, w, h):
    try:
        subprocess.run(['xprop', '-id', wid, '-f', '_MOTIF_WM_HINTS', '32c',
                       '-set', '_MOTIF_WM_HINTS', '2, 0, 0, 0, 0'],
                      capture_output=True, timeout=3)
    except: pass
    try:
        subprocess.run([XDOTOOL, 'windowmove', wid, '0', '0'],
                      capture_output=True, timeout=5)
    except: pass
    try:
        subprocess.run([XDOTOOL, 'windowsize', wid, str(w), str(h)],
                      capture_output=True, timeout=5)
    except: pass
    try:
        subprocess.run([XDOTOOL, 'windowactivate', wid],
                      capture_output=True, timeout=3)
    except: pass

def main():
    wid = None
    for _ in range(60):
        wid = find_best_window()
        if wid: break
        time.sleep(1)
    if not wid: return

    w, h = get_screen_size()
    maximize_to(wid, w, h)
    time.sleep(2)
    maximize_to(wid, w, h)

    last_w, last_h = w, h
    while True:
        time.sleep(3)
        try:
            w, h = get_screen_size()
            if w != last_w or h != last_h:
                wid = find_best_window() or wid
                maximize_to(wid, w, h)
                time.sleep(1)
                maximize_to(wid, w, h)
                last_w, last_h = w, h
        except: pass

if __name__ == '__main__': main()
PYEOF

    # Deploy xstartup and empty WM script (no window manager = no decorations)
    # App runs in background (&) so xstartup stays alive via "exec sleep infinity"
    # This keeps VNC running even when apps are killed/switched
    ssh longleaf "cat > ~/.vnc/app_xstartup.sh << 'XEOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
python3 ~/.vnc/maximize_app.py '${escaped_win}' &
${escaped_cmd} &
# Keep VNC alive indefinitely — apps are managed separately
exec sleep infinity
XEOF
chmod +x ~/.vnc/app_xstartup.sh
echo '#!/bin/sh
# Empty WM - exits immediately so TurboVNC has no window manager (no decorations)
exit 0' > ~/.vnc/nowm.sh
chmod +x ~/.vnc/nowm.sh"

    echo "[2/4] Starting VNC on ${node}:${VNC_DISPLAY}..."
    ssh longleaf "ssh ${node} '
      # Kill any existing VNC and all app processes
      /opt/TurboVNC/bin/vncserver -kill :${VNC_DISPLAY} 2>/dev/null || true
      pkill -u \$(whoami) -x Xvnc 2>/dev/null || true
      for p in freeview ITK-SNAP SlicerApp-real Slicer xfce4-session; do pkill -u \$(whoami) -x \$p 2>/dev/null; done
      pkill -u \$(whoami) -f \"fsleyes|maximize_app.py\" 2>/dev/null || true
      # Clean ALL stale lock/pid files from crashed sessions
      rm -f /tmp/.X${VNC_DISPLAY}-lock /tmp/.X11-unix/X${VNC_DISPLAY} ~/.vnc/*.pid 2>/dev/null
      sleep 2
      /opt/TurboVNC/bin/vncserver :${VNC_DISPLAY} -geometry 1920x1080 -depth 24 -noautokill -wm ~/.vnc/nowm.sh -xstartup ~/.vnc/app_xstartup.sh
    '"

    echo "[3/4] SSH tunnel: localhost:${LOCAL_VNC_PORT} → ${node}:${VNC_PORT}..."
    # Kill old tunnel first
    lsof -ti:${LOCAL_VNC_PORT} 2>/dev/null | xargs kill 2>/dev/null || true
    sleep 0.5
    ssh -f -N -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
        -L ${LOCAL_VNC_PORT}:${node}:${VNC_PORT} longleaf

    echo "[4/4] Starting websockify in background..."
    # Kill old websockify first
    lsof -ti:${WEBSOCKET_PORT} 2>/dev/null | xargs kill 2>/dev/null || true
    sleep 0.5
    # Start websockify using absolute path (conda activate unreliable in subprocess)
    WEBSOCKIFY="/Data0/swangek_data/conda_envs/survivehr/bin/websockify"
    nohup ${WEBSOCKIFY} --web=${PROJECT_DIR}/novnc ${WEBSOCKET_PORT} localhost:${LOCAL_VNC_PORT} \
        >> "${PROJECT_DIR}/.websockify.log" 2>&1 &
    WSOCK_PID=$!
    echo "  websockify PID: ${WSOCK_PID}"

    # Wait briefly and check it's actually running
    sleep 1
    if kill -0 ${WSOCK_PID} 2>/dev/null; then
        echo "  websockify running OK"
    else
        echo "  WARNING: websockify may have failed, check .websockify.log"
    fi

    # Save state
    cat > "${STATE_FILE}" << SEOF
{
  "compute_node": "${node}",
  "vnc_display": ${VNC_DISPLAY},
  "vnc_port": ${VNC_PORT},
  "local_vnc_port": ${LOCAL_VNC_PORT},
  "websocket_port": ${WEBSOCKET_PORT},
  "app": "${app}",
  "app_label": "${APP_LABEL}",
  "websockify_pid": ${WSOCK_PID}
}
SEOF
    echo "DONE: ${APP_LABEL} on ${node}:${VNC_DISPLAY}, ws://localhost:${WEBSOCKET_PORT}"
}

switch_app() {
    local app=$1
    if [ ! -f "${STATE_FILE}" ]; then
        echo "ERROR: No VNC session. Run 'start' first."
        exit 1
    fi
    local node=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['compute_node'])")
    resolve_app "${app}"

    local escaped_cmd=$(printf '%s' "${APP_CMD}" | sed "s/'/'\\\\''/g")
    local escaped_win=$(printf '%s' "${APP_WINDOW}" | sed "s/'/'\\\\''/g")

    echo "Switching to ${APP_LABEL} on ${node}..."
    echo "  Strategy: keep VNC/tunnel/websockify alive, only swap the application"

    # maximize_app.py is already deployed by start — no need to redeploy on switch

    # === KEY CHANGE: Don't restart VNC! Just kill old app and start new one ===
    # Step 1: Write a launch script to longleaf (avoids nested SSH quoting issues)
    cat << LAUNCHEOF | ssh longleaf "cat > ~/.vnc/launch_app.sh && chmod +x ~/.vnc/launch_app.sh"
#!/bin/bash
export DISPLAY=:${VNC_DISPLAY}
# Kill old apps (exact match — never kills Xvnc or sleep)
for p in freeview ITK-SNAP SlicerApp-real Slicer xfce4-session; do
  pkill -u \$(whoami) -x \$p 2>/dev/null
done
pkill -u \$(whoami) -f "fsleyes|maximize_app.py" 2>/dev/null
sleep 1
# Start new app + maximize in background (VNC stays alive via sleep infinity in xstartup)
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
python3 ~/.vnc/maximize_app.py '${APP_WINDOW}' &
${APP_CMD} &
LAUNCHEOF

    # Step 2: Execute the launch script on the compute node via SSH
    ssh longleaf "ssh ${node} 'nohup bash ~/.vnc/launch_app.sh > /tmp/vnc_app.log 2>&1 &'"
    echo "  App launched on ${node}"

    # Verify tunnel and websockify are still alive; rebuild only if dead
    if ! lsof -ti:${LOCAL_VNC_PORT} > /dev/null 2>&1; then
        echo "  SSH tunnel dead — rebuilding..."
        ssh -f -N -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
            -L ${LOCAL_VNC_PORT}:${node}:${VNC_PORT} longleaf
    else
        echo "  SSH tunnel alive — keeping it"
    fi

    if ! lsof -ti:${WEBSOCKET_PORT} > /dev/null 2>&1; then
        echo "  websockify dead — rebuilding..."
        WEBSOCKIFY="/Data0/swangek_data/conda_envs/survivehr/bin/websockify"
        nohup ${WEBSOCKIFY} --web=${PROJECT_DIR}/novnc ${WEBSOCKET_PORT} localhost:${LOCAL_VNC_PORT} \
            >> "${PROJECT_DIR}/.websockify.log" 2>&1 &
        WSOCK_PID=$!
        sleep 1
        python3 -c "
import json
s = json.load(open('${STATE_FILE}'))
s['app'] = '${app}'
s['app_label'] = '${APP_LABEL}'
s['websockify_pid'] = ${WSOCK_PID}
json.dump(s, open('${STATE_FILE}', 'w'), indent=2)
"
    else
        echo "  websockify alive — keeping it"
        python3 -c "
import json
s = json.load(open('${STATE_FILE}'))
s['app'] = '${app}'
s['app_label'] = '${APP_LABEL}'
json.dump(s, open('${STATE_FILE}', 'w'), indent=2)
"
    fi

    echo "DONE: Switched to ${APP_LABEL}"
}

stop_all() {
    echo "Stopping VNC session..."
    # Kill websockify
    lsof -ti:${WEBSOCKET_PORT} 2>/dev/null | xargs kill 2>/dev/null || true
    # Kill SSH tunnel
    lsof -ti:${LOCAL_VNC_PORT} 2>/dev/null | xargs kill 2>/dev/null || true
    # Kill VNC on compute node
    if [ -f "${STATE_FILE}" ]; then
        local node=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['compute_node'])")
        ssh longleaf "ssh ${node} '/opt/TurboVNC/bin/vncserver -kill :${VNC_DISPLAY} 2>/dev/null || true'" 2>/dev/null || true
        rm -f "${STATE_FILE}"
    fi
    echo "DONE: All stopped"
}

print_status() {
    if [ -f "${STATE_FILE}" ]; then
        cat "${STATE_FILE}"
    else
        echo '{"error": "No VNC session active"}'
    fi
}

case ${ACTION} in
  start)
    COMPUTE_NODE=${2:?"Error: start requires COMPUTE_NODE"}
    APP=${3:-slicer}
    deploy_and_start_vnc "${COMPUTE_NODE}" "${APP}"
    ;;
  switch)
    APP=${2:?"Error: switch requires APP name"}
    switch_app "${APP}"
    ;;
  stop)
    stop_all
    ;;
  status)
    print_status
    ;;
  *)
    echo "Usage: vnc_manager.sh {start|switch|stop|status} [args...]"
    exit 1
    ;;
esac
