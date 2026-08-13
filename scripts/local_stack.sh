#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="${S2S_RUNTIME_DIR:-$REPO_DIR/.local-stack}"
VENV_BIN="${S2S_VENV_BIN:-$REPO_DIR/.venv/bin}"

if [[ -f "$REPO_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_DIR/.env"
    set +a
fi

resolve_repo_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$REPO_DIR" "$1" ;;
    esac
}

LLM_MODEL="$(resolve_repo_path "${S2S_LLM_MODEL:-models/llm/Qwen3.5-4B-UD-Q4_K_XL.gguf}")"
TTS_TALKER="$(resolve_repo_path "${S2S_TTS_TALKER:-models/qwen3-tts/qwen-talker-1.7b-customvoice-Q8_0.gguf}")"
TTS_CODEC="$(resolve_repo_path "${S2S_TTS_CODEC:-models/qwen3-tts/qwen-tokenizer-12hz-Q8_0.gguf}")"
SMART_TURN_MODEL="$(resolve_repo_path "${S2S_SMART_TURN_MODEL:-models/smart-turn-v3/smart-turn-v3.2-cpu.onnx}")"

STT_DEVICE="${S2S_STT_DEVICE:-cuda}"
TTS_SPEAKER="${S2S_TTS_SPEAKER:-aiden}"
LLM_GPU_LAYERS="${S2S_LLM_GPU_LAYERS:-99}"
LLM_CONTEXT_SIZE="${S2S_LLM_CONTEXT_SIZE:-8192}"

LLM_HOST="${S2S_LLM_HOST:-127.0.0.1}"
LLM_PORT="${S2S_LLM_PORT:-8080}"
PIPELINE_HOST="${S2S_PIPELINE_HOST:-127.0.0.1}"
PIPELINE_PORT="${S2S_PIPELINE_PORT:-8765}"
DEMO_HOST="${S2S_DEMO_HOST:-127.0.0.1}"
DEMO_PORT="${S2S_DEMO_PORT:-7860}"

mkdir -p "$RUNTIME_DIR"

usage() {
    cat <<'EOF'
Usage: scripts/local_stack.sh {run|start|stop|restart|status|logs}

Commands:
  run      Start and supervise the stack in this terminal; Ctrl+C stops it.
  start    Start llama-server, speech-to-speech, and the browser demo.
  stop     Stop all three services.
  restart  Stop and start the stack.
  status   Show process and endpoint status.
  logs     Follow all service logs (Ctrl+C stops following, not the services).

Model paths and ports can be overridden with S2S_* environment variables.
EOF
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "Missing required model file: $1" >&2
        exit 1
    fi
}

pid_file() {
    printf '%s/%s.pid\n' "$RUNTIME_DIR" "$1"
}

log_file() {
    printf '%s/%s.log\n' "$RUNTIME_DIR" "$1"
}

read_pid() {
    local file
    file="$(pid_file "$1")"
    [[ -f "$file" ]] && tr -d '[:space:]' < "$file"
}

process_matches() {
    local service="$1"
    local pid
    pid="$(read_pid "$service")"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -r "/proc/$pid/cmdline" ]] || return 1

    local command_line
    command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    case "$service" in
        llama) [[ "$command_line" == *"llama-server"*"$LLM_MODEL"* ]] ;;
        pipeline) [[ "$command_line" == *"speech-to-speech"*"serve"* ]] ;;
        demo) [[ "$command_line" == *"uvicorn"*"server:app"* ]] ;;
        *) return 1 ;;
    esac
}

wait_for_http() {
    local name="$1"
    local url="$2"
    local attempts="${3:-120}"

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if ! process_matches "$name"; then
            echo "$name exited before becoming ready" >&2
            tail -n 30 "$(log_file "$name")" >&2 || true
            return 1
        fi
        if curl --silent --show-error --max-time 1 --output /dev/null "$url" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done

    echo "$name did not become ready at $url" >&2
    echo "Last log lines:" >&2
    tail -n 30 "$(log_file "$name")" >&2 || true
    return 1
}

start_llama() {
    if process_matches llama; then
        echo "llama-server already running (PID $(read_pid llama))"
        return
    fi

    rm -f "$(pid_file llama)"
    echo "Starting llama-server..."
    nohup llama-server \
        -m "$LLM_MODEL" \
        -ngl "$LLM_GPU_LAYERS" \
        -c "$LLM_CONTEXT_SIZE" \
        -np 1 \
        -fa on \
        --host "$LLM_HOST" \
        --port "$LLM_PORT" \
        >"$(log_file llama)" 2>&1 &
    echo "$!" > "$(pid_file llama)"
    wait_for_http llama "http://$LLM_HOST:$LLM_PORT/health"
    echo "llama-server ready on http://$LLM_HOST:$LLM_PORT"
}

start_pipeline() {
    if process_matches pipeline; then
        echo "speech pipeline already running (PID $(read_pid pipeline))"
        return
    fi

    rm -f "$(pid_file pipeline)"
    echo "Starting speech pipeline..."
    nohup "$VENV_BIN/speech-to-speech" serve \
        --host "$PIPELINE_HOST" \
        --port "$PIPELINE_PORT" \
        --stt parakeet-tdt \
        --parakeet_tdt_device "$STT_DEVICE" \
        --llm_backend chat-completions \
        --model_name local \
        --responses_api_base_url "http://$LLM_HOST:$LLM_PORT/v1" \
        --responses_api_api_key local \
        --responses_api_disable_thinking True \
        --tts qwen3 \
        --qwen3_tts_model_name Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice \
        --qwen3_tts_backend ggml \
        --qwen3_tts_gguf_talker_path "$TTS_TALKER" \
        --qwen3_tts_gguf_codec_path "$TTS_CODEC" \
        --qwen3_tts_speaker "$TTS_SPEAKER" \
        --smart_turn_model_path "$SMART_TURN_MODEL" \
        --enable_live_transcription \
        >"$(log_file pipeline)" 2>&1 &
    echo "$!" > "$(pid_file pipeline)"
    wait_for_http pipeline "http://$PIPELINE_HOST:$PIPELINE_PORT/" 180
    echo "speech pipeline ready on ws://$PIPELINE_HOST:$PIPELINE_PORT/v1/realtime"
}

start_demo() {
    if process_matches demo; then
        echo "browser demo already running (PID $(read_pid demo))"
        return
    fi

    rm -f "$(pid_file demo)"
    echo "Starting browser demo..."
    nohup env SPEECH_TO_SPEECH_URL="ws://$PIPELINE_HOST:$PIPELINE_PORT/v1/realtime" \
        "$VENV_BIN/uvicorn" --app-dir demo server:app \
        --host "$DEMO_HOST" \
        --port "$DEMO_PORT" \
        >"$(log_file demo)" 2>&1 &
    echo "$!" > "$(pid_file demo)"
    wait_for_http demo "http://$DEMO_HOST:$DEMO_PORT/"
    echo "browser demo ready on http://$DEMO_HOST:$DEMO_PORT"
}

start_stack() {
    require_command curl
    require_command llama-server
    require_file "$VENV_BIN/speech-to-speech"
    require_file "$VENV_BIN/uvicorn"
    require_file "$LLM_MODEL"
    require_file "$TTS_TALKER"
    require_file "$TTS_CODEC"
    require_file "$SMART_TURN_MODEL"

    cd "$REPO_DIR"
    start_llama
    start_pipeline
    start_demo
    echo
    echo "Stack is ready: http://localhost:$DEMO_PORT"
}

stop_service() {
    local service="$1"
    local pid

    if ! process_matches "$service"; then
        rm -f "$(pid_file "$service")"
        echo "$service is not running"
        return
    fi

    pid="$(read_pid "$service")"
    echo "Stopping $service (PID $pid)..."
    kill "$pid"
    for _ in {1..20}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$(pid_file "$service")"
            return
        fi
        sleep 0.5
    done

    echo "$service did not stop cleanly; terminating it forcefully" >&2
    kill -KILL "$pid" 2>/dev/null || true
    rm -f "$(pid_file "$service")"
}

stop_stack() {
    stop_service demo
    stop_service pipeline
    stop_service llama
}

run_stack() {
    local shutdown_requested=0

    request_shutdown() {
        shutdown_requested=1
    }

    trap request_shutdown INT TERM
    trap stop_stack EXIT
    start_stack
    echo "Supervising the stack. Press Ctrl+C to stop everything."

    while ((shutdown_requested == 0)); do
        if ! process_matches llama || ! process_matches pipeline || ! process_matches demo; then
            echo "A stack service exited unexpectedly." >&2
            return 1
        fi
        sleep 2
    done
}

show_service_status() {
    local service="$1"
    local endpoint="$2"
    if process_matches "$service"; then
        local pid
        pid="$(read_pid "$service")"
        if curl --silent --show-error --max-time 1 --output /dev/null "$endpoint" 2>/dev/null; then
            printf '%-10s running  PID %-8s %s\n' "$service" "$pid" "$endpoint"
        else
            printf '%-10s starting PID %-8s %s\n' "$service" "$pid" "$endpoint"
        fi
    else
        printf '%-10s stopped\n' "$service"
    fi
}

show_status() {
    show_service_status llama "http://$LLM_HOST:$LLM_PORT/health"
    show_service_status pipeline "http://$PIPELINE_HOST:$PIPELINE_PORT/"
    show_service_status demo "http://$DEMO_HOST:$DEMO_PORT/"
}

follow_logs() {
    touch "$(log_file llama)" "$(log_file pipeline)" "$(log_file demo)"
    tail -n 40 -F "$(log_file llama)" "$(log_file pipeline)" "$(log_file demo)"
}

case "${1:-}" in
    run) run_stack ;;
    start) start_stack ;;
    stop) stop_stack ;;
    restart) stop_stack; start_stack ;;
    status) show_status ;;
    logs) follow_logs ;;
    *) usage; exit 2 ;;
esac
