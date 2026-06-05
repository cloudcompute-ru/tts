#!/usr/bin/env bash
#
# Provision script for the "Синтез речи и клонирование голоса" application
# (slug: tts) on cloudcompute.ru.
#
# Runs on the GPU instance after the container starts. The customer app's
# onstart wrapper exports these env vars before invoking us:
#
#   CC_PROVISION_URL       POST endpoint for stage updates
#                          (e.g. https://app.cloudcompute.ru/api/agent/provision)
#   CC_AGENT_TOKEN         bearer token authenticating us to that endpoint
#   CC_APP_MODEL           which TTS engine to install + warm:
#                          xtts-v2 (default) | f5-tts | chatterbox
#   CC_MODEL_DISPLAY_NAME  human-facing preset id, used only in log lines
#
# All are optional — if CC_PROVISION_URL / CC_AGENT_TOKEN are absent,
# report_stage is a silent no-op so the script still works for local manual
# testing (`bash provision.sh` inside a fresh container).
#
# Stage IDs reported here MUST match config/applications.php's
# provisioning.stages for the `tts` slug:
#   install_runtime  engine + Gradio installed
#   download_model   model weights present in the HF cache
#   start_server     Gradio serving HTTP on :7860 (final port check)
#
# stdout/stderr go to /var/log/cc-provision.log (the onstart wrapper sets
# this up via `nohup ... > /var/log/cc-provision.log 2>&1 &`).
#
# IMPORTANT — Python isolation
# ----------------------------
# We deliberately do NOT use the base image's `python3`. Vast.ai's
# `jupyter-pytorch` template floats its tag and has shipped images as new as
# Python 3.14 / CUDA 13.2, for which coqui-tts / torch have no wheels (the
# install then fails or tries to build from source for ~forever). To stay
# decoupled from whatever the host pulled, we create our own venv pinned to
# Python 3.11 via `uv` (which downloads a standalone CPython), and install +
# run everything inside it.

set -euo pipefail

CC_PROVISION_URL="${CC_PROVISION_URL:-}"
CC_AGENT_TOKEN="${CC_AGENT_TOKEN:-}"

# Engine selection. The customer app passes the chosen curated preset's
# `model` key; default to XTTS-v2 (multilingual, the app default) when run
# standalone with no env.
ENGINE="${CC_APP_MODEL:-xtts-v2}"
MODEL_DISPLAY_NAME="${CC_MODEL_DISPLAY_NAME:-$ENGINE}"

TTS_PORT="${TTS_PORT:-7860}"
APP_DIR="${APP_DIR:-/workspace/cc-tts}"
APP_FILE="${APP_DIR}/app.py"
VENV_DIR="${APP_DIR}/venv"
PYVERSION="${CC_TTS_PYTHON_VERSION:-3.11}"

# Pinned venv interpreter. Populated by setup_python; every install/run below
# goes through this, never the base image's python3.
PY=""

# XTTS-v2 weights are gated behind Coqui's CPML license prompt; agreeing
# non-interactively is required for an unattended download. This only
# affects local model use (which is exactly the rent-the-GPU case).
export COQUI_TOS_AGREED=1
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

# fail <human-message>
#
# Report a fatal error against the current stage and exit non-zero. A
# non-empty `message` on provision_state is the backend's signal to flip the
# instance to ERROR immediately (Instance::hasApplicationProvisioningFailed),
# so the user sees a real error instead of the stepper hanging until the
# 30-min overall timeout.
fail() {
    local msg="$1"
    log "FAILED at stage=${CURRENT_STAGE}: ${msg}"
    # Escape backslashes and double quotes for safe JSON embedding.
    local safe
    safe="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/'"'"'/g')"
    report_stage "{\"stage\":\"${CURRENT_STAGE}\",\"message\":\"${safe}\"}"
    exit 1
}

# Any unhandled non-zero command under `set -e` lands here. Stages that do
# their own error handling wrap the risky bit in `set +e ... set -e`, so this
# trap only fires for genuinely unexpected failures.
trap 'fail "Установка прервана на этапе ${CURRENT_STAGE}. Подробности в /var/log/cc-provision.log на инстансе."' ERR

# setup_python
#
# Install uv (if absent) and create a Python ${PYVERSION} venv at $VENV_DIR.
# uv downloads a standalone CPython, so we get a known-good interpreter no
# matter what the base image ships. Sets global $PY to the venv python.
setup_python() {
    if ! command -v uv >/dev/null 2>&1; then
        log "installing uv"
        curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 \
            || fail "Не удалось установить uv (менеджер Python). Проверьте сеть и попробуйте снова."
        # uv installs to ~/.local/bin (or $XDG_BIN_HOME); make it visible now.
        export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
    fi
    command -v uv >/dev/null 2>&1 || fail "uv не найден в PATH после установки."

    log "creating Python ${PYVERSION} venv at ${VENV_DIR}"
    uv venv --python "${PYVERSION}" "${VENV_DIR}" \
        || fail "Не удалось создать виртуальное окружение Python ${PYVERSION}."

    PY="${VENV_DIR}/bin/python"
    [ -x "$PY" ] || fail "Python из venv не найден: ${PY}"
}

# uvpip <pip-args...> — install into our pinned venv via uv's fast resolver.
uvpip() {
    uv pip install --python "$PY" "$@"
}

# write_app_py
#
# Emits the Gradio app we drive ourselves (XTTS-v2 and Chatterbox). The
# heredoc is single-quoted so bash leaves the Python untouched; the script
# reads its engine + port from the same env the customer app exported.
# F5-TTS is excluded — it ships its own Gradio UI (f5-tts_infer-gradio).
write_app_py() {
    cat > "$APP_FILE" <<'PYEOF'
import os

import gradio as gr

ENGINE = os.environ.get("CC_APP_MODEL", "xtts-v2")
PORT = int(os.environ.get("TTS_PORT", "7860"))
OUT_PATH = "/tmp/cc-tts-out.wav"

REF_HINT = (
    "Загрузите чистый образец голоса 10–15 секунд: один говорящий, "
    "без музыки и фонового шума — от качества образца зависит результат."
)

if ENGINE == "chatterbox":
    import torch
    import torchaudio
    from chatterbox.tts import ChatterboxTTS

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = ChatterboxTTS.from_pretrained(device=device)

    def synth(text, ref_audio):
        if not text or not text.strip():
            raise gr.Error("Введите текст для синтеза.")
        wav = model.generate(text, audio_prompt_path=ref_audio) if ref_audio else model.generate(text)
        torchaudio.save(OUT_PATH, wav, model.sr)
        return OUT_PATH

    with gr.Blocks(title="CloudCompute TTS — Chatterbox") as demo:
        gr.Markdown("## Chatterbox — синтез речи и клонирование голоса\n" + REF_HINT)
        text = gr.Textbox(label="Текст", lines=4)
        ref = gr.Audio(label="Образец голоса (необязательно)", type="filepath")
        out = gr.Audio(label="Результат")
        gr.Button("Синтезировать", variant="primary").click(synth, [text, ref], out)
else:
    import torch
    from TTS.api import TTS

    device = "cuda" if torch.cuda.is_available() else "cpu"
    tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(device)
    LANGS = [
        "ru", "en", "ar", "es", "fr", "de", "it", "pt", "pl", "tr",
        "nl", "cs", "zh-cn", "ja", "hu", "ko", "hi",
    ]

    def synth(text, ref_audio, language):
        if not text or not text.strip():
            raise gr.Error("Введите текст для синтеза.")
        if not ref_audio:
            raise gr.Error("XTTS-v2 требует образец голоса для клонирования.")
        tts.tts_to_file(text=text, speaker_wav=ref_audio, language=language, file_path=OUT_PATH)
        return OUT_PATH

    with gr.Blocks(title="CloudCompute TTS — XTTS-v2") as demo:
        gr.Markdown("## XTTS-v2 — мультиязычный синтез речи с клонированием голоса\n" + REF_HINT)
        text = gr.Textbox(label="Текст", lines=4)
        ref = gr.Audio(label="Образец голоса", type="filepath")
        language = gr.Dropdown(LANGS, value="ru", label="Язык")
        out = gr.Audio(label="Результат")
        gr.Button("Синтезировать", variant="primary").click(synth, [text, ref, language], out)

demo.queue().launch(server_name="0.0.0.0", server_port=PORT, show_api=False)
PYEOF
}

case "$ENGINE" in
    xtts-v2|f5-tts|chatterbox) ;;
    *)
        log "unknown engine '$ENGINE', falling back to xtts-v2"
        ENGINE="xtts-v2"
        ;;
esac

mkdir -p "$APP_DIR" "$HF_HOME"

# --- stage 1: install_runtime --------------------------------------------

CURRENT_STAGE="install_runtime"
log "stage: install_runtime (engine=${ENGINE}, preset=${MODEL_DISPLAY_NAME})"
report_stage '{"stage":"install_runtime","progress_pct":0}'

# System libs every engine needs: ffmpeg for audio I/O, libsndfile for
# soundfile, git for pip VCS installs, curl for the uv installer.
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends ffmpeg libsndfile1 git curl >/dev/null 2>&1 || true

report_stage '{"stage":"install_runtime","progress_pct":20}'

# Pinned Python 3.11 venv (see header). Decouples us from the base image's
# python, which may be 3.14 and wheel-less for torch / coqui-tts.
setup_python

report_stage '{"stage":"install_runtime","progress_pct":40}'

# Torch first, from the official CUDA 12.4 wheel index. Newer NVIDIA drivers
# (incl. the CUDA 13.x hosts) run cu124 runtime fine via backward compat, and
# cu124 has stable py311 wheels for every engine below.
uvpip torch torchaudio --index-url https://download.pytorch.org/whl/cu124 \
    || fail "Не удалось установить PyTorch. Удалите инстанс и попробуйте другой сервер."

report_stage '{"stage":"install_runtime","progress_pct":60}'

# Engine-specific Python deps.
case "$ENGINE" in
    xtts-v2)
        # `coqui-tts` is the maintained community fork of the (archived)
        # original Coqui `TTS` package; same `from TTS.api import TTS`.
        uvpip "coqui-tts>=0.24" "gradio>=4.44,<6" soundfile \
            || fail "Не удалось установить движок XTTS-v2. Удалите инстанс и попробуйте снова."
        ;;
    f5-tts)
        # F5-TTS ships its own Gradio app (`f5-tts_infer-gradio`).
        uvpip f5-tts \
            || fail "Не удалось установить движок F5-TTS. Удалите инстанс и попробуйте снова."
        ;;
    chatterbox)
        uvpip chatterbox-tts "gradio>=4.44,<6" soundfile \
            || fail "Не удалось установить движок Chatterbox. Удалите инстанс и попробуйте снова."
        ;;
esac

report_stage '{"stage":"install_runtime","progress_pct":80}'

# Write the Gradio UI for the engines we drive ourselves (XTTS-v2,
# Chatterbox). F5-TTS uses its own bundled UI so it needs no app.py.
if [ "$ENGINE" != "f5-tts" ]; then
    write_app_py
fi

report_stage '{"stage":"install_runtime","progress_pct":100}'

# --- stage 2: download_model ---------------------------------------------

CURRENT_STAGE="download_model"
log "stage: download_model"
report_stage '{"stage":"download_model","progress_pct":0}'

# Warm the weights into the HF cache now (rather than on the user's first
# synth) so the start_server port check reflects a genuinely ready model.
# We can't get a clean byte-level percentage out of HF's downloader here,
# so we report 0 → 100 around the load; the stage label is the primary
# signal (with_progress is a UX nicety, same as the comfyui-flux app).
#
# The warm script is written to a file and run via `if ! ...; then` rather
# than the `set +e; cmd; status=$?` pattern: commands in an `if` condition
# are exempt from errexit AND the ERR trap, so this reliably captures a
# failure (the set+e pattern lets the global ERR trap misfire on some bash
# builds). Output is teed to a log so the real traceback surfaces in the UI
# failure message — no SSH needed to diagnose.
WARM_FILE="${APP_DIR}/warm_${ENGINE}.py"
WARM_LOG="/var/log/cc-tts-warm.log"

case "$ENGINE" in
    xtts-v2)
        cat > "$WARM_FILE" <<'PYEOF'
from TTS.api import TTS
# Constructing the model downloads + caches the XTTS-v2 checkpoint.
TTS("tts_models/multilingual/multi-dataset/xtts_v2")
print("xtts-v2 weights cached")
PYEOF
        ;;
    chatterbox)
        cat > "$WARM_FILE" <<'PYEOF'
import torch
from chatterbox.tts import ChatterboxTTS
dev = "cuda" if torch.cuda.is_available() else "cpu"
ChatterboxTTS.from_pretrained(device=dev)
print("chatterbox weights cached")
PYEOF
        ;;
    f5-tts)
        cat > "$WARM_FILE" <<'PYEOF'
# F5-TTS lazily fetches weights from HF on first synthesis. Pre-pull the
# default model so the user's first generation isn't a cold download.
try:
    from huggingface_hub import snapshot_download
    snapshot_download("SWivid/F5-TTS")
    print("f5-tts weights cached")
except Exception as e:
    # Non-fatal: the bundled UI will fetch on demand if this misses.
    print(f"f5-tts pre-pull skipped: {e}")
PYEOF
        ;;
esac

if ! "$PY" "$WARM_FILE" > "$WARM_LOG" 2>&1; then
    log "model warm-load failed; tail of ${WARM_LOG}:"
    tail -n 20 "$WARM_LOG" 2>/dev/null || true
    tail_msg="$(tail -c 600 "$WARM_LOG" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')" || true
    fail "Не удалось загрузить модель ${MODEL_DISPLAY_NAME}: ${tail_msg}"
fi

report_stage '{"stage":"download_model","progress_pct":100}'

# --- stage 3: start_server -----------------------------------------------

CURRENT_STAGE="start_server"
log "stage: start_server"
report_stage '{"stage":"start_server"}'

if [ "$ENGINE" = "f5-tts" ]; then
    # F5-TTS's own Gradio app, from the venv's bin. --host/--port expose it
    # on the mapped port.
    nohup "${VENV_DIR}/bin/f5-tts_infer-gradio" --host 0.0.0.0 --port "$TTS_PORT" \
        > /var/log/cc-tts.log 2>&1 &
else
    nohup "$PY" "$APP_FILE" > /var/log/cc-tts.log 2>&1 &
fi
SERVER_PID=$!

# Wait for Gradio to actually bind the port before reporting success.
# If the process dies during model load (OOM, CUDA mismatch), bail early
# with the tail of the log so the frontend surfaces a real error instead
# of spinning on "preparing interface" forever.
BIND_TIMEOUT_S=180
for _ in $(seq 1 "$BIND_TIMEOUT_S"); do
    if curl -fsS --max-time 1 "http://127.0.0.1:${TTS_PORT}/" >/dev/null 2>&1; then
        report_stage '{"stage":"start_server","progress_pct":100}'
        log "provisioning complete"
        exit 0
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        log "tts server exited before binding port ${TTS_PORT}"
        tail_msg="$(tail -c 500 /var/log/cc-tts.log 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')" || true
        fail "Сервис синтеза речи упал при запуске: ${tail_msg}"
    fi
    sleep 1
done

fail "Веб-интерфейс не запустился за ${BIND_TIMEOUT_S}с. Смотрите /var/log/cc-tts.log на инстансе."
