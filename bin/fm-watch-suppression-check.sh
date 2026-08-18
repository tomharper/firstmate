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
# It bans the RECORD, not one name for it. The armed-poll predicate is only the
# spelling those three bypasses happened to use; the same record is equally
# reachable through the parsers that predicate wraps, or by reading its two
# sidecar paths directly, and a fourth bypass written either of those ways would
# otherwise pass silently. The merge-poll CHECK sweep is a different subsystem
# that legitimately handles the same artifacts, so its entry points are an
# explicit named allowance below rather than an implicit gap - an invisible
# carve-out is how the busy-turn bypass survived three rounds.
#
# It bans the spelling in EVERY context - code, comment or string - because a
# comment exemption needs a rule for where code ends, and every such rule this
# guard tried was foolable by the very shape it exists to catch. Comments outside
# the owner therefore name it by prose or by its function name, never by a banned
# spelling.
#
# Structure only: it locates the owner and the reads, and never judges what the
# owner does. Point --target at a copy to exercise the check itself.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

OWNER = "may_suppress_alarm"

# Every way bin/fm-watch.sh could reach the durable completion record. Written as
# families rather than the three spellings already known to have bypassed the
# owner, so a fourth spelling is banned before anyone invents it.
BANNED = [
    # The armed-poll predicate itself, and the spelling all three known bypasses used.
    r"fm_pr_merge_poll_armed",
    # Every lower-level poll accessor, including the two parsers that predicate
    # wraps (fm_pr_poll_registration_parse, fm_pr_poll_data_parse).
    r"fm_pr_poll_[a-z_]+",
    # The record's own sidecar paths and any other textual reference to them:
    # state/<id>.pr-poll and state/<id>.pr-poll-registration.
    r"pr-poll",
]
BANNED_RE = re.compile("|".join(BANNED))

# The merge-poll CHECK sweep. These handle the same artifacts and must keep
# working untouched: they retire a landed poll and snapshot its bytes, which is
# an authenticated-check concern, not a suppression decision. Named explicitly so
# the allowance is reviewable rather than an accident of how the ban is spelled.
ALLOWED = {
    # Startup recovery of a retirement interrupted mid-sequence.
    "fm_pr_poll_retirement_recover_all": "check sweep: recover interrupted retirements",
    # Per-task retirement recovery after the receipt is published.
    "fm_pr_poll_retirement_recover_one": "check sweep: finish one task's retirement",
    # Publishes the retirement receipt that makes retirement retryable.
    "fm_pr_poll_retirement_publish": "check sweep: publish the retirement receipt",
    # Captures the poll bytes bound into that receipt before the check runs.
    "fm_pr_poll_snapshot_capture": "check sweep: snapshot poll bytes for the receipt",
    # The check script those entry points are handed.
    "fm-pr-poll.sh": "check sweep: the poll check script path",
    # The wake key the retirement notification is queued under.
    "pr-poll-retirement": "check sweep: the retirement wake key",
}


class CheckError(Exception):
    """One deterministic suppression-ownership failure."""


def fail(message: str) -> None:
    raise CheckError(message)


def allowance_covers(line: str, match: re.Match) -> bool:
    """True when THIS occurrence is itself one of the named check-sweep call sites.

    Span-scoped, never line-scoped. An allowance that asked only whether some
    allowed name appears somewhere on the line would excuse a real record read
    for sharing a line with a trailing comment or an unrelated string - a guard
    against a rule being broken a fourth time, defeatable by writing a comment
    next to the break. Each occurrence is judged on its own.
    """
    for allowed in ALLOWED:
        index = line.find(allowed)
        while index >= 0:
            if index <= match.start() and match.end() <= index + len(allowed):
                return True
            index = line.find(allowed, index + 1)
    return False


def occurrences(line: str):
    """Every banned occurrence in <line>, in EVERY context.

    There is deliberately no comment exemption and no string exemption. A guard
    whose whole premise is that it must not be foolable cannot rest on a
    heuristic for where code ends, and the obvious heuristic - treat a `#`
    earlier in the line as a comment start - is wrong in exactly the way this
    change has now been wrong four times, judging a LINE where it should judge an
    OCCURRENCE: `local id=${1#state/}` puts a `#` in front of a real record read
    and the read stops being seen. A cleverer heuristic is just another thing
    that can be wrong the same way, so there is none.
    The cost is that no comment outside the owner may name a banned spelling
    literally; comments refer to the owner by prose or by its function name
    instead. The property bought is total: there is no context whatsoever in
    which a banned spelling can sit outside the owner and pass.
    """
    return list(BANNED_RE.finditer(line))


def banned_read(line: str) -> str:
    """The banned spelling <line> carries, or None when it carries none."""
    for match in occurrences(line):
        if allowance_covers(line, match):
            continue
        return match.group(0)
    return None


def allowed_check_sweep(line: str) -> int:
    """How many of <line>'s banned occurrences the named allowance itself covers."""
    return sum(1 for match in occurrences(line) if allowance_covers(line, match))


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


def validate(target_path: Path) -> tuple[int, int, int]:
    try:
        text = target_path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"target is unreadable: {exc}")
    lines = text.splitlines()
    target = target_path.name
    start, end = owner_span(lines, target)

    inside = 0
    swept = 0
    for number, line in enumerate(lines, start=1):
        if start <= number <= end:
            if banned_read(line) is not None:
                inside += 1
            continue
        swept += allowed_check_sweep(line)
        spelling = banned_read(line)
        if spelling is None:
            continue
        fail(
            f"{target}:{number} names the durable merge-poll record ({spelling}) "
            f"outside {OWNER} (lines {start}-{end}): {line.strip()} - every "
            f"suppression decision must ask {OWNER}, which requires the "
            f"classifier to agree the task is complete, so a parked, blocked or "
            f"failed run is never silenced by a completion record. A comment or "
            f"string is not exempt: name the owner in prose instead"
        )
    if inside == 0:
        fail(
            f"{target}: {OWNER} never reads the durable merge-poll record "
            f"(none of {', '.join(BANNED)}), so this check would pass vacuously"
        )
    return end - start + 1, inside, swept


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify that watcher alarm suppression has exactly one owner."
    )
    parser.add_argument("--target", type=Path, default=Path("bin/fm-watch.sh"))
    args = parser.parse_args()
    target = args.target if args.target.is_absolute() else Path.cwd() / args.target
    try:
        owner_lines, reads, swept = validate(target)
    except CheckError as exc:
        print(f"fm-watch-suppression-check: {exc}", file=sys.stderr)
        return 1
    print(
        f"fm-watch-suppression-check: ok owner={OWNER} owner_lines={owner_lines} "
        f"record_reads={reads} check_sweep_allowed={swept} target={target.name}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
