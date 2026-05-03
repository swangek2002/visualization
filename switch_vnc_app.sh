#!/bin/bash
# ============================================================
# Switch VNC application without restarting tunnel/websockify
# Called by Flask server when user changes app in the browser
# ============================================================
# Usage: ./switch_vnc_app.sh APP
# Reads compute node info from .vnc_state.json
# ============================================================

set -e

APP=${1:?"Error: Please provide app name (slicer, fsleyes, freeview, itksnap, desktop)"}
STATE_FILE="/home/swangek/visualization/.vnc_state.json"

if [ ! -f "${STATE_FILE}" ]; then
    echo "Error: No VNC session state found. Run start_vnc_proxy.sh first."
    exit 1
fi

# Read state
COMPUTE_NODE=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['compute_node'])")
VNC_DISPLAY=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['vnc_display'])")

# Resolve application command — same as start_vnc_proxy.sh
case ${APP} in
  slicer)
    APP_LABEL="3D Slicer"
    APP_CMD="/nas/longleaf/rhel9/apps/slicer/5.8.1/Slicer"
    APP_WINDOW_NAME="Slicer"
    ;;
  fsleyes)
    APP_LABEL="FSLeyes (FSL 6.0.7)"
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
    echo "Error: Unknown app '${APP}'"
    exit 1
    ;;
esac

echo "Switching VNC app to: ${APP_LABEL} on ${COMPUTE_NODE}:${VNC_DISPLAY}"

# Escape for heredoc
ESCAPED_CMD=$(printf '%s' "${APP_CMD}" | sed "s/'/'\\\\''/g")
ESCAPED_WINDOW=$(printf '%s' "${APP_WINDOW_NAME}" | sed "s/'/'\\\\''/g")

# 1. Write new xstartup with the selected app command
ssh longleaf "cat > ~/.vnc/app_xstartup.sh << 'XEOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
python3 ~/.vnc/maximize_app.py '${ESCAPED_WINDOW}' &
${ESCAPED_CMD}
XEOF
chmod +x ~/.vnc/app_xstartup.sh"

# 2. Kill existing VNC and restart with new app
ssh longleaf "ssh ${COMPUTE_NODE} '
  /opt/TurboVNC/bin/vncserver -kill :${VNC_DISPLAY} 2>/dev/null || true
  sleep 1
  /opt/TurboVNC/bin/vncserver :${VNC_DISPLAY} \
    -geometry 1920x1080 -depth 24 \
    -xstartup ~/.vnc/app_xstartup.sh
'"

# 3. Update state file
python3 -c "
import json
state = json.load(open('${STATE_FILE}'))
state['app'] = '${APP}'
state['app_label'] = '${APP_LABEL}'
json.dump(state, open('${STATE_FILE}', 'w'), indent=2)
"

echo "Done. ${APP_LABEL} is now running on ${COMPUTE_NODE}:${VNC_DISPLAY}"
