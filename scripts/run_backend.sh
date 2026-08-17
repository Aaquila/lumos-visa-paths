#!/usr/bin/env bash
# Runs the Lumos backend API server with configuration from .env.
#
# Reads BACKEND_HOST and BACKEND_PORT from the root .env file, then launches:
#
#   uvicorn app.main:app --reload --host <host> --port <port>
#
# Usage:  ./scripts/run_backend.sh [--host HOST] [--port PORT] [extra uvicorn args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="$REPO_ROOT/backend"
ENV_FILE="$REPO_ROOT/.env"

HOST=""
PORT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --host)
      HOST="${2:-}"
      if [ -z "$HOST" ]; then echo "error: --host needs a value" >&2; exit 1; fi
      shift 2
      ;;
    --port|-p)
      PORT="${2:-}"
      if [ -z "$PORT" ]; then echo "error: $1 needs a value" >&2; exit 1; fi
      shift 2
      ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ ! -f "$ENV_FILE" ]; then
  echo "error: missing .env file at '$ENV_FILE'. See docs/RUNNING.md." >&2
  exit 1
fi

# Parse .env for BACKEND_HOST and BACKEND_PORT if not overridden.
PARSED_HOST=""
PARSED_PORT=""

while IFS= read -r raw || [ -n "$raw" ]; do
  line="$(printf '%s' "$raw" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$line" in
    ''|'#'*) continue ;;
    BACKEND_HOST=*)
      if [ -z "$HOST" ]; then
        PARSED_HOST="${line#BACKEND_HOST=}"
        PARSED_HOST="${PARSED_HOST%\"}"
        PARSED_HOST="${PARSED_HOST#\"}"
        PARSED_HOST="${PARSED_HOST%\'}"
        PARSED_HOST="${PARSED_HOST#\'}"
      fi
      ;;
    BACKEND_PORT=*)
      if [ -z "$PORT" ]; then
        PARSED_PORT="${line#BACKEND_PORT=}"
        PARSED_PORT="${PARSED_PORT%\"}"
        PARSED_PORT="${PARSED_PORT#\"}"
        PARSED_PORT="${PARSED_PORT%\'}"
        PARSED_PORT="${PARSED_PORT#\'}"
      fi
      ;;
  esac
done < "$ENV_FILE"

FINAL_HOST="${HOST:-${PARSED_HOST:-127.0.0.1}}"
FINAL_PORT="${PORT:-${PARSED_PORT:-8000}}"

echo "Backend   : $FINAL_HOST:$FINAL_PORT"
echo

cd "$BACKEND_DIR"
exec uvicorn app.main:app --reload \
  --host "$FINAL_HOST" \
  --port "$FINAL_PORT" \
  "$@"
