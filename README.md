# Tmux-Lattice

The missing layout key bindings for tmux. Equalise panes in the current window with a single key binding. All panes will resize to best fit the current window size.

## Installation Using Tmux Plugin Manager (TPM)

Add the following line to your ~/.tmux.conf (or ~/.config/tmux/tmux.conf) file:

```
set -g @plugin 'phil/tmux-lattice'
```

## Equalise Panes

![Lattice Equalise](https://github.com/phil/tmux-lattice/blob/main/resources/tmux-lattice.gif?raw=true)

- `prefix` + `=`: Equalise panes in the current window

```
# Override the default key binding for equalising panes (optional)
set-option -g @lattice_equalise_key 'M' # default: '='
```
