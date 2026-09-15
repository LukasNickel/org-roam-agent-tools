# Org-roam agent tools

Personal command-line and agent-skill interfaces for retrieving and capturing
knowledge through a configured, running Org-roam Emacs instance.

## Install

Keep this repository at a stable path. From its root, install a private copy of
the runtime and create global links for the command and skills:

```sh
runtime_dir="$HOME/.local/libexec/org-roam-agent/v1"

install -d "$runtime_dir" ~/.local/bin ~/.agents/skills
install -m 0755 tools/org-roam-agent "$runtime_dir/org-roam-agent"
install -m 0644 tools/org-roam-agent.el "$runtime_dir/org-roam-agent.el"
install -m 0644 tools/org-roam-agent-search-text.py \
  "$runtime_dir/org-roam-agent-search-text.py"

ln -sfn "$runtime_dir/org-roam-agent" ~/.local/bin/org-roam-agent
ln -sfn "$PWD/skills/org-roam-lookup" ~/.agents/skills/org-roam-lookup
ln -sfn "$PWD/skills/org-roam-capture" ~/.agents/skills/org-roam-capture
```

The runtime is copied so a project-scoped agent cannot modify code that is
allowed to run outside its sandbox. Re-run the three `install` commands after
updating this repository. The skill links remain live and require recreating
only if the repository moves.

Ensure `~/.local/bin` is on `PATH`. Verify the installed path and command
against the running Emacs server:

```sh
command -v org-roam-agent
org-roam-agent capabilities
```

Start a new agent session after installing or changing the skills.

### Codex sandbox permission

Do not give sandboxed processes direct access to the Emacs server socket:
`emacsclient` can evaluate arbitrary Emacs Lisp. Instead, allow only the
installed, bounded command interface to run outside the sandbox.

The command-rule mechanism below is specific to Codex. The helper and skills
do not otherwise depend on Codex, but another agent host needs an equivalent
least-privilege mechanism for running the installed interface outside its
sandbox. On Codex, the skills request this execution route on the first helper
invocation rather than attempting a socket connection inside the sandbox.

First run `command -v org-roam-agent` and copy its absolute output. Create
`~/.codex/rules/org-roam-agent.rules` and paste the following rule into it,
replacing `/home/YOU/.local/bin/org-roam-agent` with that exact output:

```python
prefix_rule(
    pattern = [
        "/home/YOU/.local/bin/org-roam-agent",
        [
            "capabilities",
            "search-nodes",
            "search-text",
            "context",
            "links",
            "capture-status",
            "prepare-capture",
        ],
    ],
    decision = "allow",
    justification = "Bounded access to Org-roam through the installed helper",
)
```

Use `decision = "prompt"` instead while developing or whenever the command
still resolves into a writable checkout. This preserves confirmation for each
outside-sandbox invocation without requiring a failed sandbox attempt first.
Restart the agent after changing a rules file. Test the rule, again using the
exact absolute command path:

```sh
codex execpolicy check --pretty \
  --rules ~/.codex/rules/org-roam-agent.rules \
  -- /home/YOU/.local/bin/org-roam-agent capabilities
```

To uninstall:

```sh
unlink ~/.local/bin/org-roam-agent
unlink ~/.agents/skills/org-roam-lookup
unlink ~/.agents/skills/org-roam-capture
rm -r ~/.local/libexec/org-roam-agent/v1
```

## Requirements

- Bash, Python 3, ripgrep, GNU `realpath`, and `emacsclient`
- a running Emacs server with Org-roam configured
- Agent Shell for automatic capture-transcript provenance

Successful agent captures archive an immutable, content-addressed transcript
snapshot beneath `provenance/agent-shell` in the configured Org-roam directory.
Captured notes use portable relative links to these snapshots, so provenance
travels with a synchronized Org collection. Aborted captures leave no archived
snapshot.

See [the command reference](tools/README.org) for usage and behavior.

## Test

```sh
emacs --batch -Q -L tools \
  -l tools/org-roam-agent-tests.el \
  -f ert-run-tests-batch-and-exit
```
