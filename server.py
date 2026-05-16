#!/usr/bin/env python3
"""
Flask backend for Universal Medical Image Viewer.
Replaces `python3 -m http.server` with:
  - Static file serving (index.html, verify/, novnc/)
  - Arbitrary server-path file serving with security whitelist
  - DICOM series conversion (via dcm2niix)
  - MINC→NIfTI conversion (via mnc2nii)
  - Directory listing for file browsing
"""

import os
import glob
import subprocess
import tempfile
import shutil
import json
from flask import Flask, send_from_directory, send_file, request, jsonify, abort

app = Flask(__name__)

# Security: only allow serving files under these prefixes
ALLOWED_PREFIXES = [
    '/Data0/swangek_data/',
    '/home/swangek/',
    '/tmp/',
]

# Paths to conversion tools (update if available on your system)
DCM2NIIX = shutil.which('dcm2niix') or 'dcm2niix'
MNC2NII = shutil.which('mnc2nii') or 'mnc2nii'

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))


def is_path_allowed(path):
    """Check if the absolute path is under an allowed prefix."""
    abspath = os.path.abspath(path)
    return any(abspath.startswith(p) for p in ALLOWED_PREFIXES)


# ── Static file serving ──

@app.route('/')
def index():
    return send_from_directory(PROJECT_DIR, 'index.html')


@app.route('/<path:path>')
def static_files(path):
    return send_from_directory(PROJECT_DIR, path)


# ── Serve files from arbitrary server paths ──

@app.route('/api/file')
def serve_file():
    """Serve a file from an absolute path on the server.
    Usage: /api/file?path=/Data0/swangek_data/some/file.nii.gz
    """
    path = request.args.get('path', '')
    if not path:
        return jsonify({'error': 'Missing path parameter'}), 400
    if not os.path.isabs(path):
        return jsonify({'error': 'Path must be absolute'}), 400
    if not is_path_allowed(path):
        return jsonify({'error': 'Access denied: path not in allowed directories'}), 403
    if not os.path.isfile(path):
        return jsonify({'error': 'File not found: ' + path}), 404
    return send_file(path)


# ── Directory listing ──

@app.route('/api/ls')
def list_directory():
    """List files in a directory, with optional glob filter.
    Usage: /api/ls?path=/Data0/swangek_data/&pattern=*.nii.gz
    """
    path = request.args.get('path', '')
    pattern = request.args.get('pattern', '*')
    if not path or not os.path.isabs(path):
        return jsonify({'error': 'Path must be absolute'}), 400
    if not is_path_allowed(path):
        return jsonify({'error': 'Access denied'}), 403
    if not os.path.isdir(path):
        return jsonify({'error': 'Not a directory'}), 404

    entries = []
    for name in sorted(os.listdir(path)):
        full = os.path.join(path, name)
        entry = {
            'name': name,
            'path': full,
            'isDir': os.path.isdir(full),
            'size': os.path.getsize(full) if os.path.isfile(full) else None,
        }
        # Apply pattern filter for files
        if not entry['isDir'] and pattern != '*':
            import fnmatch
            if not fnmatch.fnmatch(name, pattern):
                continue
        entries.append(entry)
    return jsonify(entries)


# ── DICOM series conversion ──

@app.route('/api/convert-dicom', methods=['POST'])
def convert_dicom():
    """Convert a DICOM directory to NIfTI using dcm2niix.
    POST body: { "path": "/absolute/path/to/dicom/dir" }
    Returns the first converted NIfTI file.
    """
    data = request.get_json(silent=True) or {}
    dicom_dir = data.get('path', '')
    if not dicom_dir or not os.path.isabs(dicom_dir):
        return jsonify({'error': 'Path must be absolute'}), 400
    if not is_path_allowed(dicom_dir):
        return jsonify({'error': 'Access denied'}), 403
    if not os.path.isdir(dicom_dir):
        return jsonify({'error': 'Not a directory: ' + dicom_dir}), 404

    tmpdir = tempfile.mkdtemp(prefix='dcm2nii_')
    try:
        result = subprocess.run(
            [DCM2NIIX, '-z', 'y', '-f', 'output_%s_%d', '-o', tmpdir, dicom_dir],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=120
        )
        if result.returncode != 0:
            return jsonify({
                'error': 'dcm2niix failed',
                'stderr': result.stderr,
                'stdout': result.stdout
            }), 500

        nifti_files = glob.glob(os.path.join(tmpdir, '*.nii.gz'))
        if not nifti_files:
            nifti_files = glob.glob(os.path.join(tmpdir, '*.nii'))
        if not nifti_files:
            return jsonify({
                'error': 'No NIfTI files produced',
                'stdout': result.stdout
            }), 500

        # Return file list if multiple, or single file
        if len(nifti_files) == 1:
            return send_file(nifti_files[0], mimetype='application/octet-stream',
                           as_attachment=True,
                           download_name=os.path.basename(nifti_files[0]))
        else:
            # Return JSON listing for multi-series
            return jsonify({
                'files': [os.path.basename(f) for f in nifti_files],
                'tmpdir': tmpdir,
                'message': 'Multiple series found. Use /api/file?path=<tmpdir>/<name> to download each.'
            })
    except FileNotFoundError:
        return jsonify({'error': 'dcm2niix not found. Install it or update DCM2NIIX path in server.py'}), 500
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'dcm2niix timed out'}), 500


# ── MINC conversion ──

@app.route('/api/convert-minc', methods=['POST'])
def convert_minc():
    """Convert a MINC file to NIfTI using mnc2nii.
    POST body: { "path": "/absolute/path/to/file.mnc" }
    Returns the converted NIfTI file.
    """
    data = request.get_json(silent=True) or {}
    mnc_path = data.get('path', '')
    if not mnc_path or not os.path.isabs(mnc_path):
        return jsonify({'error': 'Path must be absolute'}), 400
    if not is_path_allowed(mnc_path):
        return jsonify({'error': 'Access denied'}), 403
    if not os.path.isfile(mnc_path):
        return jsonify({'error': 'File not found: ' + mnc_path}), 404

    tmpdir = tempfile.mkdtemp(prefix='mnc2nii_')
    out_path = os.path.join(tmpdir, 'output.nii')
    try:
        result = subprocess.run(
            [MNC2NII, mnc_path, out_path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=60
        )
        if result.returncode != 0:
            return jsonify({'error': 'mnc2nii failed', 'stderr': result.stderr}), 500
        return send_file(out_path, mimetype='application/octet-stream',
                       as_attachment=True, download_name='converted.nii')
    except FileNotFoundError:
        return jsonify({'error': 'mnc2nii not found. Install MINC tools or update MNC2NII path in server.py'}), 500
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'mnc2nii timed out'}), 500


# ── VNC app switching ──

VNC_STATE_FILE = os.path.join(PROJECT_DIR, '.vnc_state.json')
VNC_MANAGER = os.path.join(PROJECT_DIR, 'vnc_manager.sh')
VALID_APPS = {'slicer', 'fsleyes', 'freeview', 'itksnap', 'desktop', 'wbview', 'paraview', 'afni', 'mricron', 'mricrogl', 'surfice', 'blender', 'brainnet'}

JUPYTER_STATE_FILE = os.path.join(PROJECT_DIR, '.jupyter_state.json')
JUPYTER_MANAGER = os.path.join(PROJECT_DIR, 'jupyter_manager.sh')


@app.route('/api/jupyter/state')
def jupyter_state():
    """Get current JupyterLab session state, with optional ?verify=1 health check."""
    if not os.path.isfile(JUPYTER_STATE_FILE):
        return jsonify({'error': 'No Jupyter session'}), 404
    with open(JUPYTER_STATE_FILE) as f:
        state = json.load(f)
    local_port = state.get('local_port', 8889)
    import socket
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(('localhost', local_port))
        sock.close()
    except Exception:
        os.remove(JUPYTER_STATE_FILE)
        return jsonify({'error': 'Jupyter session expired (tunnel dead)'}), 404
    return jsonify(state)


@app.route('/api/jupyter/start', methods=['POST'])
def jupyter_start():
    """Start JupyterLab on a compute node (reuses VNC's SLURM job if any)."""
    data = request.get_json(silent=True) or {}
    compute_node = data.get('compute_node', '').strip()
    if not compute_node:
        return jsonify({'error': 'Missing compute_node'}), 400
    try:
        log_file = os.path.join(PROJECT_DIR, '.jupyter_manager.log')
        with open(log_file, 'a') as lf:
            proc = subprocess.Popen(
                ['/bin/bash', JUPYTER_MANAGER, 'start', compute_node],
                stdout=lf, stderr=lf, close_fds=True
            )
            proc.wait(timeout=180)
        if proc.returncode != 0:
            return jsonify({'error': f'Jupyter start failed (exit {proc.returncode})'}), 500
        if os.path.isfile(JUPYTER_STATE_FILE):
            with open(JUPYTER_STATE_FILE) as f:
                state = json.load(f)
            return jsonify({'message': 'Jupyter started', 'state': state})
        return jsonify({'error': 'No state file written'}), 500
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Jupyter start timed out (180s)'}), 500


@app.route('/api/jupyter/stop', methods=['POST'])
def jupyter_stop():
    try:
        subprocess.run(['/bin/bash', JUPYTER_MANAGER, 'stop'],
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                      universal_newlines=True, timeout=30)
        return jsonify({'message': 'Stopped'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/vnc/state')
def vnc_state():
    """Get current VNC session state.
    Default: quick local check only (file + websockify socket).
    With ?verify=1: also checks SLURM job + remote VNC port (slow, 5-20s).
    If any check fails, state file is removed and 404 is returned.
    """
    if not os.path.isfile(VNC_STATE_FILE):
        return jsonify({'error': 'No VNC session active'}), 404
    with open(VNC_STATE_FILE) as f:
        state = json.load(f)

    compute_node = state.get('compute_node', '')
    ws_port = state.get('websocket_port', 6080)

    # Quick check: websockify alive locally
    import socket
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(('localhost', ws_port))
        sock.close()
    except Exception:
        os.remove(VNC_STATE_FILE)
        return jsonify({'error': 'Session expired: websockify not running'}), 404

    # Full verification only on demand
    if request.args.get('verify') != '1':
        return jsonify(state)

    # Verify: SLURM job for our compute_node still running
    try:
        result = subprocess.run(
            ['ssh', 'longleaf', "squeue -h -u $(whoami) -n vnc_viewer -o '%N'"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, timeout=60
        )
        active_nodes = [n.strip() for n in result.stdout.strip().split('\n') if n.strip()]
        if compute_node not in active_nodes:
            os.remove(VNC_STATE_FILE)
            return jsonify({'error': f'Session expired: SLURM job on {compute_node} no longer active'}), 404
    except Exception as e:
        return jsonify({**state, 'warning': f'Could not verify SLURM: {e}'}), 200

    # Verify: VNC actually listening on compute node
    try:
        result = subprocess.run(
            ['ssh', 'longleaf', f"ssh -o ConnectTimeout=5 {compute_node} 'ss -tln | grep -q :5901 && echo OK || echo DEAD'"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, timeout=60
        )
        if 'OK' not in result.stdout:
            os.remove(VNC_STATE_FILE)
            return jsonify({'error': f'Session expired: VNC not listening on {compute_node}:5901'}), 404
    except Exception as e:
        return jsonify({**state, 'warning': f'Could not verify VNC: {e}'}), 200

    return jsonify(state)


@app.route('/api/vnc/start', methods=['POST'])
def vnc_start():
    """Start a full VNC session: deploy scripts, start VNC, SSH tunnel, websockify.
    POST body: { "compute_node": "c1234", "app": "slicer" }
    """
    data = request.get_json(silent=True) or {}
    compute_node = data.get('compute_node', '').strip()
    app_name = data.get('app', 'slicer').strip()

    if not compute_node:
        return jsonify({'error': 'Missing compute_node parameter'}), 400
    if app_name not in VALID_APPS:
        return jsonify({'error': f'Invalid app. Choose from: {sorted(VALID_APPS)}'}), 400

    try:
        log_file = os.path.join(PROJECT_DIR, '.vnc_manager.log')
        with open(log_file, 'a') as lf:
            proc = subprocess.Popen(
                ['/bin/bash', VNC_MANAGER, 'start', compute_node, app_name],
                stdout=lf, stderr=lf, close_fds=True
            )
            proc.wait(timeout=240)

        if proc.returncode != 0:
            # Exit code 2 = SSH probe failed (pam_slurm_adopt or node unreachable)
            # Cancel the bad SLURM job so the next Connect requests a fresh node
            if proc.returncode == 2:
                try:
                    subprocess.run(
                        ['ssh', 'longleaf', 'scancel -u $(whoami) -n vnc_viewer'],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        universal_newlines=True, timeout=60
                    )
                except Exception:
                    pass
                return jsonify({
                    'error': f'Node {compute_node} is unreachable (SLURM allocated but SSH rejected). The bad job has been cancelled — click Connect again to request a fresh node.',
                    'retry': True
                }), 503
            return jsonify({
                'error': 'VNC start failed (exit code %d). Check .vnc_manager.log' % proc.returncode
            }), 500

        # Read state
        if os.path.isfile(VNC_STATE_FILE):
            with open(VNC_STATE_FILE) as f:
                state = json.load(f)
            return jsonify({
                'message': 'VNC session started: %s on %s' % (state.get('app_label', app_name), compute_node),
                'state': state
            })
        return jsonify({'message': 'VNC start completed'})
    except subprocess.TimeoutExpired:
        proc.kill()
        return jsonify({'error': 'VNC start timed out (240s)'}), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/vnc/switch', methods=['POST'])
def vnc_switch_app():
    """Switch the VNC application on an existing session.
    POST body: { "app": "fsleyes" }
    """
    data = request.get_json(silent=True) or {}
    app_name = data.get('app', '')
    if app_name not in VALID_APPS:
        return jsonify({'error': f'Invalid app. Choose from: {sorted(VALID_APPS)}'}), 400
    if not os.path.isfile(VNC_STATE_FILE):
        return jsonify({'error': 'No VNC session active. Use /api/vnc/start first.'}), 404

    try:
        log_file = os.path.join(PROJECT_DIR, '.vnc_manager.log')
        with open(log_file, 'a') as lf:
            proc = subprocess.Popen(
                ['/bin/bash', VNC_MANAGER, 'switch', app_name],
                stdout=lf, stderr=lf, close_fds=True
            )
            proc.wait(timeout=240)

        if proc.returncode != 0:
            return jsonify({'error': 'Switch failed (exit code %d)' % proc.returncode}), 500
        with open(VNC_STATE_FILE) as f:
            state = json.load(f)
        return jsonify({
            'message': 'Switched to %s' % state.get('app_label', app_name),
            'state': state
        })
    except subprocess.TimeoutExpired:
        proc.kill()
        return jsonify({'error': 'Switch timed out (120s)'}), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/vnc/stop', methods=['POST'])
def vnc_stop():
    """Stop the VNC session, tunnel, and websockify."""
    try:
        log_file = os.path.join(PROJECT_DIR, '.vnc_manager.log')
        with open(log_file, 'a') as lf:
            proc = subprocess.Popen(
                ['/bin/bash', VNC_MANAGER, 'stop'],
                stdout=lf, stderr=lf, close_fds=True
            )
            proc.wait(timeout=30)
        return jsonify({'message': 'VNC session stopped'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ── SLURM job detection on Longleaf ──

@app.route('/api/slurm/jobs')
def slurm_jobs():
    """List running SLURM jobs on Longleaf to find compute nodes."""
    try:
        result = subprocess.run(
            ['ssh', 'longleaf', 'squeue -u swangek --noheader -o "%N|%j|%T|%l|%M"'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=60
        )
        jobs = []
        for line in result.stdout.strip().split('\n'):
            line = line.strip()
            if not line or '|' not in line:
                continue
            parts = line.split('|')
            if len(parts) >= 3 and parts[2] == 'RUNNING':
                jobs.append({
                    'node': parts[0],
                    'name': parts[1],
                    'state': parts[2],
                    'time_limit': parts[3] if len(parts) > 3 else '',
                    'time_used': parts[4] if len(parts) > 4 else '',
                })
        return jsonify(jobs)
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'SSH to Longleaf timed out'}), 504
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/slurm/start', methods=['POST'])
def slurm_start():
    """Submit an interactive SLURM job on Longleaf for VNC use.
    POST body: { "partition": "gpu", "mem": "8g", "time": "4:00:00", "gpus": 0 }
    Returns the allocated compute node.
    """
    data = request.get_json(silent=True) or {}
    partition = data.get('partition', 'general')
    mem = data.get('mem', '8g')
    time_limit = data.get('time', '4:00:00')
    gpus = data.get('gpus', 0)
    job_name = 'vnc_viewer'

    # Build srun command that runs in background and reports hostname
    gpu_flag = '--gpus={}'.format(gpus) if int(gpus) > 0 else ''
    sbatch_script = (
        '#!/bin/bash\n'
        '#SBATCH -p {partition}\n'
        '#SBATCH --mem={mem}\n'
        '#SBATCH -t {time}\n'
        '#SBATCH -J {job_name}\n'
        '{gpu_line}'
        'echo "HOSTNAME=$(hostname)"\n'
        # Use tail -f /dev/null instead of "sleep infinity" because the VNC
        # cleanup script pkills "sleep infinity" (xstartup) — would kill the job
        'tail -f /dev/null\n'
    ).format(
        partition=partition, mem=mem, time=time_limit,
        job_name=job_name,
        gpu_line='#SBATCH --gpus={}\n'.format(gpus) if int(gpus) > 0 else ''
    )

    try:
        # Submit batch job
        result = subprocess.run(
            ['ssh', 'longleaf', 'sbatch --parsable << \'SBEOF\'\n' + sbatch_script + 'SBEOF'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=60
        )
        if result.returncode != 0:
            return jsonify({'error': 'sbatch failed', 'stderr': result.stderr}), 500

        job_id = result.stdout.strip().split('\n')[-1].strip()
        return jsonify({
            'message': 'Job submitted',
            'job_id': job_id,
            'hint': 'Wait for the job to start, then click Detect Node'
        })
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'SSH to Longleaf timed out'}), 504
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ── List CIVET QC subjects ──

@app.route('/api/civet-subjects')
def list_civet_subjects():
    """List available CIVET QC subjects (directories matching verify_* or verify/)."""
    subjects = []
    for d in sorted(os.listdir(PROJECT_DIR)):
        full = os.path.join(PROJECT_DIR, d)
        if os.path.isdir(full) and d.startswith('verify'):
            subj_id = d.replace('verify_', '').replace('verify', 'default')
            subjects.append({'id': subj_id, 'dir': d})
    return jsonify(subjects)


if __name__ == '__main__':
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f'Medical Image Viewer server running at http://0.0.0.0:{port}')
    print(f'Project dir: {PROJECT_DIR}')
    print(f'Allowed paths: {ALLOWED_PREFIXES}')
    app.run(host='0.0.0.0', port=port, debug=True)
