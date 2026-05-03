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
        APP_CMD="export FREESURFER_HOME=/nas/longleaf/apps/freesurfer/8.2.0/freesurfer; source \$FREESURFER_HOME/SetUpFreeSurfer.sh; /nas/longleaf/apps/freesurfer/8.2.0/freesurfer/bin/freeview"
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
    ssh longleaf "mkdir -p ~/.vnc

cat > ~/.vnc/maximize_app.py << 'PYEOF'
#!/usr/bin/env python3
import ctypes, ctypes.util, subprocess, time, sys
TARGET = sys.argv[1] if len(sys.argv) > 1 else 'Slicer'
def main():
    libname = ctypes.util.find_library('X11') or '/usr/lib64/libX11.so.6'
    x11 = ctypes.cdll.LoadLibrary(libname)
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XMoveResizeWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint]
    x11.XMoveResizeWindow.restype = ctypes.c_int
    dpy = x11.XOpenDisplay(None)
    if not dpy: return
    for _ in range(120):
        try:
            r = subprocess.run(['xwininfo', '-root', '-tree'], capture_output=True, text=True, timeout=5)
            for line in r.stdout.split('\n'):
                if '0x' in line and TARGET in line:
                    wid_str = line.strip().split()[0]
                    if wid_str.startswith('0x'):
                        wid = int(wid_str, 16)
                        x11.XMoveResizeWindow(dpy, wid, 0, 0, 1920, 1080)
                        x11.XFlush(dpy)
                        return
        except: pass
        time.sleep(1)
if __name__ == '__main__': main()
PYEOF

cat > ~/.vnc/app_xstartup.sh << 'XEOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
python3 ~/.vnc/maximize_app.py '${escaped_win}' &
${escaped_cmd}
XEOF
chmod +x ~/.vnc/app_xstartup.sh"

    echo "[2/4] Starting VNC on ${node}:${VNC_DISPLAY}..."
    ssh longleaf "ssh ${node} '
      /opt/TurboVNC/bin/vncserver -kill :${VNC_DISPLAY} 2>/dev/null || true
      sleep 1
      /opt/TurboVNC/bin/vncserver :${VNC_DISPLAY} -geometry 1920x1080 -depth 24 -xstartup ~/.vnc/app_xstartup.sh
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

    ssh longleaf "cat > ~/.vnc/app_xstartup.sh << 'XEOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
python3 ~/.vnc/maximize_app.py '${escaped_win}' &
${escaped_cmd}
XEOF
chmod +x ~/.vnc/app_xstartup.sh"

    ssh longleaf "ssh ${node} '
      /opt/TurboVNC/bin/vncserver -kill :${VNC_DISPLAY} 2>/dev/null || true
      sleep 1
      /opt/TurboVNC/bin/vncserver :${VNC_DISPLAY} -geometry 1920x1080 -depth 24 -xstartup ~/.vnc/app_xstartup.sh
    '"

    # Update state
    python3 -c "
import json
s = json.load(open('${STATE_FILE}'))
s['app'] = '${app}'
s['app_label'] = '${APP_LABEL}'
json.dump(s, open('${STATE_FILE}', 'w'), indent=2)
"
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
