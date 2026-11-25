#!/usr/bin/env bash
#
# scripts/test-shellcheck-bounded.sh — state table for scripts/shellcheck-bounded.sh
#
# WHY. The wrapper bounds each shellcheck's address space with prlimit, so a
# file that outgrows it fails the hook instead of taking the machine's memory.
# Why
# the bound is what it is: the wrapper's header. The rules pinned here:
#   - with prlimit on PATH, prlimit gets exactly the bound in bytes, then
#     `shellcheck` and the arguments, verbatim;
#   - without prlimit, shellcheck runs directly with the arguments and a note
#     on stderr says it is unbounded;
#   - shellcheck's exit status passes through unchanged on both paths, and an
#     out-of-memory exit under the bound, and no other exit, names the bound;
#   - a caller's own tighter address-space limit is kept: the bound is the
#     smaller of the two, and an out-of-memory exit names the caller's;
#   - the REAL prlimit hands its child that bound (in KiB, `ulimit -v`) and
#     passes the child's exit status back, under a caller's tighter soft or
#     hard limit too.
#
# The pre-commit hook that runs the wrapper is configured in
# .pre-commit-config.yaml, and not pinned here.
#
# HERMETIC. env -i and a from-scratch PATH holding only the stubs a row names.
# Every row starts the wrapper under an address-space limit it sets itself, so
# no row reads the limit its runner happens to have.
# prlimit and shellcheck are recording stubs that print the name they were run
# by and each argument in brackets; the stub prlimit then runs the rest of its
# arguments, as the real one does. The one row set that uses the real prlimit
# gives it a stub shellcheck that prints `ulimit -v` and allocates nothing, so
# no row ever runs shellcheck.
#
# Requires: bash, util-linux prlimit, and a hard
# address-space limit no tighter than the bound. A missing one is exit 2
# ("could not run"), never a skipped row.
#
# Exit: 0 every row passed; 1 a row failed; 2 the table could not run, or ran a
# different number of rows than it declares.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
WRAPPER="$ROOT/scripts/shellcheck-bounded.sh"

# The bound the wrapper must apply, written out here rather than read from the
# wrapper, so a changed constant fails a row instead of moving the target.
EXPECTED_LIMIT_BYTES=3221225472
BYTES_PER_KIB=1024
EXPECTED_LIMIT_KIB=$(( EXPECTED_LIMIT_BYTES / BYTES_PER_KIB ))
# A caller's own limits, tighter than the bound: 1 GiB, and 1.5 GiB, which is
# not a whole number of GiB.
TIGHTER_CALLER_LIMIT_KIB=1048576
TIGHTER_CALLER_LIMIT_BYTES=$(( TIGHTER_CALLER_LIMIT_KIB * BYTES_PER_KIB ))
FRACTIONAL_GIB_CALLER_LIMIT_KIB=1572864
FRACTIONAL_GIB_CALLER_LIMIT_BYTES=$(( FRACTIONAL_GIB_CALLER_LIMIT_KIB * BYTES_PER_KIB ))
SHELLCHECK_FINDINGS_EXIT_STATUS=1
SHELLCHECK_BAD_OPTIONS_EXIT_STATUS=4
GHC_OUT_OF_MEMORY_EXIT_STATUS=251
UNBOUNDED_NOTE='shellcheck-bounded: prlimit not found, so shellcheck runs with no memory bound'
HINT_PREFIX='shellcheck-bounded: shellcheck ran out of memory under its address-space bound of'
HINT_POINTER='see the header of scripts/shellcheck-bounded.sh'
BOUND_HINT="$HINT_PREFIX 3 GiB ($EXPECTED_LIMIT_BYTES bytes); $HINT_POINTER"
TIGHTER_CALLER_HINT="$HINT_PREFIX 1 GiB ($TIGHTER_CALLER_LIMIT_BYTES bytes), the caller's own limit; $HINT_POINTER"
FRACTIONAL_GIB_CALLER_HINT="$HINT_PREFIX 1.50 GiB ($FRACTIONAL_GIB_CALLER_LIMIT_BYTES bytes), the caller's own limit; $HINT_POINTER"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

[[ -r "$WRAPPER" ]] || fatal "cannot read $WRAPPER"
BASH_BIN=$(command -v bash) || fatal "bash is required"
REAL_PRLIMIT=$(command -v prlimit) || fatal "prlimit (util-linux) is required for the real-prlimit rows"

# Rows that do not name a tighter limit start the wrapper with the runner's hard
# limit as their soft one. Only root can raise a hard limit, so a runner whose
# hard limit is below the bound cannot run the rows that expect the bound.
RUNNER_HARD_LIMIT_KIB=$(ulimit -H -v) || fatal "cannot read this runner's address-space limit"
if [[ "$RUNNER_HARD_LIMIT_KIB" != unlimited ]]; then
    [[ "$RUNNER_HARD_LIMIT_KIB" =~ ^[0-9]+$ ]] ||
        fatal "cannot read this runner's address-space limit: '$RUNNER_HARD_LIMIT_KIB'"
    (( RUNNER_HARD_LIMIT_KIB >= EXPECTED_LIMIT_KIB )) ||
        fatal "this runner's hard address-space limit, $RUNNER_HARD_LIMIT_KIB KiB, is below the bound under test, $EXPECTED_LIMIT_KIB KiB"
fi

TMPROOT=$(mktemp -d) || fatal "mktemp failed"
trap 'rm -rf "$TMPROOT"' EXIT

# --- stubs -----------------------------------------------------------------
STUBS="$TMPROOT/stubs"
mkdir -p "$STUBS" || fatal "cannot create $STUBS"

# Records `prlimit[--as=N][shellcheck][arg]…`, then drops its own option and
# runs the rest, so the stub shellcheck's output and status come through.
cat > "$STUBS/prlimit" <<'EOF' || fatal "cannot write the prlimit stub"
#!/bin/sh
printf prlimit
for a in "$@"; do printf '[%s]' "$a"; done
echo
shift
exec "$@"
EOF

# Records `shellcheck[arg]…` and exits with the status the row asks for.
cat > "$STUBS/shellcheck" <<'EOF' || fatal "cannot write the shellcheck stub"
#!/bin/sh
printf shellcheck
for a in "$@"; do printf '[%s]' "$a"; done
echo
exit "${STUB_SHELLCHECK_EXIT_STATUS:-0}"
EOF

# Prints the address-space limit it was started under, in KiB, and allocates
# nothing.
cat > "$STUBS/shellcheck-ulimit" <<'EOF' || fatal "cannot write the ulimit stub"
#!/bin/sh
ulimit -v
exit "${STUB_SHELLCHECK_EXIT_STATUS:-0}"
EOF
chmod +x "$STUBS/prlimit" "$STUBS/shellcheck" "$STUBS/shellcheck-ulimit" ||
    fatal "cannot make the stubs executable"

# One PATH directory per state. $1 the directory's name, then NAME=SOURCE pairs.
# Run in $(…), where `fatal` exits only the subshell, so each caller adds
# `|| exit 2` (fatal has already said why).
make_bin() {
    local bin="$TMPROOT/$1" pair; shift
    mkdir -p "$bin" || fatal "cannot create $bin"
    for pair in "$@"; do
        ln -s "${pair#*=}" "$bin/${pair%%=*}" || fatal "cannot link ${pair%%=*} into $bin"
    done
    printf '%s' "$bin"
}
BIN_BOUNDED=$(make_bin bounded "prlimit=$STUBS/prlimit" "shellcheck=$STUBS/shellcheck") || exit 2
BIN_NO_PRLIMIT=$(make_bin no-prlimit "shellcheck=$STUBS/shellcheck") || exit 2
BIN_REAL_PRLIMIT=$(make_bin real-prlimit "prlimit=$REAL_PRLIMIT" "shellcheck=$STUBS/shellcheck-ulimit") || exit 2

# Starts the wrapper the way a caller would: with PATH set to $1, the remaining
# arguments, and the stub exiting with $STUB_EXIT (default 0). It runs under the
# address-space limit $CALLER_LIMIT_KIB (default: the runner's hard limit), set
# as the soft limit only, or as soft and hard together when
# $CALLER_LIMIT_IS_HARD is set. Sets OUT, ERR and RC. A limit the launcher
# cannot set is exit 2, since the row would then read the runner's limit.
LAUNCHER_FAILED_MARKER="$TMPROOT/launcher-failed"
# The launcher, run by `bash -c`: sets the limit ($1 the scope, $2 KiB), or
# leaves the marker file $3 and fails; then runs the rest of its arguments.
# SC2016: single quotes on purpose, so $1… are the launcher's own arguments.
# shellcheck disable=SC2016
LAUNCH_UNDER_LIMIT_SCRIPT='ulimit "$1" -v "$2" || { : >"$3"; exit 1; }; shift 3; exec "$@"'
run_wrapper() {
    local bin=$1 ulimit_scope=-S; shift
    [[ -n "${CALLER_LIMIT_IS_HARD:-}" ]] && ulimit_scope=-SH
    rm -f "$LAUNCHER_FAILED_MARKER" || fatal "cannot clear $LAUNCHER_FAILED_MARKER"
    env -i HOME="$TMPROOT" PATH="$bin" STUB_SHELLCHECK_EXIT_STATUS="${STUB_EXIT:-0}" \
        "$BASH_BIN" -c "$LAUNCH_UNDER_LIMIT_SCRIPT" launch-under-limit \
        "$ulimit_scope" "${CALLER_LIMIT_KIB:-$RUNNER_HARD_LIMIT_KIB}" "$LAUNCHER_FAILED_MARKER" \
        "$BASH_BIN" "$WRAPPER" "$@" >"$TMPROOT/out" 2>"$TMPROOT/err"
    RC=$?
    OUT=$(<"$TMPROOT/out"); ERR=$(<"$TMPROOT/err")
    [[ ! -e "$LAUNCHER_FAILED_MARKER" ]] || fatal "could not set the caller's address-space limit: $ERR"
}

# Prints what the stub prlimit ran: the second line of $OUT when $OUT is
# exactly two lines (prlimit's record, then shellcheck's). Otherwise prints the
# line count and $OUT, so a row reading it fails when prlimit never ran.
line_run_under_prlimit() {
    local -a out_lines
    mapfile -t out_lines <<<"$OUT"
    if (( ${#out_lines[@]} == 2 )); then
        printf '%s' "${out_lines[1]}"
    else
        printf '%d lines: %s' "${#out_lines[@]}" "$OUT"
    fi
}

# --- rows ------------------------------------------------------------------
echo "prlimit on PATH"
run_wrapper "$BIN_BOUNDED" -x script.sh
check "prlimit gets the bound in bytes, then shellcheck and the arguments" \
    "${OUT%%$'\n'*}" "prlimit[--as=$EXPECTED_LIMIT_BYTES][shellcheck][-x][script.sh]"
check "shellcheck runs under it with the arguments"   "$(line_run_under_prlimit)" "shellcheck[-x][script.sh]"
check "nothing on stderr"                             "$ERR" ""
check "exit 0 passes through"                         "$RC" "0"
run_wrapper "$BIN_BOUNDED" -x 'a file.sh'
check "an argument with a space arrives as one argument" \
    "$(line_run_under_prlimit)" "shellcheck[-x][a file.sh]"
STUB_EXIT=$SHELLCHECK_FINDINGS_EXIT_STATUS run_wrapper "$BIN_BOUNDED" script.sh
check "exit 1 (findings) passes through"              "$RC" "$SHELLCHECK_FINDINGS_EXIT_STATUS"
check "findings do not blame the bound"               "$ERR" ""
STUB_EXIT=$SHELLCHECK_BAD_OPTIONS_EXIT_STATUS run_wrapper "$BIN_BOUNDED" script.sh
check "exit 4 passes through"                         "$RC" "$SHELLCHECK_BAD_OPTIONS_EXIT_STATUS"
STUB_EXIT=$GHC_OUT_OF_MEMORY_EXIT_STATUS run_wrapper "$BIN_BOUNDED" script.sh
check "exit 251 (out of memory) passes through"       "$RC" "$GHC_OUT_OF_MEMORY_EXIT_STATUS"
check "out of memory under the bound names the bound" \
    "$ERR" "$BOUND_HINT"

echo "a caller's tighter limit, prlimit on PATH"
CALLER_LIMIT_KIB=$TIGHTER_CALLER_LIMIT_KIB STUB_EXIT=$GHC_OUT_OF_MEMORY_EXIT_STATUS \
    run_wrapper "$BIN_BOUNDED" script.sh
check "out of memory under a caller's tighter limit names that limit" \
    "$ERR" "$TIGHTER_CALLER_HINT"
CALLER_LIMIT_KIB=$FRACTIONAL_GIB_CALLER_LIMIT_KIB STUB_EXIT=$GHC_OUT_OF_MEMORY_EXIT_STATUS \
    run_wrapper "$BIN_BOUNDED" script.sh
check "a limit that is not whole GiB reads to two decimals" \
    "$ERR" "$FRACTIONAL_GIB_CALLER_HINT"

echo "prlimit not on PATH"
run_wrapper "$BIN_NO_PRLIMIT" -x script.sh
check "shellcheck runs directly with the arguments"  "$OUT" "shellcheck[-x][script.sh]"
check "the unbounded note is on stderr"              "$ERR" "$UNBOUNDED_NOTE"
check "exit 0 passes through"                        "$RC" "0"
run_wrapper "$BIN_NO_PRLIMIT" -x 'a file.sh'
check "an argument with a space arrives as one argument" "$OUT" "shellcheck[-x][a file.sh]"
STUB_EXIT=$SHELLCHECK_BAD_OPTIONS_EXIT_STATUS run_wrapper "$BIN_NO_PRLIMIT" script.sh
check "exit 4 passes through"                        "$RC" "$SHELLCHECK_BAD_OPTIONS_EXIT_STATUS"
STUB_EXIT=$GHC_OUT_OF_MEMORY_EXIT_STATUS run_wrapper "$BIN_NO_PRLIMIT" script.sh
check "out of memory with no bound does not blame the bound" "$ERR" "$UNBOUNDED_NOTE"

echo "the real prlimit"
run_wrapper "$BIN_REAL_PRLIMIT" script.sh
check "shellcheck starts under the bound (ulimit -v, KiB)" "$OUT" "$EXPECTED_LIMIT_KIB"
STUB_EXIT=$SHELLCHECK_BAD_OPTIONS_EXIT_STATUS run_wrapper "$BIN_REAL_PRLIMIT" script.sh
check "its child's exit status comes back"           "$RC" "$SHELLCHECK_BAD_OPTIONS_EXIT_STATUS"
CALLER_LIMIT_KIB=$TIGHTER_CALLER_LIMIT_KIB run_wrapper "$BIN_REAL_PRLIMIT" script.sh
check "a caller's tighter soft limit is kept"        "$OUT" "$TIGHTER_CALLER_LIMIT_KIB"
CALLER_LIMIT_IS_HARD=1 CALLER_LIMIT_KIB=$TIGHTER_CALLER_LIMIT_KIB \
    STUB_EXIT=$SHELLCHECK_BAD_OPTIONS_EXIT_STATUS run_wrapper "$BIN_REAL_PRLIMIT" script.sh
check "under a caller's tighter hard limit shellcheck still runs and its status comes back" \
    "$OUT, exit $RC" "$TIGHTER_CALLER_LIMIT_KIB, exit $SHELLCHECK_BAD_OPTIONS_EXIT_STATUS"

EXPECTED_ROWS=22
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31mFATAL\033[0m: expected %d rows, ran %d\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))" >&2
    exit 2
fi
echo
if (( FAIL )); then
    printf '\033[1;31m%d of %d checks failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"
    exit 1
fi
printf '\033[0;32mall %d checks passed\033[0m\n' "$PASS"
