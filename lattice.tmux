#! /usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$CURRENT_DIR/scripts/helpers.sh"

main() {
    tmux bind-key $(get_tmux_option "@lattce-equalise" "=") "run -b '$CURRENT_DIR/scripts/equalise.sh'"
}

main
