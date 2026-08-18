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
  local out swept
  out=$("$CHECK") || fail "the repository watcher failed its suppression-ownership check"
  assert_contains "$out" "fm-watch-suppression-check: ok owner=may_suppress_alarm" \
    "the check did not name the suppression owner it verified"
  assert_contains "$out" "record_reads=1" \
    "the check did not report exactly one durable-record read inside the owner"
  # The merge-poll CHECK sweep is a different subsystem that legitimately handles
  # the same artifacts. Its allowance must be load-bearing rather than decorative:
  # a zero here would mean the ban is too narrow to ever need it, which is the
  # state that let three bypasses through.
  swept=$(printf '%s' "$out" | sed -n 's/.*check_sweep_allowed=\([0-9][0-9]*\).*/\1/p')
  [ -n "$swept" ] && [ "$swept" -gt 0 ] \
    || fail "the named check-sweep allowance never fired, so the ban is too narrow to need it: $out"
  pass "the watcher reads the durable merge-poll record in exactly one place, and the check sweep stays allowed"
}

# A guard that cannot fail proves nothing, which is the same discipline this
# change already applies to its own control. The proof covers EVERY banned
# spelling, not just the one the three known bypasses happened to use: a guard is
# worth exactly what its failure proof covers, and a fourth bypass will be
# written in whichever spelling is still unguarded.
test_every_banned_spelling_of_a_record_read_fails_the_check() {
  local spelling copy line i=0
  # shellcheck disable=SC2016 # literal source lines to inject, never expanded here.
  for spelling in \
    'fm_pr_merge_poll_armed "$STATE" "$1"' \
    'fm_pr_poll_registration_parse "$STATE/$1.pr-poll-registration"' \
    'fm_pr_poll_data_parse "$STATE/$1.pr-poll"' \
    '[ -s "$STATE/$1.pr-poll" ] || return 1' \
    '[ -s "$STATE/$1.pr-poll-registration" ] || return 1'
  do
    i=$((i + 1))
    copy="$TMP_ROOT/fm-watch-bypassed-$i.sh"
    cp "$WATCH" "$copy"
    {
      printf '\n'
      printf 'busy_turn_carve_out() {  # <task>\n'
      printf '  %s\n' "$spelling"
      printf '}\n'
    } >> "$copy"
    line=$(grep -nF "  $spelling" "$copy" | cut -d: -f1)
    [ -n "$line" ] || fail "could not locate the reintroduced record read: $spelling"
    run_expect_failure "fm-watch-bypassed-$i.sh:$line" "$CHECK" --target "$copy"
    run_expect_failure "outside may_suppress_alarm" "$CHECK" --target "$copy"
  done
  pass "every banned spelling of a durable-record read outside the owner fails the check and is named by line"
}

# The other half of a load-bearing allowance: it must permit what it names and
# nothing more. A check-sweep call reintroduced outside the owner is allowed,
# which is what keeps the retirement and snapshot paths working untouched.
test_the_named_check_sweep_allowance_permits_only_what_it_names() {
  local copy
  copy="$TMP_ROOT/fm-watch-check-sweep.sh"
  cp "$WATCH" "$copy"
  cat >> "$copy" <<'SH'

extra_retirement_sweep() {  # <task>
  fm_pr_poll_retirement_recover_one "$STATE" "$1" "$SCRIPT_DIR/fm-pr-poll.sh"
}
SH
  "$CHECK" --target "$copy" >/dev/null \
    || fail "the guard rejected a legitimate merge-poll check-sweep call outside the owner"
  pass "the named check-sweep allowance keeps the retirement and snapshot paths working"
}

# The sharpest instance of the pattern this guard exists to stop: a guard built
# so a rule cannot be broken a fourth time, which could itself be defeated by
# naming an allowed call site anywhere on the same line. The allowance binds to
# the matched occurrence, so neither a trailing comment nor an unrelated string
# excuses a real record read beside it - and neither may quietly inflate the
# allowance count either.
test_an_allowed_name_sharing_the_line_does_not_excuse_a_record_read() {
  local copy line i=0 shape
  # shellcheck disable=SC2016 # literal source lines to inject, never expanded here.
  for shape in \
    'fm_pr_merge_poll_armed "$STATE" "$1" # mirrors the fm-pr-poll.sh sweep' \
    'fm_pr_merge_poll_armed "$STATE" "$1" || triage_log "pr-poll-retirement not armed"'
  do
    i=$((i + 1))
    copy="$TMP_ROOT/fm-watch-sameline-$i.sh"
    cp "$WATCH" "$copy"
    {
      printf '\n'
      printf 'busy_turn_carve_out() {  # <task>\n'
      printf '  %s\n' "$shape"
      printf '}\n'
    } >> "$copy"
    line=$(grep -nF "  $shape" "$copy" | cut -d: -f1)
    [ -n "$line" ] || fail "could not locate the same-line record read: $shape"
    run_expect_failure "fm-watch-sameline-$i.sh:$line" "$CHECK" --target "$copy"
    run_expect_failure "outside may_suppress_alarm" "$CHECK" --target "$copy"
  done
  pass "an allowed name in a comment or string never excuses a record read sharing its line"
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
test_every_banned_spelling_of_a_record_read_fails_the_check
test_the_named_check_sweep_allowance_permits_only_what_it_names
test_an_allowed_name_sharing_the_line_does_not_excuse_a_record_read
test_a_missing_owner_fails_the_check
