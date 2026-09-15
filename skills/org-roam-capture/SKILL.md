---
name: org-roam-capture
description: Capture durable findings and decisions as new agent-authored Org-roam content when the user asks to save them, or occasionally suggest capture after a substantial discussion produces a reusable conclusion. Do not use for general note lookup, tentative ideas, routine status, or transient details.
---

# Org-roam capture

Create only new content through the interactive Org-roam capture interface in
the user's running Emacs session. Existing note text remains unchanged.

## Suggest capture selectively

Suggest capture at a natural conclusion when the discussion produced a durable,
standalone insight that is likely to matter in another context. Make one brief,
low-pressure suggestion after answering the user's primary request. If the user
declines or ignores it, leave that topic alone.

A suggestion is not authorization to prepare a capture.

## Locate the interface

Resolve `org-roam-agent` from `PATH` with `command -v`. Stop and explain the
missing global installation if the command is absent or not executable.

Run `capabilities` before designing a capture. Use its `default_template` for a
new file node unless the user specifies another template. Use each template's
configured `purpose`, target, and initial-content preview to explain deliberate
non-default choices. Do not invent a purpose when capabilities returns null.
Treat an Emacs connection error containing `Operation not permitted` as a
sandbox restriction: retry the unchanged command with narrowly scoped approval
to reach the running Emacs server.

## Design the capture

Search node titles, aliases, and tags for the main concepts. Inspect bounded
context only for promising candidates. This lookup serves capture placement,
deduplication, and linking; leave general note-finding requests to a retrieval
skill.

When a promising existing node is found, call `links` with its stable ID to
inspect explicit backlinks and outgoing neighbors. Use semantic search to find
additional related notes when the graph neighborhood is sparse. Include only
relationships that remain clear after bounded context inspection.

Choose a new file node for a distinct concept. Choose a child node when the new
content clearly belongs beneath an existing node. Add a small set of confident
Org ID links to related nodes, inline when they support a sentence or in a short
`Related` subsection otherwise. Weak relationships do not become links.

Write a concise synthesis of the durable findings, important rationale, and
caveats. Make the note understandable without the conversation. Omit discussion
chronology, repetition, abandoned alternatives, and close imitation of the
user's wording unless exact wording matters.

Present the complete proposal before preparing it:

- mode: new file node or child node;
- parent title and stable ID for a child node;
- node title and, for a new file, section title;
- template key, description, configured purpose, and destination for a new
  file, explicitly identifying whether it is the configured default and any
  relevant tags or structure from its initial content; for a child node, state
  that templates do not apply;
- related nodes that will be linked;
- complete proposed Org body.

Wait for explicit confirmation. If the user changes any part, present the
revised proposal and wait again.

## Prepare the confirmed capture

After confirmation, write exactly the confirmed Org body to a temporary file.
Call `prepare-capture` with the confirmed fields. Omit `--session-id` when
`CODEX_SESSION_ID` is available; the helper resolves and validates the matching
agent-shell transcript. Inspect transcript files only if automatic provenance
resolution fails. If it reports multiple transcripts, select the intended file
beneath an `.agent-shell/transcripts` directory and retry with
`--transcript-file`; transcripts may belong to the current project or the Org
tree. The helper resolves relative paths against the command's working
directory and verifies both the canonical location and session header. If the
environment ID is missing, ask the user to copy the current buffer's ID with
`agent-shell-copy-session-id` and pass that value explicitly.

For a new file node, pass the confirmed title, section title, body file, and
template. For a child node, pass the confirmed title, body file, and parent ID;
do not pass a section title or template.

The helper adds the `:agent:` tag and `SOURCE_SESSION` provenance. Preserve the
returned `request_id`. A result with `"status":"prepared"` means only that
Emacs opened the capture UI. Report the mode, proposed target, and that the
capture is prepared, then tell the user to finalize with `C-c C-c` or abort
with `C-c C-k`.

After the user says they finished, query `capture-status --request-id ID`
before reporting the outcome. Report a node as created only for
`"status":"finalized"`; `"aborted"` means no new content was saved. An unknown
or expired request is not evidence of either outcome. The user may edit the
capture; the saved note is authoritative and need not be read back unless
later work depends on its final text.
