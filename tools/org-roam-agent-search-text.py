#!/usr/bin/env python3
"""Bounded full-text search for the org-roam agent CLI."""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import shutil
import subprocess
import sys


MAX_MATCH_CHARACTERS = 500


def data_string(data: dict[str, str]) -> str | None:
    """Decode a ripgrep JSON text-or-bytes value."""
    if "text" in data:
        return data["text"]
    if "bytes" in data:
        return base64.b64decode(data["bytes"]).decode("utf-8", errors="replace")
    return None


def match_result(event: dict[str, object]) -> dict[str, object] | None:
    """Convert a ripgrep match event into the public result shape."""
    if event.get("type") != "match":
        return None

    data = event["data"]
    assert isinstance(data, dict)
    path = data_string(data["path"])
    line = data_string(data["lines"])
    line_number = data.get("line_number")
    if path is None or line is None or not isinstance(line_number, int):
        return None

    text = line.rstrip("\r\n")
    truncated = len(text) > MAX_MATCH_CHARACTERS
    return {
        "file": path.removeprefix("./"),
        "line": line_number,
        "text": text[:MAX_MATCH_CHARACTERS],
        "text_truncated": truncated,
    }


def search(root: Path, query: str, regex: bool, limit: int) -> dict[str, object]:
    """Run a bounded ripgrep search beneath ROOT."""
    ripgrep = shutil.which("rg")
    if ripgrep is None:
        raise RuntimeError("the rg executable is not available")

    command = [
        ripgrep,
        "--json",
        "--no-config",
        "--no-ignore",
        "--ignore-case",
        "--glob",
        "*.org",
        "--glob",
        "!**/build/**",
        "--glob",
        "!**/.attach/**",
        "--glob",
        "!**/.attach-cleanup-quarantine/**",
    ]
    if not regex:
        command.append("--fixed-strings")
    command.extend(["--", query, "."])

    results: list[dict[str, object]] = []
    truncated = False
    with subprocess.Popen(
        command,
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    ) as process:
        assert process.stdout is not None
        for output_line in process.stdout:
            try:
                result = match_result(json.loads(output_line))
            except (AssertionError, KeyError, TypeError, ValueError) as error:
                process.terminate()
                raise RuntimeError(f"could not parse rg output: {error}") from error
            if result is None:
                continue
            if len(results) == limit:
                truncated = True
                process.terminate()
                break
            results.append(result)

        try:
            return_code = process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            return_code = process.wait()
        assert process.stderr is not None
        error_output = process.stderr.read().strip()

    if not truncated and return_code not in (0, 1):
        detail = f": {error_output}" if error_output else ""
        raise RuntimeError(f"ripgrep failed{detail}")

    return {
        "query": query,
        "mode": "regex" if regex else "literal",
        "case_sensitive": False,
        "limit": limit,
        "returned": len(results),
        "truncated": truncated,
        "results": results,
    }


def main() -> int:
    """Run the command-line adapter."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--query", required=True)
    parser.add_argument("--limit", required=True, type=int)
    parser.add_argument("--regex", action="store_true")
    arguments = parser.parse_args()

    try:
        response = search(
            arguments.root.resolve(),
            arguments.query,
            arguments.regex,
            arguments.limit,
        )
    except (OSError, RuntimeError) as error:
        print(f"org-roam-agent: {error}", file=sys.stderr)
        return 2

    json.dump(response, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
