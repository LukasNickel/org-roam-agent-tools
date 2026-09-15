---
name: org-roam-lookup
description: Look up existing knowledge in the user's Org-roam notes when they ask whether a note exists, what their notes say about a subject, or which notes are related. Return grounded results from bounded searches; use org-roam-capture for creating new content.
---

# Org-roam lookup

Answer from the user's existing Org-roam collection without changing it.

## Locate the interface

Resolve `org-roam-agent` from `PATH` with `command -v`. Use the exact absolute
path it returns for subsequent invocations so a narrowly scoped command rule
can match the installed interface. Stop and explain the missing global
installation if the command is absent or not executable.

On Codex, request outside-sandbox execution for each helper invocation from the
outset, scoped to that exact executable and command. Do not first probe the
Emacs socket from inside the sandbox. The configured command rule remains the
authority: a `prompt` decision requires user approval, while `allow` may proceed
without a prompt. On another host, use its equivalent least-privilege execution
mechanism when available. If the helper still reports an Emacs connection error
containing `Operation not permitted`, explain that the host has not granted the
required bounded access; do not probe the socket or change Emacs.

## Find candidate nodes

Start with `search-nodes --limit 20` using the subject's strongest title, alias,
or tag terms. Every whitespace-separated term is required, so prefer multiple
focused queries over one overloaded query. Reformulate with a likely synonym or
broader concept when the first result is weak or when completeness matters.

For an existence request, return the relevant candidates with their titles,
stable IDs, tags, and clickable files. Distinguish no match in the bounded
search from proof that no note exists. Resolve consequential ambiguity with the
user instead of silently choosing among equally plausible nodes.

## Read relevant evidence

For questions about note contents, use `search-text --limit 50` after metadata
search, then call `context` only for promising matches. Searching a candidate's
exact title is a useful way to locate its heading when metadata found the node
but not a body match. Broaden queries when the evidence is weak or the user asks
for comprehensive coverage.

Synthesize the answer from the inspected subtrees. Make substantive claims
traceable to named, clickable note files and line locations when available.
Quote sparingly and preserve uncertainty or disagreement present in the notes.

## Follow relationships

For related-note requests, identify an unambiguous seed node and call `links`
with its stable ID. Treat backlinks and outgoing links as explicit graph
relationships. Use each result's `link_file` and `link_line` with `context` when
the nature of the relationship matters, and explain why each reported neighbor
is relevant.

Use metadata and text searches to find plausible semantic neighbors that are
not directly linked. Label those as inferred relationships rather than graph
links. Prefer a short explained set over a large undifferentiated list.

## Preserve live state

Database-backed node and link results may omit unsaved buffer contents, while
full-text search reads disk. `context` reports whether it used a live buffer and
whether that buffer is modified. State the resulting limitation when it could
change the answer. Leave buffers, files, and the Org-roam database untouched.
