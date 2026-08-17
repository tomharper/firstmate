#!/usr/bin/env bash
# fm-watch-suppression-check.sh - hold alarm suppression to one owner.
#
# Usage:
#   bin/fm-watch-suppression-check.sh
#   bin/fm-watch-suppression-check.sh --target <path-to-fm-watch.sh>
#
# The watcher may silence a supervision alarm for exactly one reason: the task's
# durable merge-poll record says its work is finished and the classifier agrees.
# That decision has one owner, may_suppress_alarm in bin/fm-watch.sh, because
# three separate raw reads of the record have now bypassed the classifier's
# precedence - each written by someone following the rule, each silencing an
# alarm the rule meant to keep. A rule broken three times by people trying to
# obey it has to be enforced rather than restated, so this check fails when any
# read of the record appears outside that owner.
#
# Structure only: it locates the owner and the reads, and never judges what the
# owner does. Point --target at a copy to exercise the check itself.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import sys
from pathlib import Path

OWNER = "may_suppress_alarm"
RECORD = "fm_pr_merge_poll_armed"


class CheckError(Exception):
    """One deterministic suppression-ownership failure."""


def fail(message: str) -> None:
    raise CheckError(message)


def code_before(line: str, token: str) -> str:
    """The part of <line> preceding <token>, or None when the token is prose."""
    index = line.find(token)
    if index < 0:
        return None
    head = line[:index]
    return None if "#" in head else head


def owner_span(lines: list[str], target: str) -> tuple[int, int]:
    """1-indexed inclusive line range of the owner function definition."""
    starts = [
        i + 1
        for i, line in enumerate(lines)
        if line.startswith(f"{OWNER}()") or line.startswith(f"{OWNER} ()")
    ]
    if not starts:
        fail(
            f"{target} defines no {OWNER} owner: alarm suppression must have exactly "
            f"one owner, and this check cannot verify a file without it"
        )
    if len(starts) > 1:
        joined = ", ".join(str(s) for s in starts)
        fail(f"{target} defines {OWNER} more than once (lines {joined})")
    start = starts[0]
    for offset in range(start, len(lines)):
        if lines[offset] == "}":
            return start, offset + 1
    fail(f"{target}:{start} {OWNER} has no closing brace at column 0")


def validate(target_path: Path) -> tuple[int, int]:
    try:
        text = target_path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"target is unreadable: {exc}")
    lines = text.splitlines()
    target = target_path.name
    start, end = owner_span(lines, target)

    inside = 0
    for number, line in enumerate(lines, start=1):
        if code_before(line, RECORD) is None:
            continue
        if start <= number <= end:
            inside += 1
            continue
        fail(
            f"{target}:{number} reads the durable merge-poll record ({RECORD}) "
            f"outside {OWNER} (lines {start}-{end}): {line.strip()} - every "
            f"suppression decision must ask {OWNER}, which requires the "
            f"classifier to agree the task is complete, so a parked, blocked or "
            f"failed run is never silenced by a completion record"
        )
    if inside == 0:
        fail(
            f"{target}: {OWNER} never reads the durable merge-poll record "
            f"({RECORD}), so this check would pass vacuously"
        )
    return end - start + 1, inside


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify that watcher alarm suppression has exactly one owner."
    )
    parser.add_argument("--target", type=Path, default=Path("bin/fm-watch.sh"))
    args = parser.parse_args()
    target = args.target if args.target.is_absolute() else Path.cwd() / args.target
    try:
        owner_lines, reads = validate(target)
    except CheckError as exc:
        print(f"fm-watch-suppression-check: {exc}", file=sys.stderr)
        return 1
    print(
        f"fm-watch-suppression-check: ok owner={OWNER} owner_lines={owner_lines} "
        f"record_reads={reads} target={target.name}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
