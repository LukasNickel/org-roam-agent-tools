# Org-roam agent tools backlog

The capture and lookup workflows are usable from unrelated Agent Shell
projects through globally discovered skills and a separately installed runtime.
The remaining items are optional provenance and data-model improvements.

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
  - Return a stable summary of these details from `capabilities` instead of
    only the template key and short description.

## Sandbox integration

- [x] Document and streamline access to the running Emacs server from a
  sandboxed agent session.
  - Treat `Operation not permitted` while connecting to an existing Emacs
    socket as a sandbox restriction, not evidence that Emacs is stopped.
  - Do not allowlist the Emacs Unix socket: socket access is process-wide and
    `emacsclient --eval` would expose arbitrary Emacs Lisp execution.
  - Copy the privileged runtime into =~/.local/libexec/org-roam-agent/v1=
    instead of linking it to an agent-writable checkout.
  - Use an exact command-prefix rule for the installed executable and its
    supported subcommands; use per-invocation prompts while developing.
  - Treat this command-rule integration as Codex-specific; other agent hosts
    need an equivalent least-privilege execution mechanism.
  - Have both skills invoke the exact absolute path returned by =command -v=
    so the rule matches predictably.
  - Have both skills request outside-sandbox execution from the outset rather
    than first making a socket request that is expected to fail.
  - Treat a remaining permission error as a host-configuration problem rather
    than probing the socket or changing Emacs.

## Cross-project capture and installation

- [x] Support promoting research from an unrelated project into permanent
  Org-roam content.
  - Keep an Agent Shell transcript as the normal provenance source.
  - Resolve the active session's absolute transcript path even when its Agent
    Shell project root is outside the Org tree.
  - Extend explicit fallback validation to external project transcripts without
    accepting arbitrary files: require an =.agent-shell/transcripts= location
    and a header matching the requested session ID.
  - Snapshot external transcripts into the synchronized Org tree instead of
    leaving device-local links in permanent notes.

- [x] Archive capture provenance portably on successful finalization.
  - Stage an immutable transcript snapshot when preparing the capture.
  - Insert the final relative link before presenting the capture buffer.
  - Materialize the content-addressed snapshot beneath
    =provenance/agent-shell= before Org saves the finalized note.
  - Abort without leaving an archived snapshot, and prevent saving the note if
    archival fails.
  - Deduplicate identical snapshots for the same session and year.

- [ ] Investigate an on-demand conversation export when no Agent Shell
  transcript exists.
  - Treat such an export as a distinct provenance type rather than labeling it
    as an Agent Shell transcript.
  - Do not claim completeness unless the full conversation is actually
    available.

- [x] Make the helper tools discoverable independently of the current project's
  Git root.
  - Copy the runtime into the versioned
    =~/.local/libexec/org-roam-agent/v1= directory and link its command from
    =~/.local/bin=.
  - Link the skills beneath =~/.agents/skills= so skill development remains
    live without making the privileged runtime agent-writable.
  - The global capture and lookup skills resolve the installed command from
    =PATH= and then use the returned absolute path.
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

- [x] Keep compiled Elisp artifacts out of the runtime and repository.
  - The stale =org-roam-agent.elc= is absent and =*.elc= is ignored.
  - Installation copies the source =org-roam-agent.el=, and the wrapper loads
    that neighboring source file explicitly.
