#!/usr/bin/env bash
#
# Provision script for the "Синтез речи и клонирование голоса" application
# (slug: tts) on cloudcompute.ru.
#
# Runs on the GPU instance after the container starts. The customer app's
# onstart wrapper exports these env vars before invoking us:
#
#   CC_PROVISION_URL   POST endpoint for stage updates
#                      (e.g. https://app.cloudcompute.ru/api/agent/provision)
#   CC_AGENT_TOKEN     bearer token authenticating us to that endpoint
#
# Both are optional — if absent, report_stage is a silent no-op so the script
# still works for local manual testing (`bash provision.sh` inside a fresh
# container).
#
# WHAT THIS DEPLOYS
# -----------------
# We self-host Resemble AI's Chatterbox TTS family via the community
# Chatterbox-TTS-Server (forked into our org for stability, pinned by SHA):
#
#   cloudcompute-ru/Chatterbox-TTS-Server   the FastAPI server + Web UI
#   cloudcompute-ru/chatterbox-v2           the model package (--no-deps)
#
# It ships a Web UI with an engine dropdown (Original / Multilingual / Turbo)
# and a language dropdown, voice cloning, predefined voices, and an
# OpenAI-compatible API. We default the engine to **Chatterbox Multilingual**
# (23 languages incl. Russian, zero-shot voice cloning, MIT-licensed) so the
# Russian-first audience gets a working default; the user can hot-swap to
# Original/Turbo in the UI without a restart. This replaced the previous
# hand-rolled Gradio app + XTTS-v2 (abandoned, CPML, torch-hostile) + F5-TTS.
#
# Stage IDs reported here MUST match config/applications.php's
# provisioning.stages for the `tts` slug:
#   install_runtime  server cloned + Python deps installed
#   download_model   default model weights warmed into the HF cache
#   start_server     server serving HTTP on :8004 (final port check)
#
# stdout/stderr go to /var/log/cc-provision.log (the onstart wrapper sets
# this up via `nohup ... > /var/log/cc-provision.log 2>&1 &`).
#
# IMPORTANT — Python isolation
# ----------------------------
# We deliberately do NOT use the base image's `python3`. Vast.ai's
# `jupyter-pytorch` template floats its tag and has shipped images as new as
# Python 3.14 / CUDA 13.2, for which the TTS deps (torch, onnx) have no
# wheels. To stay decoupled from whatever the host pulled, we create our own
# seeded venv pinned to Python 3.10 (the only version with prebuilt wheels for
# the whole dependency set) via `uv`, and install + run everything inside it.

set -euo pipefail

CC_PROVISION_URL="${CC_PROVISION_URL:-}"
CC_AGENT_TOKEN="${CC_AGENT_TOKEN:-}"

# --- pinned upstream (our forks, pinned by commit) ------------------------
SERVER_REPO="https://github.com/cloudcompute-ru/Chatterbox-TTS-Server.git"
SERVER_SHA="915ae289340e10c6047f27f47e22eae9bf350c32"
# chatterbox model package, installed with --no-deps so it can't downgrade the
# CUDA torch wheels we install from requirements-nvidia-cu128.txt.
CHATTERBOX_PKG="git+https://github.com/cloudcompute-ru/chatterbox-v2.git@cc0357396d9c73fc1e6c544ee40bb596020edd09"

# Default in-UI engine. The server resolves this config value to the model
# class (see engine.py's MODEL_SELECTORS): chatterbox-multilingual → the
# 23-language ChatterboxMultilingualTTS. Override the runtime default via the
# engine dropdown in the Web UI.
DEFAULT_MODEL="chatterbox-multilingual"
DEFAULT_LANGUAGE="ru"

TTS_PORT="${TTS_PORT:-8004}"
APP_DIR="${APP_DIR:-/workspace/cc-tts}"
VENV_DIR="${APP_DIR}/venv"
PYVERSION="${CC_TTS_PYTHON_VERSION:-3.10}"

# Populated by setup_python; every install/run below goes through these,
# never the base image's python3.
PY=""
PIP=""

# Keep the HF cache on the (large) workspace disk, not the small container
# root, so big checkpoints don't fill / and crash the box.
export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"

# Tracks which stage we're in so the ERR trap can attribute a failure to the
# right step in the customer-facing stepper.
CURRENT_STAGE="install_runtime"

# --- helpers --------------------------------------------------------------

# report_stage <json-payload>
#
# Best-effort POST to /api/agent/provision. Failures (network blips, 401,
# 422) are swallowed: a missed update is far preferable to crashing
# provisioning. The frontend trusts our final port check (provision_marker)
# as the ready gate, so even if every report_stage call fails the user
# still gets a working session.
report_stage() {
    if [ -z "$CC_PROVISION_URL" ] || [ -z "$CC_AGENT_TOKEN" ]; then
        return 0
    fi
    curl -fsS \
        -X POST "$CC_PROVISION_URL" \
        -H "Authorization: Bearer $CC_AGENT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$1" \
        --max-time 5 \
        >/dev/null 2>&1 || true
}

log() {
    echo "[cc-provision] $*"
}

# report_log <short-status-line>
#
# Best-effort POST of a single live status line shown under the active
# stage's progress bar in the customer dashboard. Ephemeral — replaced on
# every call, cleared on stage transitions. 200 chars max.
report_log() {
    local line="$1"
    local safe
    safe="$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/'"'"'/g')"
    report_stage "{\"stage\":\"${CURRENT_STAGE}\",\"log_line\":\"${safe}\"}"
}

# send_log_tail
#
# Best-effort POST of the last 200 lines of /var/log/cc-provision.log as
# the `log_tail` field on provision_state. Persists across subsequent stage
# updates (sticky-merged on the backend) so the Provision Log tab in the
# dashboard always shows the most recent snapshot. Uses system python3 for
# correct JSON encoding — safe to call before $PY / $PIP are set up.
send_log_tail() {
    if [ -z "$CC_PROVISION_URL" ] || [ -z "$CC_AGENT_TOKEN" ]; then return 0; fi
    local encoded
    encoded="$(tail -n 200 /var/log/cc-provision.log 2>/dev/null \
        | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' \
        2>/dev/null)" || return 0
    [ -z "$encoded" ] && return 0
    report_stage "{\"stage\":\"${CURRENT_STAGE}\",\"log_tail\":${encoded}}"
}

# fail <human-message>
#
# Report a fatal error against the current stage and exit non-zero. A
# non-empty `message` on provision_state is the backend's signal to flip the
# instance to ERROR immediately (Instance::hasApplicationProvisioningFailed),
# so the user sees a real error instead of the stepper hanging until the
# overall timeout.
fail() {
    local msg="$1"
    log "FAILED at stage=${CURRENT_STAGE}: ${msg}"
    # Escape backslashes and double quotes for safe JSON embedding.
    local safe
    safe="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/'"'"'/g')"
    local log_tail_enc
    log_tail_enc="$(tail -n 100 /var/log/cc-provision.log 2>/dev/null \
        | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' \
        2>/dev/null || echo 'null')"
    report_stage "{\"stage\":\"${CURRENT_STAGE}\",\"message\":\"${safe}\",\"log_tail\":${log_tail_enc}}"
    exit 1
}

# Any unhandled non-zero command under `set -e` lands here. Stages that do
# their own error handling wrap the risky bit in an `if` (exempt from errexit
# AND this trap), so the trap only fires for genuinely unexpected failures.
trap 'fail "Установка прервана на этапе ${CURRENT_STAGE}. Подробности в /var/log/cc-provision.log на инстансе."' ERR

# run_user_hook <stage-id>
#
# Runs the customer-supplied setup script, if any. MUST be called AFTER our
# install steps but immediately BEFORE the app server starts, so anything the
# script installs (pip packages, model weights, extra repos) is on disk for the
# server's first and only boot — no restart needed.
#
# The script arrives base64-encoded in CC_USER_SETUP_B64 (base64 sidesteps all
# shell-quoting hazards). Its stdout/stderr lands in /var/log/cc-provision.log,
# so it shows up in the dashboard log tail. A non-zero exit aborts provisioning
# and surfaces the failure to the wizard.
run_user_hook() {
    [ -n "${CC_USER_SETUP_B64:-}" ] || return 0
    _stage="${1:-start_server}"
    log "running custom setup script"
    report_stage "{\"stage\":\"${_stage}\",\"message\":\"running custom setup script\"}"
    if ! printf '%s' "$CC_USER_SETUP_B64" | base64 -d > /tmp/cc-user-setup.sh 2>/dev/null; then
        log "could not decode CC_USER_SETUP_B64; skipping custom setup"
        return 0
    fi
    chmod +x /tmp/cc-user-setup.sh
    set +e
    bash /tmp/cc-user-setup.sh 2>&1 | sed 's/^/[user-setup] /'
    _rc=${PIPESTATUS[0]}
    set -e
    if [ "$_rc" -ne 0 ]; then
        _tail="$(tail -c 400 /var/log/cc-provision.log 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')"
        report_stage "{\"stage\":\"${_stage}\",\"message\":\"custom setup script failed (exit ${_rc}): ${_tail}\"}"
        exit "$_rc"
    fi
    log "custom setup script finished"
}

# setup_python
#
# Install uv (if absent) and create a seeded Python ${PYVERSION} venv at
# $VENV_DIR. uv downloads a standalone CPython, so we get a known-good
# interpreter no matter what the base image ships. --seed installs pip so we
# can use the upstream's exact pip-based install flow (pip natively honours
# the --extra-index-url lines inside the requirements files). Sets global $PY
# / $PIP to the venv interpreter + pip.
setup_python() {
    if ! command -v uv >/dev/null 2>&1; then
        log "installing uv"
        curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 \
            || fail "Не удалось установить uv (менеджер Python). Проверьте сеть и попробуйте снова."
        # uv installs to ~/.local/bin (or $XDG_BIN_HOME); make it visible now.
        export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
    fi
    command -v uv >/dev/null 2>&1 || fail "uv не найден в PATH после установки."

    log "creating seeded Python ${PYVERSION} venv at ${VENV_DIR}"
    uv venv --seed --python "${PYVERSION}" "${VENV_DIR}" \
        || fail "Не удалось создать виртуальное окружение Python ${PYVERSION}."

    PY="${VENV_DIR}/bin/python"
    PIP="${VENV_DIR}/bin/pip"
    [ -x "$PY" ] || fail "Python из venv не найден: ${PY}"
    [ -x "$PIP" ] || fail "pip из venv не найден: ${PIP}"
}

# clone_server
#
# Fetch the pinned server fork into $APP_DIR. MUST run before setup_python:
# the venv lives at $APP_DIR/venv, and `git clone` refuses a non-empty target.
# Retries a few times (network blips), then falls back to a tarball download
# (codeload, a different path) if git transport is the problem. Captures the
# real error into the failure message so we don't need SSH to diagnose.
clone_server() {
    local clog="/var/log/cc-tts-clone.log"
    local n
    for n in 1 2 3; do
        rm -rf "$APP_DIR"
        if git clone "$SERVER_REPO" "$APP_DIR" >"$clog" 2>&1 \
            && git -C "$APP_DIR" checkout --quiet "$SERVER_SHA" >>"$clog" 2>&1; then
            return 0
        fi
        log "git clone attempt ${n} failed; retrying"
        sleep 3
    done

    log "git clone failed 3x; trying tarball download"
    rm -rf "$APP_DIR" /tmp/cc-server.tgz
    if curl -fsSL "https://codeload.github.com/cloudcompute-ru/Chatterbox-TTS-Server/tar.gz/${SERVER_SHA}" \
            -o /tmp/cc-server.tgz >>"$clog" 2>&1 \
        && tar -xzf /tmp/cc-server.tgz -C /tmp >>"$clog" 2>&1; then
        mv "/tmp/Chatterbox-TTS-Server-${SERVER_SHA}" "$APP_DIR"
        return 0
    fi

    local tail_msg
    tail_msg="$(tail -c 500 "$clog" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')" || true
    fail "Не удалось склонировать сервер синтеза речи: ${tail_msg}"
}

mkdir -p "$HF_HOME"

# --- stage 1: install_runtime --------------------------------------------

CURRENT_STAGE="install_runtime"
log "stage: install_runtime"
report_stage '{"stage":"install_runtime","progress_pct":0}'

# System libs the server needs: ffmpeg for audio I/O, libsndfile for
# soundfile, git for the clone + VCS pip install, curl for the uv installer.
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends ffmpeg libsndfile1 git curl >/dev/null 2>&1 || true

report_stage '{"stage":"install_runtime","progress_pct":15}'
report_log "system deps installed (ffmpeg, libsndfile1)"

# Clone the server fork at its pinned commit FIRST (before the venv, which
# lives inside $APP_DIR — git clone needs an empty target). A floating tag
# could break launches if upstream changes; the SHA makes it reproducible.
clone_server

report_stage '{"stage":"install_runtime","progress_pct":25}'
report_log "Chatterbox-TTS-Server cloned"

# Pinned Python 3.10 venv (see header). Decouples us from the base image's
# python, which may be 3.14 and wheel-less for torch / onnx.
setup_python

report_stage '{"stage":"install_runtime","progress_pct":35}'
report_log "Python 3.10 venv ready"

# CUDA torch stack first, from the cu128 wheel set (torch 2.9.0). cu128
# covers Turing→Blackwell (incl. RTX 50-series, sm_120) in one wheel set;
# newer Vast hosts run it fine via driver forward-compat. pip reads the
# --extra-index-url pin from the requirements file natively.
report_log "installing torch+CUDA (cu128)…"
"$PIP" install --no-warn-script-location -r "${APP_DIR}/requirements-nvidia-cu128.txt" \
    || fail "Не удалось установить зависимости (PyTorch CUDA). Удалите инстанс и попробуйте другой сервер."

report_stage '{"stage":"install_runtime","progress_pct":65}'
report_log "torch installed; installing Chatterbox…"

# Chatterbox model package + s3tokenizer + onnx with --no-deps so pip can't
# replace the cu128 torch wheels with CPU-only ones (s3tokenizer/onnx are
# pulled here to dodge the protobuf<3.20 vs onnx protobuf>=3.20 conflict).
"$PIP" install --no-deps "$CHATTERBOX_PKG" s3tokenizer==0.3.0 onnx==1.16.0 \
    || fail "Не удалось установить пакет Chatterbox. Удалите инстанс и попробуйте снова."

# onnx 1.16.0 drags in an old protobuf; force a modern one (matches the
# upstream launcher's post-install fix-up).
"$PIP" install --no-deps --force-reinstall "protobuf>=4.25.0" >/dev/null 2>&1 || true

# resemble-perth ships PerthImplicitWatermarker as None in this environment
# (its __init__ swallows an internal import error), so chatterbox's
# constructor — self.watermarker = perth.PerthImplicitWatermarker() — dies
# with "'NoneType' object is not callable". Watermarking is provenance-only
# and irrelevant for a rent-the-GPU product (the customer runs their own
# generation), so substitute a no-op when perth is broken. A sitecustomize.py
# in the venv is auto-imported by EVERY python process (our warm script AND
# the server's from_pretrained at startup), so the patch can't be missed.
SITE_PACKAGES="$("$PY" -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null || echo "${VENV_DIR}/lib/python${PYVERSION}/site-packages")"
cat > "${SITE_PACKAGES}/sitecustomize.py" <<'PYEOF'
try:
    import perth

    if getattr(perth, "PerthImplicitWatermarker", None) is None:
        class _NoopWatermarker:
            def apply_watermark(self, wav, sample_rate=None, **kwargs):
                return wav

            def get_watermark(self, *args, **kwargs):
                return None

        perth.PerthImplicitWatermarker = _NoopWatermarker
except Exception:
    # Never let the shim break interpreter startup; a working perth is used
    # as-is, and any unexpected error here just leaves the original behaviour.
    pass
PYEOF

report_stage '{"stage":"install_runtime","progress_pct":85}'
report_log "dependencies installed; configuring engine…"

# Point the server at the multilingual engine + Russian default. These are
# the only two values we override in the shipped config.yaml; everything else
# (host 0.0.0.0, port 8004, no auth) already matches what we need.
sed -i 's#^\([[:space:]]*\)repo_id:.*#\1repo_id: '"$DEFAULT_MODEL"'#' "${APP_DIR}/config.yaml" || true
sed -i 's#^\([[:space:]]*\)language: en\b#\1language: '"$DEFAULT_LANGUAGE"'#' "${APP_DIR}/config.yaml" || true

report_stage '{"stage":"install_runtime","progress_pct":100}'
send_log_tail

# --- stage 2: download_model ---------------------------------------------

CURRENT_STAGE="download_model"
log "stage: download_model"
send_log_tail
report_stage '{"stage":"download_model","progress_pct":0}'
report_log "warming Chatterbox Multilingual weights…"

# Warm the default (multilingual) weights into the HF cache now rather than on
# the user's first synth, so the start_server port check reflects a genuinely
# ready model. We can't get a clean byte-level percentage out of HF's
# downloader here, so we report 0 → 100 around the load.
#
# Run via `if ! ...; then` (commands in an `if` condition are exempt from
# errexit AND the ERR trap) so we reliably capture the real traceback and
# surface it in the failure message — no SSH needed to diagnose.
WARM_FILE="${APP_DIR}/warm_model.py"
WARM_LOG="/var/log/cc-tts-warm.log"

cat > "$WARM_FILE" <<'PYEOF'
import torch
from chatterbox import ChatterboxMultilingualTTS

dev = "cuda" if torch.cuda.is_available() else "cpu"
# Constructing the model downloads + caches the multilingual checkpoint.
ChatterboxMultilingualTTS.from_pretrained(device=dev)
print("chatterbox-multilingual weights cached")
PYEOF

if ! "$PY" "$WARM_FILE" > "$WARM_LOG" 2>&1; then
    log "model warm-load failed; tail of ${WARM_LOG}:"
    tail -n 20 "$WARM_LOG" 2>/dev/null || true
    tail_msg="$(tail -c 600 "$WARM_LOG" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')" || true
    fail "Не удалось загрузить модель Chatterbox Multilingual: ${tail_msg}"
fi

report_stage '{"stage":"download_model","progress_pct":100}'
send_log_tail

# --- stage 3: start_server -----------------------------------------------

CURRENT_STAGE="start_server"
log "stage: start_server"
send_log_tail
report_stage '{"stage":"start_server"}'

# Custom setup runs here — the TTS engine + weights are installed, but the
# server hasn't started, so anything the script installs is present for the
# single launch below.
run_user_hook "start_server"

report_log "starting Chatterbox-TTS-Server on port ${TTS_PORT}…"

# Run from the repo dir so the server finds config.yaml + static/ui assets.
# It loads the model on startup (lifespan), but we pre-warmed the cache so
# that's fast; the port-bind check below is the real ready gate.
( cd "$APP_DIR" && nohup "$PY" server.py > /var/log/cc-tts.log 2>&1 & echo $! > "${APP_DIR}/.server.pid" )
SERVER_PID="$(cat "${APP_DIR}/.server.pid" 2>/dev/null || echo '')"

# Wait for the server to actually answer HTTP before reporting success. If
# the process dies during startup (OOM, CUDA mismatch), bail early with the
# tail of the log so the frontend surfaces a real error instead of spinning.
BIND_TIMEOUT_S=240
for _ in $(seq 1 "$BIND_TIMEOUT_S"); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${TTS_PORT}/" >/dev/null 2>&1; then
        send_log_tail
        report_stage '{"stage":"start_server","progress_pct":100}'
        log "provisioning complete"
        exit 0
    fi
    if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
        log "tts server exited before binding port ${TTS_PORT}"
        tail_msg="$(tail -c 500 /var/log/cc-tts.log 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')" || true
        fail "Сервис синтеза речи упал при запуске: ${tail_msg}"
    fi
    sleep 1
done

fail "Веб-интерфейс не запустился за ${BIND_TIMEOUT_S}с. Смотрите /var/log/cc-tts.log на инстансе."
