#!/usr/bin/env bash
# shellcheck disable=SC2016  # see "the fixture text is the string under test" below
# State table for scripts/check-state-table-totals.sh.
#
# Hermetic: every row builds its own fixture tree under a temp dir and runs the
# checker against it with an explicit root. Nothing reads this repository except
# the integration rows at the end, which assert that the tree we actually ship
# passes its own guard.
#
# THE NEEDLE RULES THIS SUITE OBEYS, both learned the hard way in another
# guard's state table and both about needles rather than fixtures:
#
#   - A `contains` needle must be UNIQUE TO THE RULE under test, not merely
#     absent from the pass path. Three rules of that guard printed
#     `<file>:<line>` in the same format, so a bare path needle there was
#     ambiguous by construction and one row passed with the wrong rule's
#     message satisfying it.
#   - Check the needle against what the PASS path prints too. One rule's ok
#     and bad messages in that guard shared a phrase, so the needle built from
#     it asserted nothing.
#
# So each rule's fail needle gets a `lacks` row against a clean tree's output,
# under "no fail needle appears on the pass path". Those rows are not padding:
# they are the only thing standing between this suite and four needles that
# match whatever is printed.
#
# WHAT THIS SUITE CANNOT REACH. The checker's exit 3 ("a check vanished") has no
# fixture, because all four rules run unconditionally on every input -- there is
# no tree that makes `checks` differ from EXPECTED_CHECKS. That is a property of
# the checker worth having and not a gap to paper over with a row; it is reached
# by the mutation sweep instead, which deletes a rule and expects exit 3.
set -uo pipefail

# THE FIXTURE TEXT IS THE STRING UNDER TEST (the SC2016 waiver on line 2, which
# has to sit before the first command to be file-wide -- placed after
# `set -uo pipefail` it scopes to the next command only, and local shellcheck
# 0.11.0 still flagged all five sites while the pinned 0.9.0.6 stayed silent).
# The fixture builders below print literal `$((PASS + FAIL))`, `$EXPECTED_ROWS`
# and `$EXPECTED_TOTAL` into the suites they write. Those are the strings under
# test -- a computed total is one of the defects this guard must catch -- not
# expansions this script wants performed.

CHECKER=${CHECKER:-}
if [ -z "$CHECKER" ]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    CHECKER="$here/check-state-table-totals.sh"
fi
[ -x "$CHECKER" ] || { printf 'test-state-table-totals: %s is not executable\n' "$CHECKER" >&2; exit 2; }

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

pass=0; fail=0
ROOT=$(mktemp -d)
# A fixture row makes a file unreadable. If the suite dies between the chmod and
# the cleanup, `rm -rf` still works (the directory above it is ours), but restore
# the mode anyway so an interrupted run leaves nothing odd behind.
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

check() { # check <desc> <expected-rc> <actual-rc>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %s\n' "$1"
    else
        fail=$((fail + 1)); printf '  FAIL %s (expected rc=%s, got rc=%s)\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <desc> <haystack> <needle>
    case "$2" in
        *"$3"*) pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
        *)      fail=$((fail + 1)); printf '  FAIL %s (missing: %s)\n' "$1" "$3" ;;
    esac
}
lacks() { # lacks <desc> <haystack> <needle>
    case "$2" in
        *"$3"*) fail=$((fail + 1)); printf '  FAIL %s (unexpectedly present: %s)\n' "$1" "$3" ;;
        *)      pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
    esac
}

# --- fixture builders ----------------------------------------------------
# The checker's allow-list is EMPTY in this repository, so a fixture carries no
# exempt file, and the counts below say `exempt=0`. That is pinned rather than
# derived from the checker: deriving it would test the checker with itself, and
# adding an allow-list entry SHOULD break this suite loudly rather than quietly
# widen what it tolerates.
mkfix() { # mkfix -> prints a fresh fixture root, with an empty scripts/
    local d
    d=$(mktemp -d "$ROOT/fix.XXXXXX")
    mkdir -p "$d/scripts"
    printf '%s' "$d"
}

# EVERY FIXTURE TOTAL BELOW IS WRITTEN THROUGH printf, NEVER AS A HEREDOC LINE,
# and that is load-bearing rather than a style choice. The checker reads the
# FILE rather than the shell, so a line beginning `EXPECTED_ROWS=` inside a
# heredoc in THIS file would be counted as this file's own declaration. Two
# fixtures deliberately carry a *computed* and an *uncompared* total; as heredoc
# text those would make the guard report its own state table as the violation,
# and -- worse -- a phantom declaration would let this suite satisfy the guard
# with `EXPECTED_TOTAL` deleted, making the repo's newest state table exempt in
# practice from the guard it ships. Writing them as printf arguments puts
# `printf` at the start of the line, so this file declares exactly one row-total
# constant: its own. A row under "this suite injects no phantom declaration"
# pins that, and the limitation itself is pinned under "fixture text is text".
emit() { printf '%s\n' "$@"; }

# A suite the checker must accept: a literal total, compared in the `(( ))`
# spelling that carries no `$` sigil -- the form every table here uses.
good_suite() { # good_suite <root> <basename>
    emit '#!/usr/bin/env bash' \
         'PASS=0; FAIL=0' \
         'EXPECTED_ROWS=3' \
         'if (( PASS + FAIL != EXPECTED_ROWS )); then FAIL=$((FAIL + 1)); fi' \
         > "$1/scripts/$2"
}

# A suite with rows and a summary but no total at all -- the defect this guard
# exists for.
bare_suite() { # bare_suite <root> <basename>
    emit '#!/usr/bin/env bash' \
         'PASS=0; FAIL=0' \
         'printf "=== %d passed, %d failed ===\\n" "$PASS" "$FAIL"' \
         > "$1/scripts/$2"
}

run() { out=$("$CHECKER" "$1" 2>&1); rc=$?; }

printf '== a tree whose suites all declare a total ==\n'
d=$(mkfix); good_suite "$d" test-a.sh; good_suite "$d" test-b.sh
run "$d"
check    "a clean tree passes"              0 "$rc"
contains "  and counts the suites it read"  "$out" "TOTAL: all 2 state table(s) declare a row total"
contains "  and reports the exempt count"   "$out" "suites=2 considered=2 exempt=0"

printf '\n== no fail needle appears on the pass path ==\n'
# These four are what make the `contains` rows below mean anything: a needle
# that also occurs when the rule passes asserts nothing at all.
lacks "the TOTAL pass message is not the TOTAL fail needle"     "$out" "TOTAL: no row total in:"
lacks "the LITERAL pass message is not the LITERAL fail needle" "$out" "LITERAL: row total computed at run time in:"
lacks "the ASSERT pass message is not the ASSERT fail needle"   "$out" "ASSERT: row total declared and never compared in:"
lacks "the ALLOW pass message is not the ALLOW fail needle"     "$out" "ALLOW: allow-list names no such file:"

printf '\n== a suite with no row total ==\n'
d=$(mkfix); good_suite "$d" test-a.sh; bare_suite "$d" test-b.sh
run "$d"
check    "a suite with no total fails the tree"      1 "$rc"
contains "  under the TOTAL rule"                    "$out" "TOTAL: no row total in:"
contains "  naming the offending file"               "$out" "scripts/test-b.sh"
lacks    "  and not the compliant one"               "$out" "scripts/test-a.sh"
contains "  with the fix and the worked example"     "$out" "scripts/test-sudo-fprint-gate.sh"
lacks    "  and no other rule is dragged in"         "$out" "LITERAL: row total computed at run time in:"

printf '\n== EVERY offending file is named, not just the first ==\n'
# This is the whole point of the guard. A checker that stopped at the first hit
# would report a subset as if it were the set, the very defect the guard exists
# to prevent.
d=$(mkfix); bare_suite "$d" test-a.sh; bare_suite "$d" test-b.sh; bare_suite "$d" test-c.sh
run "$d"
check    "three bare suites fail"   1 "$rc"
contains "  the first is named"     "$out" "scripts/test-a.sh"
contains "  the second is named"    "$out" "scripts/test-b.sh"
contains "  the third is named"     "$out" "scripts/test-c.sh"

printf '\n== a total computed at run time is not a total ==\n'
# The obvious way to silence a red row total under time pressure, and it goes
# green forever: the suite then asserts that the rows that ran equal the rows
# that ran. It is worse than no total because it looks like one.
d=$(mkfix)
emit '#!/usr/bin/env bash' \
     'PASS=1; FAIL=0' \
     'EXPECTED_ROWS=$((PASS + FAIL))' \
     'if (( PASS + FAIL != EXPECTED_ROWS )); then FAIL=$((FAIL + 1)); fi' \
     > "$d/scripts/test-a.sh"
run "$d"
check    "a computed total fails"          1 "$rc"
contains "  under the LITERAL rule"        "$out" "LITERAL: row total computed at run time in:"
contains "  naming the file"               "$out" "scripts/test-a.sh"
lacks    "  and not as a missing total"    "$out" "TOTAL: no row total in:"

printf '\n== a total nobody compares is not a total ==\n'
d=$(mkfix)
emit '#!/usr/bin/env bash' \
     'PASS=0; FAIL=0' \
     'EXPECTED_ROWS=3' \
     'printf "done\\n"' \
     > "$d/scripts/test-a.sh"
run "$d"
check    "a declared-but-unused total fails" 1 "$rc"
contains "  under the ASSERT rule"           "$out" "ASSERT: row total declared and never compared in:"
lacks    "  and not as a missing total"      "$out" "TOTAL: no row total in:"

printf '\n== prose about a total is not a total ==\n'
# Both halves matter. A comment can describe a total the file does not have,
# and a suite's comments routinely explain its total by name -- so a
# rule satisfied by a mention would be satisfied everywhere and assert nothing.
d=$(mkfix)
emit '#!/usr/bin/env bash' \
     'PASS=0; FAIL=0' \
     '# EXPECTED_ROWS=3 is the number of rows this suite runs.' \
     'printf "done\\n"' \
     > "$d/scripts/test-a.sh"
run "$d"
check    "a commented-out assignment is not an assignment" 1 "$rc"
contains "  so the file still has no row total"            "$out" "TOTAL: no row total in:"

d=$(mkfix)
emit '#!/usr/bin/env bash' \
     'PASS=0; FAIL=0' \
     'EXPECTED_ROWS=3' \
     '# The number above is EXPECTED_ROWS, which pins how many rows ran.' \
     'printf "done\\n"' \
     > "$d/scripts/test-a.sh"
run "$d"
check    "a comment mentioning the name does not satisfy ASSERT" 1 "$rc"
contains "  the total is still never compared"                   "$out" "ASSERT: row total declared and never compared in:"

d=$(mkfix)
emit '#!/usr/bin/env bash' \
     'PASS=0; FAIL=0' \
     'EXPECTED_ROWS=3   # the suite exits 1 if PASS + FAIL != EXPECTED_ROWS' \
     'printf "done\\n"' \
     > "$d/scripts/test-a.sh"
run "$d"
check    "a comparison described in the assignment's own trailing comment does not count" 1 "$rc"
contains "  the total is still never compared"  "$out" "ASSERT: row total declared and never compared in:"
# This row is what makes the assignment-line filter in `compared_somewhere` load
# bearing rather than defensive. Without it the `!=` in this perfectly ordinary
# explanatory comment satisfies ASSERT, and a suite that only DESCRIBES its
# comparison passes as though it performed one.

printf '\n== the spellings in use are all accepted ==\n'
# A guard that refuses a correct thing gets deleted. Each of these spellings is
# in use in a state table: the `(( ))` one in every table here, the
# EXPECTED_TOTAL one in this suite.
d=$(mkfix)
emit '#!/usr/bin/env bash' \
     'pass=0; fail=0' \
     'EXPECTED_TOTAL=114' \
     'if [ "$((pass + fail))" -ne "$EXPECTED_TOTAL" ]; then exit 1; fi' \
     > "$d/scripts/test-a.sh"
run "$d"
check "EXPECTED_TOTAL with [ -ne ] and a sigil is accepted" 0 "$rc"

d=$(mkfix)
emit '#!/usr/bin/env bash' \
     'TOTAL=1' \
     'EXPECTED_ROWS=131' \
     'if (( TOTAL != EXPECTED_ROWS )); then exit 1; fi' \
     > "$d/scripts/test-a.sh"
run "$d"
check "a bare (( )) comparison with no sigil is accepted" 0 "$rc"

d=$(mkfix)
emit '#!/usr/bin/env bash' \
     'PASS=0; FAIL=0' \
     '    EXPECTED_ROWS=3   # indented, with a trailing comment' \
     '    if (( PASS + FAIL != EXPECTED_ROWS )); then FAIL=1; fi' \
     > "$d/scripts/test-a.sh"
run "$d"
check "an indented assignment with a trailing comment is accepted" 0 "$rc"

printf '\n== a suite that declares TWO row-total constants ==\n'
# THE ROW THAT PINS THE `tr` DEFECT. `declared_names` once trimmed its matches
# with `tr -d '[:space:]='`, and `[:space:]` includes the NEWLINE -- so two matches
# welded into the single token `EXPECTED_ROWSEXPECTED_TOTAL`, which then matched
# no assignment and no comparison, and the file was reported as having a
# computed, uncompared total.
#
# Every other suite assigns the constant exactly ONCE, so no fixture and no
# integration row has two but this one: without it, re-introducing the defect
# would survive the whole suite. That is the gap this fixture closes, and the shape is
# realistic rather than contrived: a state table whose fixtures are themselves
# state tables is exactly what a suite for this guard is.
d=$(mkfix)
emit '#!/usr/bin/env bash' \
     'pass=0; fail=0' \
     'cat > fixture.sh <<FIX' \
     'EXPECTED_ROWS=3' \
     'FIX' \
     'EXPECTED_TOTAL=5' \
     'if [ "$((pass + fail))" -ne "$EXPECTED_TOTAL" ]; then exit 1; fi' \
     > "$d/scripts/test-a.sh"
run "$d"
check    "a file declaring two row-total constants is accepted" 0 "$rc"
lacks    "  neither is read as computed"  "$out" "LITERAL: row total computed at run time in:"
lacks    "  nor as never compared"        "$out" "ASSERT: row total declared and never compared in:"

printf '\n== only scripts/test-*.sh is in scope ==\n'
d=$(mkfix); good_suite "$d" test-a.sh
printf '#!/usr/bin/env bash\necho hi\n' > "$d/scripts/check-something.sh"
printf '#!/usr/bin/env bash\necho hi\n' > "$d/scripts/helper.sh"
printf 'notes about test-things\n'      > "$d/scripts/test-notes.txt"
mkdir -p "$d/scripts/sub"
printf '#!/usr/bin/env bash\necho hi\n' > "$d/scripts/sub/test-nested.sh"
run "$d"
check    "a checker, a helper, a .txt and a nested file are all out of scope" 0 "$rc"
contains "  and the suite count says so"  "$out" "suites=1 considered=1"

printf '\n== the allow-list ==\n'
# Empty in this repository, so its exemption and its stale-entry failure have
# no fixture here: both need an entry. What an empty list must do is evaluate
# the rule and pass it, never skip it.
d=$(mkfix); good_suite "$d" test-a.sh
run "$d"
check    "an empty allow-list passes the tree"       0 "$rc"
contains "  and the ALLOW rule says it has no entry" "$out" "ALLOW: all 0 allow-list entr(y/ies) name a file that exists"

printf '\n== could not run is exit 2, never a pass ==\n'
# Every way of getting a path or a glob wrong would otherwise narrow this check
# into silence while it reported a clean tree -- which is the exact failure mode
# the guard exists to prevent, so it is the one it must not have.
d=$(mkfix); rm -rf "$d/scripts"
run "$d"
check    "a tree with no scripts/ is exit 2" 2 "$rc"
contains "  and says so"                     "$out" "no $d/scripts directory"
lacks    "  and never reports a clean tree"  "$out" "all 4 checks passed"

d=$(mkfix)   # scripts/ exists, and is empty
run "$d"
check    "a scripts/ with no test-*.sh at all is exit 2" 2 "$rc"
contains "  and refuses to report on zero suites"        "$out" "refusing to report a clean tree over zero suites"

d=$(mkfix); good_suite "$d" test-a.sh
chmod 000 "$d/scripts/test-a.sh"
run "$d"
chmod 644 "$d/scripts/test-a.sh"
check    "an unreadable suite is exit 2"                 2 "$rc"
contains "  naming it, and refusing to guess"            "$out" "refusing to guess whether it has a row total"
lacks    "  rather than reporting it as having no total" "$out" "TOTAL: no row total in:"

run "$ROOT/no-such-tree"
check    "a root that does not exist is exit 2" 2 "$rc"
contains "  and says which"                     "$out" "no such directory"

out=$("$CHECKER" --wat 2>&1); rc=$?
check    "an unrecognised argument is exit 2"   2 "$rc"
contains "  rather than being read as a path"   "$out" "unrecognised argument"

printf '\n== fixture text is text, and the guard cannot tell ==\n'
# AN HONEST LIMITATION, PINNED RATHER THAN HIDDEN. The checker reads the file,
# not the shell, so a state table that builds fixture suites containing a row
# total has that fixture text counted as its own declaration -- and can
# therefore satisfy all three rules with no total of its own. Telling the
# difference means knowing where a heredoc begins and ends, which is parsing
# shell for one file shape, and hand-parsing a language has a measured cost
# (a hand-written reader passes silently on the shapes it did not anticipate).
#
# This row asserts what the guard DOES, not what it ought to. If someone later
# teaches it about heredocs, this row fails and is the place they find out that
# the fixtures below depend on the old behaviour.
d=$(mkfix)
emit '#!/usr/bin/env bash' \
     'PASS=0; FAIL=0' \
     'cat > fixture.sh <<FIX' \
     'EXPECTED_ROWS=3' \
     'if (( PASS + FAIL != EXPECTED_ROWS )); then FAIL=1; fi' \
     'FIX' \
     > "$d/scripts/test-a.sh"
run "$d"
check "a total that exists only as fixture text is accepted" 0 "$rc"

printf '\n== this suite injects no phantom declaration ==\n'
# Which is why the fixtures above are written through `emit`/`printf` and never
# as heredoc lines. Without this row the property is an accident that the next
# edit silently undoes -- and undoing it would exempt the repo's newest state
# table from the guard it ships, because the guard would then see a total in
# this file whether or not it has one.
self_decls=$(grep -cE '^[[:space:]]*EXPECTED_(ROWS|TOTAL)=' "${BASH_SOURCE[0]}")
check "this file declares exactly one row-total constant" "$self_decls" 1

printf '\n== the tree we ship ==\n'
run "$repo"
check    "this repository passes its own guard"        0 "$rc"
contains "  having enumerated its real suite set"      "$out" "SUMMARY: suites="
contains "  and every rule was evaluated"              "$out" "all 4 checks passed"
# The guard's own suite is a state table under scripts/, so it is in scope for
# the guard. A checker exempt from itself is the first place an exemption grows.
contains "  including this suite, which is in scope"   "$(printf '%s\n' "$repo"/scripts/test-*.sh)" "test-state-table-totals.sh"

# --- the row total ------------------------------------------------------------
# The total catches a row that VANISHED (an early exit, a deleted block, an unset
# variable under `set -u`) -- every row that still ran would pass and this suite
# would print a green summary. It does NOT catch a fixture that failed to build:
# such a row still runs and still passes.
#
# This number lives here, in the state table, deliberately. Changing it is a
# visible edit a reviewer reads as "this expects fewer checks now, why", where a
# literal beside the code gets updated by whoever removes the check.
EXPECTED_TOTAL=58

printf '\n'
if [ "$((pass + fail))" -ne "$EXPECTED_TOTAL" ]; then
    printf 'test-state-table-totals: performed %d checks, expected %d — a row vanished\n' \
        "$((pass + fail))" "$EXPECTED_TOTAL"
    exit 1
fi
if [ "$fail" -gt 0 ]; then
    printf 'test-state-table-totals: %d passed, %d FAILED\n' "$pass" "$fail"
    exit 1
fi
printf 'test-state-table-totals: all %d checks passed\n' "$pass"
