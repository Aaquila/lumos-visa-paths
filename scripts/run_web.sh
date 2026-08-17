#!/usr/bin/env bash
# Runs the Lumos Flutter web app with the Google OAuth client ID wired in.
#
# Reads the client ID from the root .env file (GOOGLE_AUTH_CLIENT_ID), then launches:
#
#   flutter run -d chrome --web-port 7357 --dart-define=GOOGLE_CLIENT_ID=<id>
#
# Port 7357 is fixed on purpose: it must match the Authorized JavaScript origin
# (http://localhost:7357) registered on the OAuth client in Google Cloud.
#
# Usage:  ./scripts/run_web.sh [-p PORT] [extra flutter args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FRONTEND_DIR="$REPO_ROOT/frontend"
ENV_FILE="$REPO_ROOT/.env"

PORT=""
PARSED_PORT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--port|-Port)
      PORT="${2:-}"
      if [ -z "$PORT" ]; then echo "error: $1 needs a port number" >&2; exit 1; fi
      shift 2
      ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ ! -f "$ENV_FILE" ]; then
  echo "error: missing .env file at '$ENV_FILE'. Create it with GOOGLE_AUTH_CLIENT_ID=<your-client-id> (see docs/RUNNING.md)." >&2
  exit 1
fi

# Parse .env for GOOGLE_AUTH_CLIENT_ID and FRONTEND_PORT.
CLIENT_ID=""
FOUND_LINE=0
LINE_NO=0
while IFS= read -r raw || [ -n "$raw" ]; do
  LINE_NO=$((LINE_NO + 1))
  line="$(printf '%s' "$raw" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$line" in
    ''|'#'*) continue ;;
    GOOGLE_AUTH_CLIENT_ID=*)
      if [ -z "$CLIENT_ID" ]; then
        CLIENT_ID="${line#GOOGLE_AUTH_CLIENT_ID=}"
        CLIENT_ID="${CLIENT_ID%\"}"
        CLIENT_ID="${CLIENT_ID#\"}"
        CLIENT_ID="${CLIENT_ID%\'}"
        CLIENT_ID="${CLIENT_ID#\'}"
        FOUND_LINE=$LINE_NO
      fi
      ;;
    FRONTEND_PORT=*)
      if [ -z "$PORT" ] && [ -z "$PARSED_PORT" ]; then
        PARSED_PORT="${line#FRONTEND_PORT=}"
        PARSED_PORT="${PARSED_PORT%\"}"
        PARSED_PORT="${PARSED_PORT#\"}"
        PARSED_PORT="${PARSED_PORT%\'}"
        PARSED_PORT="${PARSED_PORT#\'}"
      fi
      ;;
  esac
done < "$ENV_FILE"

FINAL_PORT="${PORT:-${PARSED_PORT:-7357}}"

if [ -z "$CLIENT_ID" ]; then
  echo "error: GOOGLE_AUTH_CLIENT_ID not found in '$ENV_FILE'. Add the line: GOOGLE_AUTH_CLIENT_ID=<your-client-id> (see docs/RUNNING.md)." >&2
  exit 1
fi

case "$CLIENT_ID" in
  *"YOUR_CLIENT_ID_HERE"*|*"PLACEHOLDER"*)
    echo "error: client ID is still a placeholder. Edit '$ENV_FILE' line $FOUND_LINE and replace the value with your real Google OAuth Web client ID (see docs/RUNNING.md)." >&2
    exit 1
    ;;
  *.apps.googleusercontent.com) ;;
  *)
    echo "error: '$CLIENT_ID' (from '$ENV_FILE' line $FOUND_LINE) does not look like a Google client ID; it must end in '.apps.googleusercontent.com'." >&2
    exit 1
    ;;
esac

if [ ! -d "$FRONTEND_DIR" ]; then
  echo "error: could not find the Flutter app at '$FRONTEND_DIR'." >&2
  exit 1
fi

echo "Client ID : $CLIENT_ID"
echo "Port      : $FINAL_PORT"
echo "Origin    : http://localhost:$FINAL_PORT  (must match the OAuth client's Authorized JavaScript origin)"
echo

cd "$FRONTEND_DIR"
exec flutter run -d chrome \
  --web-port "$FINAL_PORT" \
  --web-hostname localhost \
  --dart-define=GOOGLE_CLIENT_ID="$CLIENT_ID" \
  "$@"
