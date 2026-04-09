#!/usr/bin/env bash
#
# devcontainer.sh - Convenience script to manage the dev container
#
# Usage:
#   ./devcontainer.sh          Start (or rebuild) the container, then open a shell
#   ./devcontainer.sh up       Start the container only (no shell)
#   ./devcontainer.sh shell    Open a shell in the running container
#   ./devcontainer.sh down     Stop and remove the container
#   ./devcontainer.sh rebuild  Force a full rebuild
#   ./devcontainer.sh status   Show whether the container is running

set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_LABEL="devcontainer"  # used to find the running container

# ── helpers ──────────────────────────────────────────────────────────
get_container_id() {
  docker ps -q --filter "label=devcontainer.local_folder=${WORKSPACE_DIR}" 2>/dev/null | head -1
}

info()  { echo -e "\033[1;34m[devcontainer]\033[0m $*"; }
error() { echo -e "\033[1;31m[devcontainer]\033[0m $*" >&2; }

# ── commands ─────────────────────────────────────────────────────────
cmd_up() {
  info "Starting dev container from ${WORKSPACE_DIR} ..."
  devcontainer up --workspace-folder "$WORKSPACE_DIR"
  info "Dev container is running."
}

cmd_shell() {
  local cid
  cid="$(get_container_id)"
  if [[ -z "$cid" ]]; then
    error "No running container found. Run '$0 up' first."
    exit 1
  fi
  info "Attaching shell to container ${cid:0:12} ..."
  docker exec -it -u superuser -w /workspaces/app "$cid" bash
}

cmd_down() {
  local cid
  cid="$(get_container_id)"
  if [[ -z "$cid" ]]; then
    info "No running container to stop."
    return
  fi
  info "Stopping container ${cid:0:12} ..."
  docker rm -f "$cid" >/dev/null
  info "Container stopped and removed."
}

cmd_rebuild() {
  info "Rebuilding dev container (no cache) ..."
  cmd_down 2>/dev/null || true
  devcontainer up --workspace-folder "$WORKSPACE_DIR" --build-no-cache
  info "Rebuild complete."
}

cmd_status() {
  local cid
  cid="$(get_container_id)"
  if [[ -n "$cid" ]]; then
    info "Container is RUNNING (${cid:0:12})"
    docker ps --filter "id=$cid" --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
  else
    info "No running container found."
  fi
}

# ── main ─────────────────────────────────────────────────────────────
case "${1:-}" in
  up)       cmd_up ;;
  shell)    cmd_shell ;;
  down)     cmd_down ;;
  rebuild)  cmd_rebuild ;;
  status)   cmd_status ;;
  "")
    # Default: start + shell
    cmd_up
    cmd_shell
    ;;
  *)
    error "Unknown command: $1"
    echo "Usage: $0 {up|shell|down|rebuild|status}"
    exit 1
    ;;
esac
