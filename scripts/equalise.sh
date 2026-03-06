#!/usr/bin/env bash
#
# equalise.sh — Recursively equalise tmux pane sizes while preserving layout structure.
#
# Usage: bash scripts/equalise.sh
#
# Parses the tmux layout string, rebuilds it with equal dimensions at each
# split level, and applies it atomically via `tmux select-layout`.

set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/layout_lib.sh"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local raw_layout
    raw_layout=$(tmux display-message -p '#{window_layout}')

    if [[ -z "$raw_layout" ]]; then
        echo "Error: could not get tmux layout. Are you inside a tmux session?" >&2
        exit 1
    fi

    # Strip checksum prefix: "xxxx,<layout_body>"
    local layout_body="${raw_layout#*,}"

    # Parse
    LAYOUT_STR="$layout_body"
    POS=0
    parse_node
    local root_id="$RETVAL"

    # Equalize from root dimensions
    equalise_node "$root_id" "${NODE_W[$root_id]}" "${NODE_H[$root_id]}" "${NODE_X[$root_id]}" "${NODE_Y[$root_id]}"

    # Serialize
    serialize_node "$root_id"
    local new_body="$RETVAL"

    # Checksum + apply
    local checksum
    checksum=$(compute_checksum "$new_body")
    tmux select-layout "${checksum},${new_body}"
}

main "$@"
