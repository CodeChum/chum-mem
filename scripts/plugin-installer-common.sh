#!/usr/bin/env bash
set -euo pipefail

PLUGIN_INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

chum_memory_profile_url() {
  local profile="${1:-local}"
  case "$profile" in
    local)
      printf '%s\n' "http://localhost:63001/mcp"
      ;;
    production|prod)
      # Team server. Set CHUM_MEMORY_API_URL (e.g. https://chum-mem.gradechum.com)
      # before running the installer; the plugin hooks read the same variable.
      if [[ -z "${CHUM_MEMORY_API_URL:-}" ]]; then
        echo "CHUM_MEMORY_API_URL is not set; export it to your team's chum-mem server URL first" >&2
        exit 1
      fi
      printf '%s\n' "${CHUM_MEMORY_API_URL%/}/mcp"
      ;;
    *)
      echo "Unsupported profile: $profile (use: local|production)" >&2
      return 1
      ;;
  esac
}

chum_memory_require_command() {
  local command_name="$1"
  local install_hint="$2"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is not installed or not on PATH." >&2
    echo "$install_hint" >&2
    return 1
  fi
}

chum_memory_repo_root() {
  printf '%s\n' "$PLUGIN_INSTALLER_ROOT"
}
