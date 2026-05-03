#!/bin/bash
# ============================================================
# VNC Proxy: frontier → Longleaf (SSH tunnel + websockify)
# Multi-App Mode — launches selected application fullscreen
# ============================================================
# Usage:
#   ./start_vnc_proxy.sh COMPUTE_NODE [APP] [VNC_DISPLAY] [WEBSOCKET_PORT]
#
# APP options: slicer (default), fsleyes, freeview, itksnap, desktop
#
# Examples:
#   ./start_vnc_proxy.sh c1234                  # default: 3D Slicer
#   ./start_vnc_proxy.sh c1234 fsleyes          # FSLeyes (FSL)
#   ./start_vnc_proxy.sh c1234 freeview         # FreeSurfer Freeview
#   ./start_vnc_proxy.sh c1234 itksnap          # ITK-SNAP
#   ./start_vnc_proxy.sh c1234 desktop          # Full Longleaf Desktop
#
# Prerequisites:
#   1. SSH key auth to longleaf configured (~/.ssh/config)
#   2. conda env 'survivehr' with websockify installed
#   3. VNC password already set on Longleaf (~/.vnc/passwd)
#   4. Active SLURM job on the compute node
# ============================================================

set -e

COMPUTE_NODE=${1:?"Error: Please provide Longleaf compute node name (e.g. c1234)"}
APP=${2:-slicer}
VNC_DISPLAY=${3:-1}
WEBSOCKET_PORT=${4:-6080}

VNC_PORT=$((5900 + VNC_DISPLAY))
LOCAL_VNC_PORT=5901

# Resolve application — using actual paths verified on Longleaf
case ${APP} in
  slicer)
    APP_LABEL="3D Slicer"
    APP_CMD="/nas/longleaf/rhel9/apps/slicer/5.8.1/Slicer"
    APP_WINDOW_NAME="Slicer"
    ;;
  fsleyes)
    APP_LABEL="FSLeyes (FSL 6.0.7)"
    # fsleyes needs FSLDIR set and some env setup from module
    APP_CMD="source /nas/longleaf/rhel9/apps/fsl/6.0.7/fsl/etc/fslconf/fsl.sh; /nas/longleaf/rhel9/apps/fsl/6.0.7/fsl/bin/fsleyes"
    APP_WINDOW_NAME="FSLeyes"
    ;;
  freeview)
    APP_LABEL="FreeSurfer Freeview 8.2.0"
    APP_CMD="export FREESURFER_HOME=/nas/longleaf/apps/freesurfer/8.2.0/freesurfer; source \$FREESURFER_HOME/SetUpFreeSurfer.sh; /nas/longleaf/apps/freesurfer/8.2.0/freesurfer/bin/freeview"
    APP_WINDOW_NAME="freeview"
    ;;
  itksnap)
    APP_LABEL="ITK-SNAP 4.2.2"
    APP_CMD="/nas/longleaf/apps/itksnap/4.2.2/bin/itksnap"
    APP_WINDOW_NAME="ITK-SNAP"
    ;;
  desktop)
    APP_LABEL="Longleaf Desktop"
    APP_CMD="xfce4-session || /etc/X11/xinit/xinitrc || xterm"
    APP_WINDOW_NAME="Desktop"
    ;;
  *)
    echo "Error: Unknown app '${APP}'."
    echo "Available: slicer, fsleyes, freeview, itksnap, desktop"
    exit 1
    ;;
esac

# Save VNC session state so Flask server can switch apps later
STATE_FILE="/home/swangek/visualization/.vnc_state.json"
cat > "${STATE_FILE}" << EOF
{
  "compute_node": "${COMPUTE_NODE}",
  "vnc_display": ${VNC_DISPLAY},
  "vnc_port": ${VNC_PORT},
  "websocket_port": ${WEBSOCKET_PORT},
  "app": "${APP}",
  "app_label": "${APP_LABEL}"
}
EOF

echo "================================================"
echo "  VNC Proxy Setup — ${APP_LABEL}"
echo "================================================"
echo "  Longleaf node:   ${COMPUTE_NODE}"
echo "  Application:     ${APP_LABEL}"
echo "  VNC display:     :${VNC_DISPLAY} (port ${VNC_PORT})"
echo "  Local VNC port:  ${LOCAL_VNC_PORT}"
echo "  WebSocket port:  ${WEBSOCKET_PORT}"
echo "================================================"

# Kill any existing SSH tunnel on the local VNC port
if lsof -ti:${LOCAL_VNC_PORT} >/dev/null 2>&1; then
    echo "Killing existing process on port ${LOCAL_VNC_PORT}..."
    kill $(lsof -ti:${LOCAL_VNC_PORT}) 2>/dev/null || true
    sleep 1
fi

# Kill any existing websockify on the WebSocket port
if lsof -ti:${WEBSOCKET_PORT} >/dev/null 2>&1; then
    echo "Killing existing process on port ${WEBSOCKET_PORT}..."
    kill $(lsof -ti:${WEBSOCKET_PORT}) 2>/dev/null || true
    sleep 1
fi

# 1. Deploy app-specific startup scripts to Longleaf NFS home
#    KEY FIX: Write the actual command directly into xstartup,
#    not via environment variable (which gets lost in SSH→SSH→VNC chain)
echo ""
echo "[1/4] Deploying startup scripts for ${APP_LABEL}..."

# Escape the command for embedding in heredoc
ESCAPED_CMD=$(printf '%s' "${APP_CMD}" | sed "s/'/'\\\\''/g")
ESCAPED_WINDOW=$(printf '%s' "${APP_WINDOW_NAME}" | sed "s/'/'\\\\''/g")

ssh longleaf "mkdir -p ~/.vnc

cat > ~/.vnc/maximize_app.py << 'PYEOF'
#!/usr/bin/env python3
\"\"\"Wait for application window and resize it to fill the VNC screen.\"\"\"
import ctypes, ctypes.util, subprocess, time, sys

TARGET = sys.argv[1] if len(sys.argv) > 1 else 'Slicer'

def main():
    libname = ctypes.util.find_library('X11') or '/usr/lib64/libX11.so.6'
    x11 = ctypes.cdll.LoadLibrary(libname)
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XMoveResizeWindow.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong,
        ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint
    ]
    x11.XMoveResizeWindow.restype = ctypes.c_int
    dpy = x11.XOpenDisplay(None)
    if not dpy:
        return
    for _ in range(120):
        try:
            r = subprocess.run(
                ['xwininfo', '-root', '-tree'],
                capture_output=True, text=True, timeout=5
            )
            for line in r.stdout.split('\n'):
                if '0x' in line and TARGET in line:
                    wid_str = line.strip().split()[0]
                    if wid_str.startswith('0x'):
                        wid = int(wid_str, 16)
                        x11.XMoveResizeWindow(dpy, wid, 0, 0, 1920, 1080)
                        x11.XFlush(dpy)
                        return
        except Exception:
            pass
        time.sleep(1)

if __name__ == '__main__':
    main()
PYEOF

cat > ~/.vnc/app_xstartup.sh << 'XEOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
# Auto-maximize the app window when it appears
python3 ~/.vnc/maximize_app.py '${ESCAPED_WINDOW}' &
# Start the application directly (hardcoded, not via env var)
${ESCAPED_CMD}
XEOF
chmod +x ~/.vnc/app_xstartup.sh"
echo "  Scripts deployed to ~/.vnc/ on Longleaf"

# 2. (Re)start VNC with the selected application
echo "[2/4] Starting VNC with ${APP_LABEL} on ${COMPUTE_NODE}:${VNC_DISPLAY}..."
ssh longleaf "ssh ${COMPUTE_NODE} '
  /opt/TurboVNC/bin/vncserver -kill :${VNC_DISPLAY} 2>/dev/null || true
  sleep 1
  /opt/TurboVNC/bin/vncserver :${VNC_DISPLAY} \
    -geometry 1920x1080 -depth 24 \
    -xstartup ~/.vnc/app_xstartup.sh
'"
echo "  VNC started — ${APP_LABEL} launching fullscreen on :${VNC_DISPLAY}"

# 3. Establish SSH tunnel
echo "[3/4] Creating SSH tunnel..."
ssh -f -N \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -L ${LOCAL_VNC_PORT}:${COMPUTE_NODE}:${VNC_PORT} \
    longleaf
echo "  SSH tunnel: localhost:${LOCAL_VNC_PORT} → ${COMPUTE_NODE}:${VNC_PORT}"

# 4. Start websockify
echo "[4/4] Starting websockify..."
echo "  WebSocket proxy: ws://localhost:${WEBSOCKET_PORT} → localhost:${LOCAL_VNC_PORT}"
echo ""
echo "================================================"
echo "  Ready! Open your browser and go to:"
echo "  http://localhost:8080 → Remote VNC tab → Connect"
echo "  Application: ${APP_LABEL}"
echo ""
echo "  Or directly: http://localhost:${WEBSOCKET_PORT}/vnc_lite.html"
echo "  Press Ctrl+C to stop"
echo "================================================"

# Activate conda and run websockify (foreground, so Ctrl+C stops it)
eval "$(conda shell.bash hook)"
conda activate survivehr
websockify --web=/home/swangek/visualization/novnc ${WEBSOCKET_PORT} localhost:${LOCAL_VNC_PORT}
