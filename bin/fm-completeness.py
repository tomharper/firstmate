#!/usr/bin/env python3
"""Formal completeness gate for firstmate task-lifecycle decisions.

Firstmate's "is this task done / safe to tear down / clear to merge?" calls are
really invariants (AGENTS.md prime directives #2 and #3). This turns them into a
formal rule set checked by the Z3-backed neurosymbolic-evaluator: firstmate
proposes a completion claim with the observed facts, and the solver PROVES it
either SAT (consistent with every invariant) or UNSAT (provably premature, with
the violated rule named). Hard rules gate; soft rules score (never block).

The rules are DATA, not code: they load from fm-completeness.rules.json (or
$FM_COMPLETENESS_RULES). This module only translates that data into the
evaluator's custom-rule callbacks and runs the check.

I/O: reads one JSON object of facts on stdin, e.g.
    {"name": "fix-x", "kind": "ship", "landed": "none",
     "worktree": "holds_unlanded_work", "mode": "strict",
     "metadata": {"backlog_recorded": true}}
`mode` is "strict" (default, hard invariants only) or "graded" (also scores soft
rules). All other top-level keys except name/mode/metadata are axis values.

Prints a JSON result on stdout. Exit 0 if SAT, 2 if UNSAT, 3 on a usage/tooling
error (so the bash wrapper can fail-open and defer to its own checks).
"""
from __future__ import annotations

import json
import os
import sys

EXIT_SAT = 0
EXIT_UNSAT = 2
EXIT_ERROR = 3


def _default_rules_path() -> str:
    env = os.environ.get("FM_COMPLETENESS_RULES")
    if env:
        return env
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "fm-completeness.rules.json")


def _applies(axes: dict, when: dict) -> bool:
    """A rule with a `when` clause applies only when every condition matches."""
    return all(axes.get(k) == v for k, v in when.items())


def _make_hard_check(rule: dict):
    when = rule.get("when", {})
    require = rule.get("require", {})
    forbid = rule.get("forbid", {})
    reason = rule["reason"]

    def check(pred, _vocab):
        axes = pred.axes
        if not _applies(axes, when):
            return None
        for key, val in require.items():
            if axes.get(key) != val:
                return reason
        for key, val in forbid.items():
            if axes.get(key) == val:
                return reason
        return None

    return check


def _make_soft_check(rule: dict):
    when = rule.get("when", {})
    meta_key = rule.get("require_meta")
    reason = rule["reason"]

    def check(pred, _vocab):
        if not _applies(pred.axes, when):
            return None
        if meta_key is not None and pred.metadata.get(meta_key):
            return None
        return reason

    return check


def build_vocabulary(spec: dict):
    """Translate the rules data file into a verified Vocabulary."""
    from neurosymbolic_evaluator import Vocabulary

    vocab = Vocabulary(spec.get("name", "firstmate_task_completeness"))
    for axis, values in spec.get("axes", {}).items():
        vocab.add_axis(axis, list(values))
    for rule in spec.get("hard_rules", []):
        vocab.add_custom_rule(rule["name"], _make_hard_check(rule))
    for rule in spec.get("soft_rules", []):
        vocab.add_custom_soft_rule(
            rule["name"], _make_soft_check(rule), weight=int(rule.get("weight", 1)))
    return vocab


def check(spec: dict, facts: dict) -> dict:
    vocab = build_vocabulary(spec)

    name = facts.get("name", "task")
    mode = facts.get("mode", "strict")
    metadata = facts.get("metadata", {}) or {}
    declared_axes = set(spec.get("axes", {}))
    axis_values = {k: v for k, v in facts.items()
                   if k not in ("name", "mode", "metadata") and k in declared_axes}

    # Reject axis values the data file never declared — a typo'd fact must surface
    # as a tooling error, not silently pass the gate.
    for axis, value in axis_values.items():
        if value not in spec["axes"][axis]:
            raise ValueError(
                "fact %s=%r is not a declared value of axis %s (%s)"
                % (axis, value, axis, ", ".join(spec["axes"][axis])))

    if mode == "graded":
        result = vocab.verify_extension_graded(name, metadata=metadata, **axis_values)
    else:
        result = vocab.verify_extension(name, metadata=metadata, **axis_values)

    return {
        "sat": bool(result.sat),
        "reason": result.reason,
        "violated_rules": list(result.violated_rules),
        "counterexample": result.counterexample,
        "compliance": getattr(result, "compliance", 1.0),
        "unmet_soft": list(getattr(result, "unmet_soft", [])),
        "mode": mode,
    }


def main() -> int:
    try:
        raw = sys.stdin.read()
        facts = json.loads(raw) if raw.strip() else {}
    except (json.JSONDecodeError, ValueError) as exc:
        print(json.dumps({"error": "bad facts JSON: %s" % exc}), file=sys.stderr)
        return EXIT_ERROR

    rules_path = _default_rules_path()
    try:
        with open(rules_path, encoding="utf-8") as handle:
            spec = json.load(handle)
    except OSError as exc:
        print(json.dumps({"error": "cannot read rules file %s: %s"
                          % (rules_path, exc)}), file=sys.stderr)
        return EXIT_ERROR

    try:
        out = check(spec, facts)
    except ImportError as exc:
        print(json.dumps({"error": "neurosymbolic-evaluator not importable: %s"
                          % exc}), file=sys.stderr)
        return EXIT_ERROR
    except (ValueError, KeyError) as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return EXIT_ERROR

    print(json.dumps(out))
    return EXIT_SAT if out["sat"] else EXIT_UNSAT


if __name__ == "__main__":
    sys.exit(main())
