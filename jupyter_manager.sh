#!/bin/bash
# Jupyter manager — starts/stops JupyterLab on a Longleaf compute node + SSH tunnel
# Usage:
#   ./jupyter_manager.sh start COMPUTE_NODE  — start Jupyter + tunnel
#   ./jupyter_manager.sh stop                — tear down
#   ./jupyter_manager.sh status              — print state

ACTION=${1:?"Usage: jupyter_manager.sh {start|stop|status} [compute_node]"}

PROJECT_DIR="/home/swangek/visualization"
STATE_FILE="${PROJECT_DIR}/.jupyter_state.json"
LOG_FILE="${PROJECT_DIR}/.jupyter_manager.log"
JUPYTER_PORT_REMOTE=8888
JUPYTER_PORT_LOCAL=6081

exec > >(tee -a "${LOG_FILE}") 2>&1
echo ""
echo "=== $(date) === jupyter_manager.sh ${@} ==="

start_jupyter() {
    local node=$1
    local token=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 24)

    echo "[1/3] Deploying Jupyter launch script to Longleaf..."
    cat << REMEOF | ssh longleaf "cat > ~/.vnc/start_jupyter.sh && chmod +x ~/.vnc/start_jupyter.sh"
#!/bin/bash
# Runs on compute node. Starts JupyterLab in neuroviz env.
TOKEN="\$1"
pkill -u \$(whoami) -f "jupyter-lab" 2>/dev/null || true
sleep 1
source /nas/longleaf/rhel9/apps/anaconda/2024.02/etc/profile.d/conda.sh 2>/dev/null || true
conda activate neuroviz 2>&1 || { echo "FATAL: cannot activate neuroviz conda env" >&2; exit 1; }
cd ~
nohup jupyter lab --no-browser --ip 0.0.0.0 --port ${JUPYTER_PORT_REMOTE} \\
    --IdentityProvider.token="\$TOKEN" \\
    --ServerApp.password="" \\
    --ServerApp.disable_check_xsrf=True \\
    --ServerApp.allow_origin='*' \\
    --ServerApp.base_url=/jlab/ \\
    --ServerApp.tornado_settings='{"headers":{"Content-Security-Policy":"frame-ancestors *"}}' \\
    > /tmp/jupyter.log 2>&1 &
# Wait up to 30s for Jupyter to start listening
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 2
    if ss -tln 2>/dev/null | grep -q ":${JUPYTER_PORT_REMOTE} "; then
        echo "Jupyter listening on :${JUPYTER_PORT_REMOTE} (after \${i}*2s)"
        exit 0
    fi
done
echo "FATAL: Jupyter failed to start within 30s" >&2
tail -30 /tmp/jupyter.log >&2
exit 1
REMEOF

    echo "[2/3] Starting JupyterLab on ${node}..."
    ssh -n longleaf "ssh ${node} 'bash ~/.vnc/start_jupyter.sh \"${token}\"'"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to start Jupyter on ${node}"
        exit 1
    fi

    echo "[3/3] SSH tunnel: localhost:${JUPYTER_PORT_LOCAL} → ${node}:${JUPYTER_PORT_REMOTE}..."
    lsof -ti:${JUPYTER_PORT_LOCAL} 2>/dev/null | xargs kill 2>/dev/null || true
    sleep 0.5
    ssh -f -N -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
        -L *:${JUPYTER_PORT_LOCAL}:${node}:${JUPYTER_PORT_REMOTE} longleaf

    cat > "${STATE_FILE}" << SEOF
{
  "compute_node": "${node}",
  "remote_port": ${JUPYTER_PORT_REMOTE},
  "local_port": ${JUPYTER_PORT_LOCAL},
  "token": "${token}"
}
SEOF
    echo "DONE: JupyterLab ready at http://localhost:${JUPYTER_PORT_LOCAL}/lab?token=${token}"
}

stop_jupyter() {
    echo "Stopping Jupyter..."
    if [ -f "${STATE_FILE}" ]; then
        local node=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['compute_node'])")
        ssh -n longleaf "ssh ${node} 'pkill -u \$(whoami) -f jupyter-lab 2>/dev/null || true'" 2>/dev/null || true
        rm -f "${STATE_FILE}"
    fi
    lsof -ti:${JUPYTER_PORT_LOCAL} 2>/dev/null | xargs kill 2>/dev/null || true
    echo "DONE: Jupyter stopped"
}

print_status() {
    if [ -f "${STATE_FILE}" ]; then
        cat "${STATE_FILE}"
    else
        echo '{"error": "No Jupyter session"}'
    fi
}

case ${ACTION} in
  start)
    NODE=${2:?"Error: start requires COMPUTE_NODE"}
    start_jupyter "${NODE}"
    ;;
  stop)
    stop_jupyter
    ;;
  status)
    print_status
    ;;
esac
