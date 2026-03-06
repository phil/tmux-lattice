#!/usr/bin/env bash
#
# push_right.sh — Move the current pane to a full-height column on the far right.
#
# Usage: bash scripts/push_right.sh
#
# Manipulates the tmux layout string directly to extract the active pane from
# its current position and re-attach it as a full-height pane on the right,
# without using break-pane or join-pane.

set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/layout_lib.sh"
source "$CURRENT_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# Find pane node
# ---------------------------------------------------------------------------

# Walk the tree to find the leaf node for a given tmux pane ID.
# Sets RETVAL to the node ID, or "" if not found.
find_pane_node() {
    local target_pane="$1"
    local start_id="${2:-0}"

    local ntype="${NODE_TYPE[$start_id]}"

    if [[ "$ntype" == "leaf" ]]; then
        if [[ "${NODE_PANEID[$start_id]}" == "$target_pane" ]]; then
            RETVAL="$start_id"
            return 0
        fi
        RETVAL=""
        return 1
    fi

    local children=(${NODE_CHILDREN[$start_id]})
    local child
    for child in "${children[@]}"; do
        if find_pane_node "$target_pane" "$child"; then
            return 0
        fi
    done

    RETVAL=""
    return 1
}

# ---------------------------------------------------------------------------
# Remove pane from tree
# ---------------------------------------------------------------------------

# Remove a leaf node from the tree, collapsing single-child split nodes.
# $1 = node ID to remove
# $2 = current root ID
# Sets RETVAL to the (possibly new) root ID after removal.
remove_pane_from_tree() {
    local node_id="$1"
    local root_id="$2"
    local parent_id="${NODE_PARENT[$node_id]}"

    # If there's no parent, this is the only pane — nothing to remove.
    if [[ -z "$parent_id" ]]; then
        RETVAL="$root_id"
        return
    fi

    # Remove node_id from parent's children list.
    local old_children=(${NODE_CHILDREN[$parent_id]})
    local new_children=()
    local child
    for child in "${old_children[@]}"; do
        if [[ "$child" != "$node_id" ]]; then
            new_children+=("$child")
        fi
    done
    NODE_CHILDREN[$parent_id]="${new_children[*]:-}"

    # If parent now has exactly one child, collapse it out of the tree.
    if [[ ${#new_children[@]} -eq 1 ]]; then
        local survivor="${new_children[0]}"
        local grandparent_id="${NODE_PARENT[$parent_id]}"

        if [[ -z "$grandparent_id" ]]; then
            # Parent was root; survivor becomes root.
            NODE_PARENT[$survivor]=""
            RETVAL="$survivor"
        else
            # Replace parent with survivor in grandparent's children list.
            local gp_children=(${NODE_CHILDREN[$grandparent_id]})
            local new_gp_children=()
            for child in "${gp_children[@]}"; do
                if [[ "$child" == "$parent_id" ]]; then
                    new_gp_children+=("$survivor")
                else
                    new_gp_children+=("$child")
                fi
            done
            NODE_CHILDREN[$grandparent_id]="${new_gp_children[*]}"
            NODE_PARENT[$survivor]="$grandparent_id"
            RETVAL="$root_id"
        fi
    else
        RETVAL="$root_id"
    fi
}

# ---------------------------------------------------------------------------
# Check if already in position
# ---------------------------------------------------------------------------

# Returns 0 if the target node is already a full-height pane on the far right
# (i.e. the root is a horizontal split and target is the last child).
already_pushed_right() {
    local root_id="$1"
    local target_node_id="$2"

    [[ "${NODE_TYPE[$root_id]}" != "horizontal" ]] && return 1

    local children=(${NODE_CHILDREN[$root_id]})
    local last_child="${children[-1]}"

    [[ "$last_child" != "$target_node_id" ]] && return 1
    [[ "${NODE_TYPE[$target_node_id]}" != "leaf" ]] && return 1
    [[ "${NODE_H[$target_node_id]}" -eq "${NODE_H[$root_id]}" ]] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Build push-right layout
# ---------------------------------------------------------------------------

# Assembles the final layout: remaining tree on the left, target pane full
# height on the right.  Creates a new synthetic root node.
# $1 = remaining root ID, $2 = target node ID, $3 = total_w, $4 = total_h
# Sets RETVAL to the new synthetic root ID.
build_push_right_layout() {
    local remaining_root="$1"
    local target_node="$2"
    local total_w="$3"
    local total_h="$4"

    # Determine right-pane width.
    local right_w="${NODE_W[$target_node]}"

    # Fallback: honour @lattice_push_right_width_pct (default 40).
    if [[ -z "$right_w" || "$right_w" -le 0 ]]; then
        local pct
        pct=$(get_tmux_option "@lattice_push_right_width_pct" "40")
        right_w=$(( total_w * pct / 100 ))
    fi

    # Clamp: ensure both sides have at least 1 column.
    local min_left=1
    local max_right=$(( total_w - min_left - 1 ))
    if [[ $right_w -ge $max_right ]]; then
        right_w=$(( total_w / 2 ))
    fi
    if [[ $right_w -le 0 ]]; then
        right_w=$(( total_w / 2 ))
    fi

    local left_w=$(( total_w - right_w - 1 ))  # 1 = divider border

    local new_root

    if [[ "${NODE_TYPE[$remaining_root]}" == "horizontal" ]]; then
        # The remaining tree is already a horizontal split.  Adding a new
        # horizontal wrapper would produce a nested horizontal inside a
        # horizontal (e.g. {{p1,p2},p3}), which causes equalise to distribute
        # widths at the wrong level.  Instead, graft the target directly onto
        # the existing horizontal node so the result is a flat split ({p1,p2,p3}).
        NODE_CHILDREN[$remaining_root]="${NODE_CHILDREN[$remaining_root]} $target_node"
        NODE_PARENT[$target_node]="$remaining_root"
        new_root="$remaining_root"

        # Reflow all children (including target) across the full window width
        # so they share space evenly.  equalise_node handles the geometry.
        equalise_node "$new_root" "$total_w" "$total_h" 0 0
    else
        # Remaining tree is a vertical split or a single leaf — safe to wrap.
        equalise_node "$remaining_root" "$left_w" "$total_h" 0 0

        # Set target node geometry: full height, anchored to the right.
        NODE_W[$target_node]=$right_w
        NODE_H[$target_node]=$total_h
        NODE_X[$target_node]=$(( left_w + 1 ))
        NODE_Y[$target_node]=0

        new_root=$NEXT_ID
        NEXT_ID=$((NEXT_ID + 1))
        NODE_TYPE[$new_root]="horizontal"
        NODE_CHILDREN[$new_root]="$remaining_root $target_node"
        NODE_PARENT[$new_root]=""
        NODE_W[$new_root]=$total_w
        NODE_H[$new_root]=$total_h
        NODE_X[$new_root]=0
        NODE_Y[$new_root]=0

        NODE_PARENT[$remaining_root]="$new_root"
        NODE_PARENT[$target_node]="$new_root"
    fi

    RETVAL="$new_root"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local active_pane
    active_pane=$(tmux display-message -p '#{pane_id}')
    # Strip the leading '%' to get the numeric ID used in layout strings.
    local active_pane_num="${active_pane#%}"

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

    # Guard: nothing to do if there's only one pane.
    if [[ "${NODE_TYPE[$root_id]}" == "leaf" ]]; then
        exit 0
    fi

    # Build parent map for upward tree navigation.
    build_parent_map "$root_id" ""

    # Find the node for the active pane.
    if ! find_pane_node "$active_pane_num" "$root_id"; then
        echo "Error: could not find pane $active_pane in layout." >&2
        exit 1
    fi
    local target_node="$RETVAL"

    local total_w="${NODE_W[$root_id]}"
    local total_h="${NODE_H[$root_id]}"

    # Guard: already in position.
    if already_pushed_right "$root_id" "$target_node"; then
        exit 0
    fi

    # Remove target pane from the tree.
    remove_pane_from_tree "$target_node" "$root_id"
    local remaining_root="$RETVAL"

    # Build new layout with target as full-height right pane.
    build_push_right_layout "$remaining_root" "$target_node" "$total_w" "$total_h"
    local new_root="$RETVAL"

    # Serialize and apply.
    serialize_node "$new_root"
    local new_body="$RETVAL"

    local checksum
    checksum=$(compute_checksum "$new_body")
    tmux select-layout "${checksum},${new_body}"
}

main "$@"
