# Org-roam agent tools backlog

The current capture workflow is usable when Agent Shell runs inside the Org
project. These are hardening and portability improvements.

## Capture lifecycle

- [x] Track whether a prepared capture was finalized or aborted.
  - Give each prepared capture a request ID.
  - Expose a bounded status query for that request.
  - Do not report a note as created merely because its capture buffer was
    prepared.

## Transcript provenance

- [x] Make `CODEX_SESSION_ID` the normal provenance path in documentation and
  agent instructions.
  - Omit `--session-id` when the environment variable is available; the helper
    already uses it by default.
  - Do not inspect `.agent-shell/transcripts` unless automatic resolution fails
    or reports an ambiguous session.
  - Document how this behaves when multiple agent-shell sessions are running.
- [x] Allow explicit transcript selection when resumed or crashed sessions make
  a session ID ambiguous.
  - Add an optional `--transcript-file` argument.
  - Keep automatic selection as the normal path.
  - Validate that an explicitly selected file belongs to the requested session
    and is inside the expected transcript directory.
  - Support transcripts beneath nested Agent Shell project roots rather than
    assuming the Org-roam root is always the Agent Shell project root.

## Capture templates

- [x] Describe the configured capture templates well enough for an agent to
  choose one deliberately.
  - Document the standard template's destination, file header, and intended use
    for ordinary knowledge notes.
  - Document when each non-standard template should be selected.
  - Consider returning a stable summary of these details from `capabilities`
    instead of only the template key and short description.

## Sandbox integration

- [ ] Document and streamline access to the running Emacs server from a
  sandboxed agent session.
  - Treat `Operation not permitted` while connecting to an existing Emacs
    socket as a sandbox restriction, not evidence that Emacs is stopped.
  - Investigate a least-privilege permission profile that allows only the
    configured Emacs Unix socket.
  - If configuration is unavailable, retry the unchanged helper command with
    explicit approval rather than probing or changing Emacs.

## Cross-project capture and installation

- [x] Support promoting research from an unrelated project into permanent
  Org-roam content.
  - Keep an Agent Shell transcript as the normal provenance source.
  - Resolve the active session's absolute transcript path even when its Agent
    Shell project root is outside the Org tree.
  - Extend explicit fallback validation to external project transcripts without
    accepting arbitrary files: require an =.agent-shell/transcripts= location
    and a header matching the requested session ID.
  - External transcripts remain linked in place; durable archival can be added
    later as an explicit operation.

- [ ] Investigate an on-demand conversation export when no Agent Shell
  transcript exists.
  - Treat such an export as a distinct provenance type rather than labeling it
    as an Agent Shell transcript.
  - Do not claim completeness unless the full conversation is actually
    available.

- [x] Make the helper tools discoverable independently of the current project's
  Git root.
  - Install the command into =~/.local/bin= and the skills beneath
    =~/.agents/skills= using symlinks documented in the project README.
  - The global capture and lookup skills resolve the installed command from
    =PATH=.
  - Retain a convenient development path for editing and testing the tools in
    this repository without making other projects depend on its layout.

## Agent section identity

- [ ] Decide whether the tagged agent section in a newly created file node
  should receive its own Org ID.
  - An ID would make the agent-authored section independently linkable and
    queryable as an Org-roam node.
  - Omitting it keeps a simple one-node-per-file structure.
  - Preserve the rule that agent-authored text lives in an `:agent:` tagged
    section either way.

## Compiled Elisp

- [ ] Remove the unused stale `org-roam-agent.elc` and document how compiled
  artifacts are handled.
  - Add an ignore rule if byte-compiled files should remain local build output.
  - Continue loading the source `.el` explicitly unless an intentional build or
    installation step is introduced.
