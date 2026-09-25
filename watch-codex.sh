#!/bin/bash
set -u

usage_app="${1:?Pass the Codex usage app executable path}"
usage_pid=""

stop_usage_app() {
    if [[ -n "$usage_pid" ]] && kill -0 "$usage_pid" 2>/dev/null; then
        kill -TERM "$usage_pid" 2>/dev/null || true
        wait "$usage_pid" 2>/dev/null || true
    fi
    usage_pid=""
}

trap stop_usage_app EXIT TERM INT

while true; do
    # The current Codex desktop build runs as ChatGPT; keep Codex as a
    # fallback for builds whose main executable uses that process name.
    if /usr/bin/pgrep -x ChatGPT >/dev/null 2>&1 || /usr/bin/pgrep -x Codex >/dev/null 2>&1; then
        if [[ -z "$usage_pid" ]] || ! kill -0 "$usage_pid" 2>/dev/null; then
            "$usage_app" >/dev/null 2>&1 &
            usage_pid=$!
        fi
    else
        stop_usage_app
    fi
    sleep 3
done
