#! /usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$CURRENT_DIR/scripts/helpers.sh"

main() {
    tmux display-message "Lattice: Initialising key bindings..."
    tmux bind-key $(get_tmux_option "@lattice_equalise_key" "=") "run -b '$CURRENT_DIR/scripts/equalise.sh'"
    tmux bind-key $(get_tmux_option "@lattice_push_right_key" ">") "run -b '$CURRENT_DIR/scripts/push_right.sh'"
}

main
