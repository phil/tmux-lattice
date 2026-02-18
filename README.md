# Tmux-Lattice

The missing layout key bindings for tmux. Equalise panes in the current window with a single key binding. All panes will resize to best fit the current window size.

## Installation Using Tmux Plugin Manager (TPM)

Add the following line to your ~/.tmux.conf (or ~/.config/tmux/tmux.conf) file:

```
set -g @plugin 'phil/tmux-lattice'
```

## Key Bindings

- prfix + =: Equalise panes in the current window

```
set-option -g @lattice_equalise_key 'M' # default: '='
```
