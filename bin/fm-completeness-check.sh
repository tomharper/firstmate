#!/usr/bin/env bash
# Formal completeness gate for a task-lifecycle decision (AGENTS.md sections 2, 7).
#
# Derives the observed facts for a task (or takes them explicitly), then asks the
# Z3-backed engine (fm-completeness.py + fm-completeness.rules.json) to PROVE the
# completion claim consistent with firstmate's invariants. Hard rules gate; soft
# rules score. Prints a one-line verdict; on a blocked claim it names the violated
# rule and exits non-zero.
#
# Usage:
#   fm-completeness-check.sh --gate teardown --id <task-id>
#   fm-completeness-check.sh --gate merge    --id <task-id>   # approval via $FM_CAPTAIN_APPROVED
#   fm-completeness-check.sh --kind ship --landed none --worktree holds_unlanded_work [...]
#
# Flags (explicit facts override anything derived):
#   --gate <teardown|merge|done>   what decision this guards (drives fact derivation)
#   --id <task-id>                 derive facts from state/<id>.meta + data/<id>/ + git
#   --kind --landed --report --worktree --captain-approval <value>
#   --mode <strict|graded>         strict (default) gates on invariants; graded also scores soft rules
#   --meta <key>                   set a soft-rule metadata key true (repeatable)
#
# Exit: 0 = SAT (proceed), 2 = UNSAT (blocked), 0 = tooling unavailable (FAIL-OPEN,
# warns and defers to the caller's own checks) unless FM_COMPLETENESS_STRICT=1.
# Set FM_COMPLETENESS_GATE=0 to skip the gate entirely (still exits 0).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ENGINE="$SCRIPT_DIR/fm-completeness.py"

GATE=""
ID=""
MODE="strict"
KIND=""
LANDED=""
REPORT=""
WORKTREE=""
APPROVAL=""
META_KEYS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --gate) GATE="$2"; shift 2 ;;
    --id) ID="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --kind) KIND="$2"; shift 2 ;;
    --landed) LANDED="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --captain-approval) APPROVAL="$2"; shift 2 ;;
    --meta) META_KEYS+=("$2"); shift 2 ;;
    *) echo "fm-completeness-check: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

# Honor the global off-switch.
if [ "${FM_COMPLETENESS_GATE:-1}" = "0" ]; then
  exit 0
fi

fail_open() {
  # Tooling missing or broken: never wedge the lifecycle. Warn and defer to the
  # caller's own (bash) safety checks, unless the operator demands strictness.
  if [ "${FM_COMPLETENESS_STRICT:-0}" = "1" ]; then
    echo "completeness gate: $1 (FM_COMPLETENESS_STRICT=1 -> refusing)" >&2
    exit 3
  fi
  echo "completeness gate: $1; skipping formal check (set FM_COMPLETENESS_STRICT=1 to enforce)" >&2
  exit 0
}

command -v python3 >/dev/null 2>&1 || fail_open "python3 not found"
[ -f "$ENGINE" ] || fail_open "engine $ENGINE missing"

git_unlanded_facts() {
  # Mirror fm-teardown.sh's notion of "landed" so the gate never diverges from
  # the script it guards. Sets LANDED and WORKTREE for a ship task.
  local wt=$1 proj=$2 mode=$3 dirty unpushed default unmerged
  if [ ! -d "$wt" ]; then
    # No worktree on disk means there is nothing to discard, exactly as
    # fm-teardown.sh skips its unlanded check when [ ! -d "$WT" ]. Resolve to a
    # non-blocking state: clean worktree and a landed value that clears
    # SHIP_REQUIRES_LANDED, rather than landed=none which would false-block.
    if [ "$mode" = "local-only" ]; then
      LANDED="${LANDED:-local_merged}"
    else
      LANDED="${LANDED:-pushed}"
    fi
    WORKTREE="${WORKTREE:-clean}"
    return 0
  fi
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | grep -vE '^\?\? \.claude/' | head -1 || true)
  unpushed=$(git -C "$wt" log --oneline HEAD --not --remotes -- 2>/dev/null | head -1 || true)
  if [ "$mode" = "local-only" ]; then
    default=$(git -C "$proj" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
    [ -n "$default" ] || default=main
    unmerged=$(git -C "$wt" log --oneline HEAD --not "$default" -- 2>/dev/null | head -1 || true)
    if [ -z "$unmerged" ]; then
      LANDED="${LANDED:-local_merged}"
    elif [ -z "$unpushed" ]; then
      LANDED="${LANDED:-pushed}"
    else
      LANDED="${LANDED:-none}"
    fi
    if [ -n "$dirty" ] || { [ -n "$unmerged" ] && [ -n "$unpushed" ]; }; then
      WORKTREE="${WORKTREE:-holds_unlanded_work}"
    else
      WORKTREE="${WORKTREE:-clean}"
    fi
  else
    if [ -z "$unpushed" ]; then LANDED="${LANDED:-pushed}"; else LANDED="${LANDED:-none}"; fi
    if [ -n "$dirty" ] || [ -n "$unpushed" ]; then
      WORKTREE="${WORKTREE:-holds_unlanded_work}"
    else
      WORKTREE="${WORKTREE:-clean}"
    fi
  fi
}

# Derive facts from a task id when one is given (explicit flags still win).
if [ -n "$ID" ]; then
  META="$STATE/$ID.meta"
  if [ -f "$META" ]; then
    [ -n "$KIND" ] || KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
    meta_mode=$(grep '^mode=' "$META" | cut -d= -f2- || true)
    wt=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
    proj=$(grep '^project=' "$META" | cut -d= -f2- || true)
  else
    meta_mode=""; wt=""; proj=""
  fi
  [ -n "$KIND" ] || KIND=ship
  [ -n "$meta_mode" ] || meta_mode=no-mistakes

  if [ -z "$REPORT" ]; then
    if [ -f "$DATA/$ID/report.md" ]; then REPORT=present; else REPORT=absent; fi
  fi

  case "$GATE" in
    merge)
      [ -n "$KIND" ] || KIND=ship
      LANDED="${LANDED:-merged}"
      WORKTREE="${WORKTREE:-clean}"
      ;;
    *)
      if [ "$KIND" = scout ]; then
        # Scout carve-out: the report governs, the worktree is scratch by contract.
        LANDED="${LANDED:-none}"; WORKTREE="${WORKTREE:-clean}"; APPROVAL="${APPROVAL:-not_required}"
      elif [ "$KIND" = ship ]; then
        git_unlanded_facts "$wt" "$proj" "$meta_mode"
        APPROVAL="${APPROVAL:-not_required}"
      else
        LANDED="${LANDED:-none}"; WORKTREE="${WORKTREE:-clean}"; APPROVAL="${APPROVAL:-not_required}"
      fi
      ;;
  esac
fi

# Approval at a merge gate is an explicit assertion the caller must make
# (directive #2): $FM_CAPTAIN_APPROVED in {granted,yes,1} -> granted;
# {not_required} -> not_required; anything else / unset -> pending (blocks).
if [ "$GATE" = "merge" ] && [ -z "$APPROVAL" ]; then
  case "${FM_CAPTAIN_APPROVED:-}" in
    granted|yes|1|true) APPROVAL=granted ;;
    not_required) APPROVAL=not_required ;;
    *) APPROVAL=pending ;;
  esac
fi

# Defaults for any axis still unset.
[ -n "$KIND" ] || KIND=ship
[ -n "$LANDED" ] || LANDED=none
[ -n "$REPORT" ] || REPORT=absent
[ -n "$WORKTREE" ] || WORKTREE=clean
[ -n "$APPROVAL" ] || APPROVAL=not_required

case "$ID" in *\"*|*\\*) echo "fm-completeness-check: refusing id with quote/backslash" >&2; exit 64 ;; esac

# Build the metadata object from repeated --meta keys.
meta_json="{}"
if [ "${#META_KEYS[@]}" -gt 0 ]; then
  meta_json="{"
  sep=""
  for key in "${META_KEYS[@]}"; do
    meta_json="$meta_json$sep\"$key\": true"
    sep=", "
  done
  meta_json="$meta_json}"
fi

facts=$(printf '{"name": "%s", "mode": "%s", "kind": "%s", "landed": "%s", "report": "%s", "worktree": "%s", "captain_approval": "%s", "metadata": %s}' \
  "${ID:-task}" "$MODE" "$KIND" "$LANDED" "$REPORT" "$WORKTREE" "$APPROVAL" "$meta_json")

errfile=$(mktemp "${TMPDIR:-/tmp}/fm-completeness.XXXXXX")
set +e
out=$(printf '%s' "$facts" | python3 "$ENGINE" 2>"$errfile")
rc=$?
err=$(cat "$errfile" 2>/dev/null || true)
rm -f "$errfile"
set -e

if [ "$rc" = "3" ]; then
  fail_open "engine error: ${err:-unknown}"
fi

label="${ID:-task}${GATE:+ ($GATE)}"
if [ "$rc" = "0" ]; then
  if [ "$MODE" = "graded" ]; then
    compliance=$(printf '%s' "$out" | sed -n 's/.*"compliance": \([0-9.]*\).*/\1/p')
    echo "completeness gate: SAT - $label clears every invariant (compliance ${compliance:-1.0})"
  else
    echo "completeness gate: SAT - $label clears every invariant"
  fi
  exit 0
fi

reason=$(printf '%s' "$out" | sed -n 's/.*"reason": "\(.*\)", "violated_rules.*/\1/p')
violated=$(printf '%s' "$out" | sed -n 's/.*"violated_rules": \[\(.*\)\], "counterexample.*/\1/p')
echo "completeness gate: BLOCKED - $label is provably premature" >&2
[ -n "$violated" ] && echo "  violated: $violated" >&2
[ -n "$reason" ] && echo "  reason: $reason" >&2
[ -z "$reason" ] && echo "  $out" >&2
exit 2
