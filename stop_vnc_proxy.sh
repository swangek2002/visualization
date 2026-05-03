#!/bin/bash
# Stop VNC proxy: kill SSH tunnel and websockify

LOCAL_VNC_PORT=${1:-5901}
WEBSOCKET_PORT=${2:-6080}

echo "Stopping VNC proxy..."

if lsof -ti:${WEBSOCKET_PORT} >/dev/null 2>&1; then
    kill $(lsof -ti:${WEBSOCKET_PORT}) 2>/dev/null
    echo "  Stopped websockify on port ${WEBSOCKET_PORT}"
else
    echo "  No websockify on port ${WEBSOCKET_PORT}"
fi

if lsof -ti:${LOCAL_VNC_PORT} >/dev/null 2>&1; then
    kill $(lsof -ti:${LOCAL_VNC_PORT}) 2>/dev/null
    echo "  Stopped SSH tunnel on port ${LOCAL_VNC_PORT}"
else
    echo "  No SSH tunnel on port ${LOCAL_VNC_PORT}"
fi

echo "Done."
