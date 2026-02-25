#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# colors.sh - Color output helpers for terminal scripts
# ---------------------------------------------------------------------------

# Respect the NO_COLOR convention (https://no-color.org/)
if [[ -n "${NO_COLOR:-}" ]]; then
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    NC=""
else
    RED="\033[0;31m"
    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    BLUE="\033[0;34m"
    NC="\033[0m" # No Color
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$*"
}

success() {
    printf "${GREEN}[OK]${NC}   %s\n" "$*"
}

warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$*"
}

error() {
    printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
}

header() {
    local msg="$*"
    local len=${#msg}
    local border
    border=$(printf '=%.0s' $(seq 1 $((len + 4))))
    printf "\n${BLUE}%s${NC}\n" "$border"
    printf "${BLUE}| %s |${NC}\n" "$msg"
    printf "${BLUE}%s${NC}\n\n" "$border"
}
