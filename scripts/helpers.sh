debug() {
    echo "$1" >&2
}

# Get Tmux option value, if not set, use default value
# checks for local, then global options
#
# Usage
# get_tmux_option <option> <default_value>
get_tmux_option() {
    local option="$1"
    local default_value="$2"
    local option_value=$(tmux show-option -qv "$option")

    if [ -z "$option_value" ]; then
        option_value=$(tmux show-option -gqv "$option")
    fi

    if [ -z "$option_value" ]; then
        echo "$default_value"
    else
        echo "$option_value"
    fi
}
