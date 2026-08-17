#!/usr/bin/env bash
# Structural regression tests for the watcher's one alarm-suppression owner.
#
# The rule these pin: bin/fm-watch.sh may silence a supervision alarm only
# through may_suppress_alarm, which requires both the durable merge-poll record
# and the classifier's agreement. Three separate raw reads of that record have
# bypassed the precedence, so bin/fm-watch-suppression-check.sh enforces the rule
# rather than restating it.
#
# The check is exercised through its executable interface, never by reading
# bin/fm-watch.sh here: a test that asserted implementation-source bytes would be
# the thing this repo's contract forbids. The guard script IS that interface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-watch-suppression-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-watch-suppression.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

run_expect_failure() {
  local expected=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected', got: $out"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

test_repository_watcher_has_one_suppression_owner() {
  local out
  out=$("$CHECK") || fail "the repository watcher failed its suppression-ownership check"
  assert_contains "$out" "fm-watch-suppression-check: ok owner=may_suppress_alarm" \
    "the check did not name the suppression owner it verified"
  assert_contains "$out" "record_reads=1" \
    "the check did not report exactly one durable-record read inside the owner"
  pass "the watcher reads the durable merge-poll record in exactly one place"
}

# A guard that cannot fail proves nothing, which is the same discipline this
# change already applies to its own control: reintroduce the bypass the check
# exists to catch and the check must name the line that did it.
test_a_reintroduced_raw_record_read_fails_the_check() {
  local copy line
  copy="$TMP_ROOT/fm-watch-bypassed.sh"
  cp "$WATCH" "$copy"
  cat >> "$copy" <<'SH'

busy_turn_carve_out() {  # <task>
  fm_pr_merge_poll_armed "$STATE" "$1"
}
SH
  line=$(grep -n 'fm_pr_merge_poll_armed "$STATE" "$1"' "$copy" | cut -d: -f1)
  [ -n "$line" ] || fail "could not locate the reintroduced raw record read"
  run_expect_failure "fm-watch-bypassed.sh:$line" "$CHECK" --target "$copy"
  run_expect_failure "outside may_suppress_alarm" "$CHECK" --target "$copy"
  pass "a raw durable-record read outside the owner fails the check and is named by line"
}

# The other way the check could pass vacuously: an owner that is gone or renamed.
test_a_missing_owner_fails_the_check() {
  local copy
  copy="$TMP_ROOT/fm-watch-ownerless.sh"
  sed 's/may_suppress_alarm/may_suppress_alarm_renamed/g' "$WATCH" > "$copy"
  run_expect_failure "defines no may_suppress_alarm owner" "$CHECK" --target "$copy"
  pass "a watcher with no suppression owner fails rather than passing vacuously"
}

test_repository_watcher_has_one_suppression_owner
test_a_reintroduced_raw_record_read_fails_the_check
test_a_missing_owner_fails_the_check
