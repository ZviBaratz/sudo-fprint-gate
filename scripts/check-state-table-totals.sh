#!/usr/bin/env bash
# Assert that every state table under scripts/ asserts its own row total.
#
# WHY THIS EXISTS. A suite that loses its row total, or never had one, can lose
# rows without anyone noticing. Counting the suites that DO have a total and
# assuming the rest are covered miscounts easily: a hand-built list of suites
# goes stale as tables are added.
#
# The complement, every table without a total, is one line of shell. So this is
# that line, as a guard: it makes the audit unnecessary instead of repeating it.
# A habit of checking by hand would not hold; a check does.
#
# WHAT A ROW TOTAL IS, AND WHY IT MATTERS. A state table here ends with
# `EXPECTED_ROWS=<n>` (or `EXPECTED_TOTAL=<n>`) compared against the rows that
# actually ran. It catches a check that VANISHED -- an early `exit`, an unset
# variable under `set -u`, a deleted block, an emptied `for` list -- where every
# row that still ran passes and the suite prints a cheerful green summary.
# Without it a suite can lose half its rows and still say "all N checks passed".
#
# BE HONEST ABOUT WHAT THIS CANNOT SEE, because the guard otherwise reads as
# more coverage than it is:
#
#   - A row total detects a SKIPPED check and never a HOLLOW one. A row whose
#     fixture cannot reach the branch it names still runs, still passes, and is
#     invisible both to the total and to this. That is what mutation sweeps are
#     for.
#   - ASSERT below requires the constant to be COMPARED somewhere, not that it
#     is compared against the number of rows that ran. `(( 1 != EXPECTED_ROWS ))`
#     would satisfy it. Deciding otherwise means parsing shell, and hand-parsing
#     a language has a measured cost: hand-written parsers of structured text
#     tend to pass silently on the shapes they did not anticipate.
#   - It says nothing about whether the number is RIGHT. A wrong total fails the
#     suite itself, loudly, which is the check that belongs there and not here.
#   - It reads the FILE, not the shell. A state table that builds fixture
#     suites containing `EXPECTED_ROWS=<n>` -- which is what a state table for
#     THIS guard does -- has that fixture text counted as its own declaration,
#     so such a file could satisfy all three rules while having no total of its
#     own. Detecting it means knowing where a heredoc begins and ends, i.e.
#     parsing shell, for one file shape. The answer instead is that
#     scripts/test-state-table-totals.sh writes its fixture totals through
#     `printf` so it injects no phantom declaration, and a row there pins that
#     it stays that way. The limitation itself has a row too, asserting what
#     the guard does rather than what it ought to.
#
# Rules print prefixes unique to themselves (TOTAL:/LITERAL:/ASSERT:/ALLOW:) so
# a state-table needle is unambiguous, and no pass-path message contains another
# rule's fail-path wording. Colour only on a tty: an unconditional escape puts
# control characters into every redirect and makes a tick un-greppable, which
# has already let a state-table row pass whatever was printed.
#
# Exit 0 = every rule evaluated and none violated. 1 = a rule was violated (the
# tree is wrong). 2 = could not run -- an unreadable suite, a missing scripts/
# directory, or a glob that matched nothing. 3 = this script is self-inconsistent
# (a rule was skipped). 2 and 3 are distinct on purpose: a skipped check means
# the guard is broken and a violation
# means the tree is broken, and a state-table row can only pin the difference if
# the codes differ.
#
# Exit 2 is the one that matters most here. Every way of getting a path or a
# glob wrong -- a renamed directory, an unreadable file, a typo in the pattern --
# would otherwise narrow this check into silence while it reported a clean tree.
# Narrowing into silence IS the failure mode this guard exists to prevent, so it
# is the one it must not have.
set -uo pipefail

EXPECTED_CHECKS=4

# THE ALLOW-LIST. Named and justified here, never implied by absence: a suite
# that is simply missing from an enumeration is how a hand-built list goes
# stale, so an exemption has to be written down and argued.
# A stale entry is a rule whose condition can no longer fire, so ALLOW below
# FAILS on an entry naming no file -- the list cannot rot quietly.
#
# Empty in this repository: every scripts/test-*.sh here is a shell state table
# with a row total of its own. An entry belongs here only for a suite whose
# count another tool already owns (a wrapper around a test runner that counts
# and reports its own tests), with the argument written beside it.
ALLOWLIST=()

if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'; else RED=''; GRN=''; RST=''; fi

die_cannot_run() { printf '%scheck-state-table-totals: %s%s\n' "$RED" "$1" "$RST" >&2; exit 2; }

root=${1:-}
case "$root" in
    -*) die_cannot_run "unrecognised argument: $root" ;;
esac
if [ -z "$root" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null) ||
        die_cannot_run "not a git repository and no root given"
fi
[ -d "$root" ] || die_cannot_run "no such directory: $root"
[ -d "$root/scripts" ] || die_cannot_run "no $root/scripts directory"
[ -x "$root/scripts" ] || die_cannot_run "$root/scripts exists but cannot be enumerated"

# nullglob so an unmatched pattern yields nothing rather than the pattern
# itself -- and then the emptiness is checked, because "no files matched" must
# be exit 2 and never a clean run over zero suites.
shopt -s nullglob
suites=( "$root"/scripts/test-*.sh )
[ "${#suites[@]}" -gt 0 ] ||
    die_cannot_run "no scripts/test-*.sh under $root -- refusing to report a clean tree over zero suites"

checks=0; viol=0
ok()   { checks=$((checks+1)); printf '%s  ok%s   %s\n' "$GRN" "$RST" "$1"; }
bad()  { checks=$((checks+1)); viol=$((viol+1)); printf '%s  BAD%s  %s\n' "$RED" "$RST" "$1"; }
note() { printf '       %s\n' "$1"; }

is_allowed() { # is_allowed <repo-relative-path>
    local a
    for a in "${ALLOWLIST[@]}"; do [ "$a" = "$1" ] && return 0; done
    return 1
}

# declared_names prints the row-total constants a file ASSIGNS, one per line.
#
# The anchor is what keeps prose out: a comment saying "EXPECTED_ROWS=37 is the
# total" begins with `#`, which `[[:space:]]*` does not match, so it is not an
# assignment here. That matters because an assignment recognised inside a
# comment would let a file document a total it does not have.
#
# The trimming is `sed`, not `tr -d '[:space:]='`, and that was a live defect
# rather than a style preference. `[:space:]` includes the NEWLINE, so `tr`
# welded every match into one token -- `EXPECTED_ROWSEXPECTED_TOTAL` -- which
# then matched no assignment and no comparison, and the file was reported as
# having a computed, uncompared total. It was invisible over every suite of
# the repository, because each of them assigns the constant exactly ONCE, so
# there was nothing to weld; the first file with two assignments was this
# guard's own state table, which builds fixtures that contain totals. A rule
# that is correct only on inputs of length one, over a corpus that happens to
# be all length one, is the "green over the thing it exists to catch" shape
# one more time. `sed` edits per line and cannot weld.
declared_names() { # declared_names <file>
    grep -oE '^[[:space:]]*EXPECTED_(ROWS|TOTAL)=' "$1" 2>/dev/null |
        sed 's/[[:space:]]//g; s/=$//' | sort -u
}

# literal_assign: the constant is a DECIMAL LITERAL written down, not computed.
#
# `EXPECTED_ROWS=$((PASS + FAIL))` parses, runs, and makes the total vacuous --
# the suite then asserts that the number of rows equals the number of rows. It
# is also the obvious way to "fix" a red total under time pressure, and it goes
# green forever. A computed total is worse than no total, because it looks like
# one, so it gets its own rule rather than being folded into TOTAL.
literal_assign() { # literal_assign <file> <name>
    grep -qE "^[[:space:]]*$2=[0-9]+[[:space:]]*(#.*)?\$" "$1" 2>/dev/null
}

# compared_somewhere: the constant is read back in a comparison, on a line that
# is not its own assignment.
#
# Both spellings in use are covered: `(( PASS + FAIL != EXPECTED_ROWS ))`
# has no `$` sigil at all because it is inside arithmetic, and
# `[ "$((pass + fail))" -ne "$EXPECTED_TOTAL" ]` has one. So the name is matched
# bare and the line must also carry a comparison operator. Requiring the sigil
# would have failed every `(( ))` suite, which is most of them -- a guard that
# refuses the majority spelling of a correct thing gets deleted.
#
# The operator requirement is what stops the prose around these blocks from
# satisfying the rule: every suite's comment mentions the constant by name while
# explaining it, and none of those sentences contains `!=`, `-ne`, `-eq` or `==`.
compared_somewhere() { # compared_somewhere <file> <name>
    grep -nE "(^|[^A-Za-z0-9_])$2([^A-Za-z0-9_]|\$)" "$1" 2>/dev/null |
        grep -vE "^[0-9]+:[[:space:]]*$2=" |
        grep -qE '(!=|==|-ne|-eq)'
}

no_total=''; computed=''; unused=''; considered=0
for f in "${suites[@]}"; do
    rel=${f#"$root"/}
    # An unreadable suite is exit 2, never "it has no total" and never "it has
    # one". Both readings are answers this script cannot support, and one of
    # them is a clean bill of health over a file nobody looked at.
    [ -r "$f" ] || die_cannot_run "cannot read $rel -- refusing to guess whether it has a row total"
    is_allowed "$rel" && continue
    considered=$((considered + 1))

    names=$(declared_names "$f")
    if [ -z "$names" ]; then
        no_total="$no_total$rel "
        continue
    fi

    have_lit=1; have_cmp=1
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        literal_assign "$f" "$n" && have_lit=0
        compared_somewhere "$f" "$n" && have_cmp=0
    done <<EOF
$names
EOF
    [ "$have_lit" -eq 0 ] || computed="$computed$rel "
    [ "$have_cmp" -eq 0 ] || unused="$unused$rel "
done

# --- R1 TOTAL ------------------------------------------------------------
if [ -z "$no_total" ]; then
    ok "TOTAL: all $considered state table(s) declare a row total"
else
    bad "TOTAL: no row total in: ${no_total% }"
    note "Fix: end the suite with EXPECTED_ROWS=<n> compared against the rows that ran."
    note "     The worked example is the tail of scripts/test-sudo-fprint-gate.sh."
fi

# --- R2 LITERAL ----------------------------------------------------------
if [ -z "$computed" ]; then
    ok "LITERAL: every row total is a decimal number written down"
else
    bad "LITERAL: row total computed at run time in: ${computed% }"
    note "Fix: write the number. A total derived from the rows that ran asserts nothing."
fi

# --- R3 ASSERT -----------------------------------------------------------
if [ -z "$unused" ]; then
    ok "ASSERT: every row total is read back in a comparison"
else
    bad "ASSERT: row total declared and never compared in: ${unused% }"
    note "Fix: compare it -- (( PASS + FAIL != EXPECTED_ROWS )) -- and fail the suite when it differs."
fi

# --- R4 ALLOW ------------------------------------------------------------
# A stale exemption is a rule whose condition can no longer fire, and those are
# retired rather than left lying around. Left lying around it is also a hazard:
# a future suite reusing the name, a shell state table this time, would be
# exempted by an entry written about a different file that no longer exists.
missing_allow=''
for a in "${ALLOWLIST[@]}"; do
    [ -f "$root/$a" ] || missing_allow="$missing_allow$a "
done
if [ -z "$missing_allow" ]; then
    ok "ALLOW: all ${#ALLOWLIST[@]} allow-list entr(y/ies) name a file that exists"
else
    bad "ALLOW: allow-list names no such file: ${missing_allow% }"
    note "Fix: remove the entry. An exemption for a file that is gone exempts the next file to take its name."
fi

# --- summary -------------------------------------------------------------
# Printed on every exit path, so `suites=0 considered=0` can never be mistaken
# for a clean enumeration in a CI log.
printf 'SUMMARY: suites=%s considered=%s exempt=%s root=%s\n' \
    "${#suites[@]}" "$considered" "${#ALLOWLIST[@]}" "$root"

if [ "$checks" -ne "$EXPECTED_CHECKS" ]; then
    printf '%scheck-state-table-totals: performed %d checks, expected %d — a check vanished%s\n' \
        "$RED" "$checks" "$EXPECTED_CHECKS" "$RST" >&2
    exit 3
fi
if [ "$viol" -gt 0 ]; then
    printf '%scheck-state-table-totals: %d of %d checks failed%s\n' "$RED" "$viol" "$checks" "$RST" >&2
    exit 1
fi
printf '%scheck-state-table-totals: all %d checks passed%s\n' "$GRN" "$checks" "$RST"
