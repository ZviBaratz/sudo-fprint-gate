#!/usr/bin/env bash
#
# scripts/shellcheck-bounded.sh — run shellcheck with its address space bounded
#
# WHY. This is the pre-commit hook's entry. A large state table can drive an unbounded
# run to about 8.9 GB resident. Under the bound, a file that outgrows it fails one hook
# ("shellcheck: out of memory", exit 251) instead of squeezing the machine.
#
# 3 GiB, NOT 2. The bound and this wrapper come from the resource-pulse
# repository, whose heaviest state table failed at 2000 MiB of address space and
# passed at 2048 MiB (about 1.3 GiB resident). This repository's tables are
# smaller; the same bound keeps one wrapper, one behaviour, in both.
#
# HOW. `prlimit --as=BYTES shellcheck "$@"` sets RLIMIT_AS on shellcheck. That
# is the only handle there is: its GHC runtime refuses RTS options such as
# `+RTS -M`. GHC sizes its heap to a fraction of RLIMIT_AS, so resident memory
# stays well below the bound.
#
# ONLY EVER TIGHTER. prlimit sets the soft and the hard limit together, and
# raising a hard limit needs privilege. So the bound applied is the smaller of
# this wrapper's and the caller's own soft limit (never above its hard one). A
# caller's tighter limit is kept: never loosened, and never turned into a
# prlimit failure whose exit 1 reads as findings.
#
# PER PROCESS, NOT A TOTAL. Each shellcheck started here gets the whole bound.
# The hook is `require_serial: true`, so pre-commit runs one at a time.
#
# WITHOUT prlimit (it is util-linux, so macOS has none) the wrapper runs it
# unbounded, with a one-line note on stderr, so the hook keeps working there.
#
# Exit status: shellcheck's, unchanged. When shellcheck is not on PATH, 127,
# from prlimit or bash with its own message.
# State table: scripts/test-shellcheck-bounded.sh. The hook that runs it:
# .pre-commit-config.yaml.
set -u

readonly SHELLCHECK_ADDRESS_SPACE_LIMIT_BYTES=3221225472  # 3 GiB
readonly BYTES_PER_KIB=1024
readonly BYTES_PER_GIB=1073741824
# GHC's runtime exits with this status when it cannot allocate more heap.
readonly GHC_OUT_OF_MEMORY_EXIT_STATUS=251

note() { printf 'shellcheck-bounded: %s\n' "$*" >&2; }

# Prints the bound to apply, in bytes: this wrapper's, or the caller's own soft
# limit when that is tighter. `ulimit -S -v` answers in KiB, or `unlimited`;
# anything that is not a number leaves this wrapper's bound. Compared in KiB,
# so a huge caller limit cannot overflow bash's arithmetic.
effective_bound_bytes() {
    local caller_soft_limit_kib
    caller_soft_limit_kib=$(ulimit -S -v)
    if [[ "$caller_soft_limit_kib" =~ ^[0-9]+$ ]] &&
        (( caller_soft_limit_kib <= SHELLCHECK_ADDRESS_SPACE_LIMIT_BYTES / BYTES_PER_KIB )); then
        printf '%d' "$(( caller_soft_limit_kib * BYTES_PER_KIB ))"
    else
        printf '%d' "$SHELLCHECK_ADDRESS_SPACE_LIMIT_BYTES"
    fi
}

# Prints a byte count in GiB: whole, or else to two decimals, truncated.
format_gib() {
    local bytes=$1 hundredths_of_gib
    if (( bytes % BYTES_PER_GIB == 0 )); then
        printf '%d GiB' "$(( bytes / BYTES_PER_GIB ))"
    else
        hundredths_of_gib=$(( bytes * 100 / BYTES_PER_GIB ))
        printf '%d.%02d GiB' "$(( hundredths_of_gib / 100 ))" "$(( hundredths_of_gib % 100 ))"
    fi
}

# Runs shellcheck under the bound. When it runs out of memory there, names the
# bound and whose it is, since GHC's own message does not.
run_bounded() {
    local bound_bytes bound_owner='' bound_description shellcheck_status=0
    bound_bytes=$(effective_bound_bytes)
    if (( bound_bytes < SHELLCHECK_ADDRESS_SPACE_LIMIT_BYTES )); then
        bound_owner=", the caller's own limit"
    fi
    prlimit --as="$bound_bytes" shellcheck "$@" || shellcheck_status=$?
    if (( shellcheck_status == GHC_OUT_OF_MEMORY_EXIT_STATUS )); then
        bound_description="$(format_gib "$bound_bytes") ($bound_bytes bytes)$bound_owner"
        note "shellcheck ran out of memory under its address-space bound of" \
            "$bound_description; see the header of scripts/shellcheck-bounded.sh"
    fi
    return "$shellcheck_status"
}

run_unbounded() {
    note "prlimit not found, so shellcheck runs with no memory bound"
    exec shellcheck "$@"
}

main() {
    if command -v prlimit >/dev/null 2>&1; then
        run_bounded "$@"
    else
        run_unbounded "$@"
    fi
}

main "$@"
