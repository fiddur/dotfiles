# Dotfiles

Personal configuration files managed with a bare git repository.

## What's included

- `.tmux.conf` - tmux configuration (Alt+number window switching, copy-mode bindings)
- `.config/alacritty/alacritty.toml` - Alacritty terminal config (Shift+Enter fix for tmux)
- `.bashrc.common` - Shared bash settings:
  - EDITOR, NODE_OPTIONS, NVM, pnpm
  - Claude Code helpers (`cr`, `cl`, tab completion)
  - `dot` alias for dotfiles management
  - `turbo` alias

## Setup on a new machine

```bash
# 1. Clone the bare repository
git clone --bare git@github.com:fiddur/dotfiles.git ~/.dotfiles

# 2. Define the alias temporarily
alias dot='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'

# 3. Checkout the files
dot checkout

# If checkout fails due to existing files, back them up first:
mkdir -p ~/.dotfiles-backup
dot checkout 2>&1 | grep -E "^\s+" | awk '{print $1}' | xargs -I{} mv {} ~/.dotfiles-backup/
dot checkout

# 4. Configure git to ignore untracked files
dot config status.showUntrackedFiles no
```

## Post-setup

Add this line near the end of your local `~/.bashrc` (before any machine-specific settings):

```bash
# Load common settings from dotfiles
[ -f ~/.bashrc.common ] && . ~/.bashrc.common
```

Then remove any duplicate settings from `.bashrc` that are now in `.bashrc.common` (NVM, pnpm, NODE_OPTIONS, etc.).

## Aurboda

The dotfiles include scripts and cron jobs for pushing data to [Aurboda](https://aurboda.net).

### Config

Create `~/.config/aurboda/config`:

```bash
AURBODA_BASE_URL=https://aurboda.net
AURBODA_TOKEN=your-token-here
```

Get your token from Aurboda → Settings → Data Sources.

### Install cron jobs

```bash
crontab -l | cat - ~/.config/cron/aurboda.crontab | crontab -
```

This installs:
- **Workstation heartbeat** — reports active/display state every minute
- **ActivityWatch push** — pushes window activity to Aurboda every 5 minutes (requires [ActivityWatch](https://activitywatch.net/) to be installed and running)

## Daily usage

The `dot` alias works like regular git:

```bash
dot status                  # Check status
dot add ~/.some-config      # Stage a file
dot commit -m "message"     # Commit
dot push                    # Push to remote
```

## Claude Code helpers

- `cl` - List Claude sessions with custom names in current directory
- `cr` - Resume a Claude session (with tab completion)
  - `cr <TAB>` - Autocomplete session names
  - `cr "Session Name"` - Resume and rename tmux window
