#!/usr/bin/env bash
#
# equalize.sh — Recursively equalize tmux pane sizes while preserving layout structure.
#
# Usage: bash scripts/equalize.sh
#
# Parses the tmux layout string, rebuilds it with equal dimensions at each
# split level, and applies it atomically via `tmux select-layout`.

set -euo pipefail

# ---------------------------------------------------------------------------
# Tree storage
#
# Each node has an integer ID. Properties stored in associative arrays.
#
#   NODE_TYPE[$id]     = "leaf" | "horizontal" | "vertical"
#   NODE_CHILDREN[$id] = space-separated child IDs (for splits)
#   NODE_PANEID[$id]   = tmux pane ID (for leaves)
#   NODE_W[$id], NODE_H[$id], NODE_X[$id], NODE_Y[$id] = geometry
# ---------------------------------------------------------------------------

declare -A NODE_TYPE NODE_CHILDREN NODE_PANEID NODE_W NODE_H NODE_X NODE_Y
NEXT_ID=0

# ---------------------------------------------------------------------------
# Parser
#
# Uses global variables for return values to avoid subshell issues.
#   LAYOUT_STR / POS  — input string and cursor
#   RETVAL             — generic return value from parse functions
# ---------------------------------------------------------------------------

LAYOUT_STR=""
POS=0
RETVAL=""

parse_int() {
    local num=""
    while [[ $POS -lt ${#LAYOUT_STR} ]]; do
        local ch="${LAYOUT_STR:$POS:1}"
        if [[ "$ch" =~ [0-9] ]]; then
            num="${num}${ch}"
            POS=$((POS + 1))
        else
            break
        fi
    done
    RETVAL="$num"
}

expect_char() {
    local expected="$1"
    local actual="${LAYOUT_STR:$POS:1}"
    if [[ "$actual" != "$expected" ]]; then
        echo "Parse error at position $POS: expected '$expected', got '$actual'" >&2
        exit 1
    fi
    POS=$((POS + 1))
}

# Parse one node (leaf or split). Sets RETVAL to the new node ID.
parse_node() {
    local id=$NEXT_ID
    NEXT_ID=$((NEXT_ID + 1))

    # Parse dimensions: WxH,X,Y
    parse_int; local w="$RETVAL"
    expect_char "x"
    parse_int; local h="$RETVAL"
    expect_char ","
    parse_int; local x="$RETVAL"
    expect_char ","
    parse_int; local y="$RETVAL"

    NODE_W[$id]=$w
    NODE_H[$id]=$h
    NODE_X[$id]=$x
    NODE_Y[$id]=$y

    local ch="${LAYOUT_STR:$POS:1}"

    if [[ "$ch" == "{" || "$ch" == "[" ]]; then
        local close_bracket
        if [[ "$ch" == "{" ]]; then
            NODE_TYPE[$id]="horizontal"
            close_bracket="}"
        else
            NODE_TYPE[$id]="vertical"
            close_bracket="]"
        fi
        POS=$((POS + 1))  # consume opener

        # Parse first child
        parse_node
        local children="$RETVAL"

        # Parse remaining children separated by ','
        while [[ "${LAYOUT_STR:$POS:1}" == "," ]]; do
            POS=$((POS + 1))  # consume ','
            parse_node
            children="$children $RETVAL"
        done

        expect_char "$close_bracket"
        NODE_CHILDREN[$id]="$children"
    elif [[ "$ch" == "," ]]; then
        # Leaf node with pane ID
        POS=$((POS + 1))  # consume ','
        parse_int
        NODE_TYPE[$id]="leaf"
        NODE_PANEID[$id]="$RETVAL"
    else
        # Leaf at end or before a delimiter
        NODE_TYPE[$id]="leaf"
        NODE_PANEID[$id]=""
    fi

    RETVAL="$id"
}

# ---------------------------------------------------------------------------
# Equalize
# ---------------------------------------------------------------------------

equalize_node() {
    local id=$1 avail_w=$2 avail_h=$3 x=$4 y=$5

    NODE_W[$id]=$avail_w
    NODE_H[$id]=$avail_h
    NODE_X[$id]=$x
    NODE_Y[$id]=$y

    local ntype="${NODE_TYPE[$id]}"
    [[ "$ntype" == "leaf" ]] && return

    local children=(${NODE_CHILDREN[$id]})
    local n=${#children[@]}

    if [[ "$ntype" == "horizontal" ]]; then
        local borders=$((n - 1))
        local usable=$((avail_w - borders))
        local base=$((usable / n))
        local remainder=$((usable - base * n))

        local i cx=$x
        for ((i = 0; i < n; i++)); do
            local child_w=$base
            if [[ $i -ge $((n - remainder)) && $remainder -gt 0 ]]; then
                child_w=$((base + 1))
            fi
            equalize_node "${children[$i]}" "$child_w" "$avail_h" "$cx" "$y"
            cx=$((cx + child_w + 1))
        done
    else
        local borders=$((n - 1))
        local usable=$((avail_h - borders))
        local base=$((usable / n))
        local remainder=$((usable - base * n))

        local i cy=$y
        for ((i = 0; i < n; i++)); do
            local child_h=$base
            if [[ $i -ge $((n - remainder)) && $remainder -gt 0 ]]; then
                child_h=$((base + 1))
            fi
            equalize_node "${children[$i]}" "$avail_w" "$child_h" "$x" "$cy"
            cy=$((cy + child_h + 1))
        done
    fi
}

# ---------------------------------------------------------------------------
# Serializer — builds result in RETVAL to avoid subshells
# ---------------------------------------------------------------------------

serialize_node() {
    local id=$1
    local ntype="${NODE_TYPE[$id]}"
    local result="${NODE_W[$id]}x${NODE_H[$id]},${NODE_X[$id]},${NODE_Y[$id]}"

    if [[ "$ntype" == "leaf" ]]; then
        local pane_id="${NODE_PANEID[$id]}"
        if [[ -n "$pane_id" ]]; then
            result="${result},${pane_id}"
        fi
    elif [[ "$ntype" == "horizontal" ]]; then
        local children=(${NODE_CHILDREN[$id]})
        local i
        result="${result}{"
        for ((i = 0; i < ${#children[@]}; i++)); do
            if [[ $i -gt 0 ]]; then
                result="${result},"
            fi
            serialize_node "${children[$i]}"
            result="${result}${RETVAL}"
        done
        result="${result}}"
    elif [[ "$ntype" == "vertical" ]]; then
        local children=(${NODE_CHILDREN[$id]})
        local i
        result="${result}["
        for ((i = 0; i < ${#children[@]}; i++)); do
            if [[ $i -gt 0 ]]; then
                result="${result},"
            fi
            serialize_node "${children[$i]}"
            result="${result}${RETVAL}"
        done
        result="${result}]"
    fi

    RETVAL="$result"
}

# ---------------------------------------------------------------------------
# Checksum — tmux's rotate-right-then-add algorithm (16-bit)
# ---------------------------------------------------------------------------

compute_checksum() {
    local layout_body="$1"
    local csum=0
    local len=${#layout_body}

    for ((i = 0; i < len; i++)); do
        local ch="${layout_body:$i:1}"
        local val
        val=$(printf '%d' "'$ch")
        csum=$(( (csum >> 1) | ((csum & 1) << 15) ))
        csum=$(( (csum + val) & 0xFFFF ))
    done

    printf '%04x' "$csum"
}

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
    equalize_node "$root_id" "${NODE_W[$root_id]}" "${NODE_H[$root_id]}" "${NODE_X[$root_id]}" "${NODE_Y[$root_id]}"

    # Serialize
    serialize_node "$root_id"
    local new_body="$RETVAL"

    # Checksum + apply
    local checksum
    checksum=$(compute_checksum "$new_body")
    tmux select-layout "${checksum},${new_body}"
}

main "$@"
