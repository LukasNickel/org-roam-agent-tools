# Org-roam agent tools

Personal command-line and agent-skill interfaces for retrieving and capturing
knowledge through a configured, running Org-roam Emacs instance.

## Install

Keep this repository at a stable path. From its root, create global symlinks:

```sh
mkdir -p ~/.local/bin ~/.agents/skills

ln -sfn "$PWD/tools/org-roam-agent" ~/.local/bin/org-roam-agent
ln -sfn "$PWD/skills/org-roam-lookup" ~/.agents/skills/org-roam-lookup
ln -sfn "$PWD/skills/org-roam-capture" ~/.agents/skills/org-roam-capture
```

Ensure `~/.local/bin` is on `PATH`, then start a new agent session so it can
discover the global skills. Verify the command against the running Emacs
server:

```sh
command -v org-roam-agent
org-roam-agent capabilities
```

The symlinks keep the installation current as this checkout changes. Moving
the repository requires recreating them.

To uninstall:

```sh
unlink ~/.local/bin/org-roam-agent
unlink ~/.agents/skills/org-roam-lookup
unlink ~/.agents/skills/org-roam-capture
```

## Requirements

- Bash, Python 3, ripgrep, GNU `realpath`, and `emacsclient`
- a running Emacs server with Org-roam configured
- Agent Shell for automatic capture-transcript provenance

See [the command reference](tools/README.org) for usage and behavior.

## Test

```sh
emacs --batch -Q -L tools \
  -l tools/org-roam-agent-tests.el \
  -f ert-run-tests-batch-and-exit
```
