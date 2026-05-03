#!/bin/bash
cd /home/swangek/visualization

# Use Flask backend if available, fall back to simple http.server
if python3 -c "import flask" 2>/dev/null; then
    echo "Starting Flask backend..."
    python3 server.py "${1:-8080}"
else
    echo "Flask not available, falling back to simple HTTP server"
    echo "Install Flask for full features: pip3 install --user flask"
    echo "Server running at http://localhost:${1:-8080}"
    echo "Press Ctrl+C to stop"
    python3 -m http.server "${1:-8080}"
fi
