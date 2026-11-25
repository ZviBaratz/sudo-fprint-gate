#!/usr/bin/env bash
# sudo-fprint-gate.sh — let sudo take a fingerprint AFTER the password, without
# ever putting a fingerprint wait in front of a password anywhere.
# SPDX-License-Identifier: GPL-2.0-or-later
#
#   /etc/pam.d/sudo-fingerprint                  from pam/   root 0644
#       the password first, then (gated) the fingerprint
#   /usr/local/libexec/fingerprint-should-offer  from pam/   root 0755
#       the gate: sudo or sudo-i only, a local account, a real terminal, the
#       lid open; anything else, or a gate that cannot run, is a skip
#   /etc/pam.d/sudo, /etc/pam.d/sudo-i           ONE line each, edited in place
#       `@include sudo-fingerprint` immediately before
#       `@include common-auth`. Both are sudo-common conffiles: one line, never a
#       replaced file.
#   /etc/gdm3/greeter.dconf-defaults             TWO lines, edited in place, ONLY
#       with --greeter-password-only: enable-fingerprint-authentication=false for
#       the GREETER alone, because a fingerprint login leaves the GNOME keyring
#       locked. The lock screen reads the same key from your own dconf and keeps
#       the fingerprint.
#
# The lock screen needs nothing here: GDM runs gdm-fingerprint BESIDE
# gdm-password, the one place both can be offered at once. common-auth, polkit,
# su and login are NOT touched, and --check fails if any PAM service other than
# gdm-fingerprint and this stanza ever runs pam_fprintd, which the stock
# `pam-auth-update --enable fprintd` would do in front of every password on the
# machine. Why each piece is shaped as it is: docs/guide.md.
#
# BEFORE THE FIRST WRITE the stanza is checked three ways, and the install
# refuses, writing nothing, on any failure:
#   - STATICALLY: every control field is one libpam knows, and every numeric
#     jump lands exactly one line past pam_fprintd. One line further lands
#     inside common-auth, and three further on its `required pam_permit.so`,
#     which authenticates with no credential at all (measured).
#   - Through the REAL libpam (scripts/pam-stack-probe.py, pam_start_confdir)
#     with a CORRECT password standing in: it must authenticate. One misspelled
#     keyword makes libpam refuse every sudo (measured: PAM_PERM_DENIED).
#   - Through the real libpam with a WRONG password, the stanza's own control
#     fields, and stand-ins for the gate and the reader: a gate that offers must
#     reach the reader, one that skips or is missing must not, a matching finger
#     must authenticate, and nothing else may. A typo in a control field is
#     invisible to the correct-password probe, which returns at the first line;
#     these catch it (measured: `defualt=1` reached the reader).
# --check runs all three against the installed files. The install also refuses
# any auth module outside a known set anywhere on the auth chain that follows
# the stanza's include in sudo and sudo-i (common-auth, and every file an
# @include, `auth include` or `auth substack` there brings in): the stanza's
# `sufficient pam_unix` ENDS that chain on a correct password, so a lockout
# check (pam_faillock) or a second factor there would never run. It follows
# each include as libpam resolves it, and refuses one it cannot open or read,
# a loop, and nesting deeper than libpam loads.
#
# Copied root-owned, never symlinked: root's PAM reads them. Every write is a
# root-owned temporary file RENAMED into place, so a concurrent sudo never reads
# half a stack. The stanza goes in before any include, and every include comes
# out before the stanza does, because libpam aborts the whole stack when an
# @include cannot be opened (measured: PAM_ABORT, before any prompt). The gate's
# order does not matter: a missing gate is a skip.
#
# Run it as yourself, from a primary checkout: it calls sudo for each write, and
# refuses to install from a linked git worktree, or from a submodule inside one
# (root would run files from a branch nobody may have reviewed). Idempotent:
# re-run it to resync after editing the repository copies. gdm is RELOADED (its
# ExecReload only recompiles the greeter config), never restarted, because a
# restart ends the session.
#
# Usage: sudo-fprint-gate.sh [--greeter-password-only | --check | --remove]
#   (no option)              install, or resync. The greeter keeps GDM's own
#                            setting; this tool's greeter lines from an earlier
#                            --greeter-password-only are taken out again.
#   --greeter-password-only  install, and also turn the fingerprint off at the
#                            login screen (the greeter) only, so the GNOME
#                            keyring unlocks at login.
#   --check   read-only, needs no sudo: is every piece installed as this checkout
#             says, does the installed stanza pass the static and libpam checks
#             above, has gdm compiled any greeter change, and does no PAM stack
#             put pam_fprintd in front of a password? Exit 1 if not.
#   --remove  take every piece out again. The edited files return
#             byte-identical to what they were before the install.
#
# SUDO_FPRINT_GATE_PREFIX is a TEST SEAM, not an operational knob: it prefixes
# every path so the state table can run the install for real. It is refused
# unless it is an absolute path to an existing directory, and it says so loudly
# on every run where it is set.
set -euo pipefail

MODE=install
IS_GREETER_PASSWORD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check | --remove)
      if [[ "$MODE" != install ]]; then
        echo "--check and --remove cannot be combined" >&2; exit 2
      fi
      MODE="${arg#--}" ;;
    --greeter-password-only) IS_GREETER_PASSWORD_ONLY=1 ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
      "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if (( IS_GREETER_PASSWORD_ONLY )) && [[ "$MODE" != install ]]; then
  echo "--greeter-password-only belongs to an install, not to --$MODE" >&2; exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# A test seam, validated rather than trusted. Empty in every real run.
PREFIX="${SUDO_FPRINT_GATE_PREFIX:-}"
if [[ -n "$PREFIX" ]]; then
  [[ "$PREFIX" == /* && -d "$PREFIX" ]] || {
    echo "SUDO_FPRINT_GATE_PREFIX must be an absolute path to an existing directory, got '$PREFIX'" >&2
    exit 2; }
fi

STANZA_NAME="sudo-fingerprint"
STANZA_SRC="${REPO_ROOT}/pam/${STANZA_NAME}"
GATE_NAME="fingerprint-should-offer"
GATE_SRC="${REPO_ROOT}/pam/${GATE_NAME}"
# Where the stanza says the gate lives: the path pam_exec runs, never prefixed.
GATE_INSTALLED_PATH="/usr/local/libexec/${GATE_NAME}"
PAM_ETC_DIR="${PREFIX}/etc/pam.d"
PAM_VENDOR_DIR="${PREFIX}/usr/lib/pam.d"
STANZA_DST="${PAM_ETC_DIR}/${STANZA_NAME}"
GATE_DIR="${PREFIX}/usr/local/libexec"
GATE_DST="${PREFIX}${GATE_INSTALLED_PATH}"
SUDO_SERVICES=("${PAM_ETC_DIR}/sudo" "${PAM_ETC_DIR}/sudo-i")
GREETER_CONFIG="${PREFIX}/etc/gdm3/greeter.dconf-defaults"
# What gdm's generate-config compiles GREETER_CONFIG into, at every gdm start
# and on `systemctl reload gdm.service`.
GREETER_COMPILED="${PREFIX}/var/lib/gdm3/greeter-dconf-defaults"
GDM_UNIT="gdm.service"
# Every write lands at <dst>${TMP_SUFFIX} first and is renamed over <dst>.
TMP_SUFFIX=".sudo-fprint-gate.tmp"
JOURNAL_TAG="sudo-fprint-gate"
# How many superprojects up the worktree guard looks, for a submodule nested in
# a submodule. Real nesting is one or two deep.
MAX_SUPERPROJECT_DEPTH=8

INCLUDE_LINE="@include ${STANZA_NAME}"
INCLUDE_RE="^[[:space:]]*@include[[:space:]]+${STANZA_NAME}[[:space:]]*$"
COMMON_AUTH_RE='^[[:space:]]*@include[[:space:]]+common-auth[[:space:]]*$'
GREETER_SECTION='[org/gnome/login-screen]'
GREETER_SECTION_RE='^\[org/gnome/login-screen\]$'
GREETER_MARKER='# sudo-fprint-gate: no fingerprint at the greeter, so the GNOME keyring unlocks at login'
GREETER_KEY_LINE='enable-fingerprint-authentication=false'
GREETER_KEY_RE='^[[:space:]]*enable-fingerprint-authentication[[:space:]]*='
SECTION_HEADER_RE='^[[:space:]]*\['
COMMENT_RE='^[[:space:]]*#'
FPRINTD_MODULE_RE='(^|[[:space:]/])pam_fprintd(\.so)?([[:space:]]|$)'
# The only services that may run pam_fprintd, each where it cannot delay a
# password: GDM runs gdm-fingerprint beside gdm-password, and this stanza runs
# it after a password has already failed.
FPRINTD_ALLOWED_SERVICES=(gdm-fingerprint "$STANZA_NAME")
REQUIRED_PAM_MODULES=(pam_fprintd.so pam_exec.so)
# The auth modules the chain after the stanza's include may run. The stanza's
# `sufficient pam_unix` ends that chain on a correct password, so each must be
# one a correct password may skip: the password checks themselves, the stack's
# own deny/permit, and pam_cap (it grants capabilities, it does not
# authenticate). pam_sss is known because the gate skips non-local accounts.
# pam_fprintd is the other guard's to report, not this one's.
SKIPPABLE_AUTH_MODULES=(pam_unix.so pam_sss.so pam_deny.so pam_permit.so pam_cap.so pam_fprintd.so)
SKIP_EXPLANATION="a correct password at the stanza ends the auth chain, so no auth rule after its include runs; modules known to be safe to skip: ${SKIPPABLE_AUTH_MODULES[*]}"
# One PAM rule as pam.conf(5) lays it out: a type (a leading '-' only silences
# a module that cannot load), a control keyword or [...] field, then a module
# path, or for include/substack a file name. libpam reads the type and the
# control keyword case-insensitively (measured: `AUTH` and `INCLUDE` both run).
PAM_RULE_RE='^[[:space:]]*(-?[[:alpha:]]+)[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+([^[:space:]]+)'
AT_LINE_RE='^[[:space:]]*@'
# `@include NAME`, the directive read case-insensitively (measured: `@INCLUDE`
# runs, while `@foo` fails the stack).
AT_DIRECTIVE_RE='^[[:space:]]*@([[:alpha:]]*)([[:space:]]+([^[:space:]]+))?[[:space:]]*$'
# libpam joins a line ending in a backslash onto the next (measured).
CONTINUED_LINE_RE='\\$'
# Rules of these types are not auth rules, and an include from one brings in
# only rules of its own type (measured: an `account include` of a file whose
# auth rule denies leaves authentication alone).
NON_AUTH_RULE_TYPES=(account session password)
PAM_INCLUDE_CONTROLS=(include substack)
# How deep includes may nest below a service file. Measured on Linux-PAM 1.7.0
# with scripts/pam-stack-probe.py: 15 levels of @include or substack load, and
# a 16th aborts the stack (start:26) or fails it (6).
MAX_INCLUDE_DEPTH=15
BLANK_RE='^[[:space:]]*$'
PROBE="${REPO_ROOT}/scripts/pam-stack-probe.py"
PAM_SUCCESS=0

# What the stanza may hold, read statically (pam.conf(5)). Only plain `auth`
# rules; a control is one of the four keywords or a [...] field of
# <return code>=<action> pairs, where an action is one of these names or a jump
# count.
STANZA_RULE_RE='^[[:space:]]*auth[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+([^[:space:]]+)'
CONTROL_PAIR_RE='^([a-z_]+)=([a-z]+|[0-9]+)$'
JUMP_COUNT_RE='^[0-9]+$'
PAM_CONTROL_KEYWORDS=(required requisite sufficient optional)
PAM_CONTROL_ACTIONS=(ignore bad die ok "done" reset)
PAM_RETURN_CODE_NAMES=(success open_err symbol_err service_err system_err buf_err perm_denied auth_err
  cred_insufficient authinfo_unavail user_unknown maxtries new_authtok_reqd acct_expired session_err
  cred_unavail cred_expired cred_err no_module_data conv_err authtok_err authtok_recover_err
  authtok_lock_busy authtok_disable_aging try_again ignore abort authtok_expired module_unknown bad_item
  conv_again incomplete default)
READER_MODULE="pam_fprintd.so"

# Owner and mode of an installed copy. Under the test seam nothing can be
# chowned to root, so the copies belong to whoever runs the suite.
OWNER="root:root"
[[ -n "$PREFIX" ]] && OWNER="$(id -un):$(id -gn)"
STANZA_STAT="${OWNER} 644"
GATE_STAT="${OWNER} 755"

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; BLUE=''; RED=''; RESET=''
fi
log() {
  local level="$1"; shift; local msg="$*"
  case "$level" in
    INFO)    echo -e "${BLUE}▶${RESET} $msg" ;;
    SUCCESS) echo -e "${GREEN}✓${RESET} $msg" ;;
    WARNING) echo -e "${YELLOW}⚠${RESET} $msg" >&2 ;;
    ERROR)   echo -e "${RED}✗${RESET} $msg" >&2 ;;
  esac
}
# log_each <level> <lines> — one log line per non-empty input line.
log_each() {
  local level="$1" line
  while IFS= read -r line; do
    [[ -n "$line" ]] && log "$level" "$line"
  done <<<"$2"
  return 0
}

for f in "$STANZA_SRC" "$GATE_SRC"; do
  [[ -r "$f" ]] || { log ERROR "missing $f"; exit 1; }
done

if [[ -n "$PREFIX" ]]; then
  log WARNING "SUDO_FPRINT_GATE_PREFIX=$PREFIX — working under a prefix, NOT on the real /etc"
fi

WORK="$(mktemp -d)" || { log ERROR "mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
# The wrong-password probes' stand-ins: a gate that offers, one that skips, one
# that is not there, and a reader that records being reached, then fails or
# (the matching finger) succeeds.
GATE_OFFER_STAND_IN="$WORK/gate-offers"
GATE_SKIP_STAND_IN="$WORK/gate-skips"
GATE_MISSING_STAND_IN="$WORK/no-such-gate"
READER_NO_MATCH_STAND_IN="$WORK/reader-no-match"
READER_MATCH_STAND_IN="$WORK/reader-match"
READER_REACHED_MARKER="$WORK/reader-reached"

# ---------------------------------------------------------------------------
# Rendering: what each edited file should say, computed from what it says now.
# Pure bash line loops, so a file's other bytes (trailing spaces included)
# survive untouched and nothing depends on which awk or grep is installed.
# ---------------------------------------------------------------------------

# count_matching_lines <file> <ERE> — how many lines match.
count_matching_lines() {
  local file="$1" pattern="$2" line count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $pattern ]]; then count=$((count + 1)); fi
  done <"$file"
  printf '%s\n' "$count"
}

# render_sudo_service <file> <with|without> — the file with every include of
# the stanza removed, and with one put back immediately before the single
# common-auth include.
render_sudo_service() {
  local file="$1" want="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $INCLUDE_RE ]]; then continue; fi
    if [[ "$want" == with && "$line" =~ $COMMON_AUTH_RE ]]; then
      printf '%s\n' "$INCLUDE_LINE"
    fi
    printf '%s\n' "$line"
  done <"$file"
  return 0
}

# render_greeter <file> <with|without> — the file with this tool's marker (and
# the key line right after it) removed, and with both put back immediately
# after the login-screen section header.
render_greeter() {
  local file="$1" want="$2" line is_after_marker=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( is_after_marker )); then
      is_after_marker=0
      if [[ "$line" == "$GREETER_KEY_LINE" ]]; then continue; fi
    fi
    if [[ "$line" == "$GREETER_MARKER" ]]; then is_after_marker=1; continue; fi
    printf '%s\n' "$line"
    if [[ "$want" == with && "$line" == "$GREETER_SECTION" ]]; then
      printf '%s\n%s\n' "$GREETER_MARKER" "$GREETER_KEY_LINE"
    fi
  done <"$file"
  return 0
}

# has_greeter_marker — does the greeter file carry this tool's marker line?
has_greeter_marker() {
  local line
  [[ -r "$GREETER_CONFIG" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$GREETER_MARKER" ]]; then return 0; fi
  done <"$GREETER_CONFIG"
  return 1
}

# foreign_greeter_settings <file> — every line in the login-screen section that
# sets the key, other than this tool's own: printed, one per line.
foreign_greeter_settings() {
  local line is_in_section=0
  while IFS= read -r line; do
    if [[ "$line" =~ $SECTION_HEADER_RE ]]; then
      is_in_section=0
      if [[ "$line" == "$GREETER_SECTION" ]]; then is_in_section=1; fi
      continue
    fi
    if (( is_in_section )) && [[ "$line" =~ $GREETER_KEY_RE ]]; then printf '%s\n' "$line"; fi
  done < <(render_greeter "$1" without)
  return 0
}

# is_listed <word> <list...> — is the word one of the list's?
is_listed() {
  local word="$1" listed; shift
  for listed in "$@"; do
    if [[ "$word" == "$listed" ]]; then return 0; fi
  done
  return 1
}

# fprintd_in_front_of_a_password — every EFFECTIVE PAM service file that runs
# pam_fprintd where it could delay a password, printed "<file> puts ...: <line>".
# A file in /etc/pam.d shadows the vendor file of the same name (pam.d(5)), so
# a vendor file with an /etc twin is not read. A file that cannot be read cannot
# be cleared, so it is reported too.
fprintd_in_front_of_a_password() {
  local file name line
  local -A is_seen=()
  for file in "$PAM_ETC_DIR"/* "$PAM_VENDOR_DIR"/*; do
    [[ -f "$file" ]] || continue
    name="${file##*/}"
    if [[ -n "${is_seen[$name]:-}" ]]; then continue; fi
    is_seen[$name]=1
    if is_listed "$name" "${FPRINTD_ALLOWED_SERVICES[@]}"; then continue; fi
    if [[ ! -r "$file" ]]; then
      printf '%s cannot be read, so it cannot be cleared of pam_fprintd\n' "$file"
      continue
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ $COMMENT_RE ]]; then continue; fi
      if [[ "$line" =~ $FPRINTD_MODULE_RE ]]; then
        printf '%s puts pam_fprintd where it would delay a password: %s\n' "$file" "$line"
      fi
    done <"$file"
  done
  return 0
}

# is_pam_module_installed <name.so> — in any of the directories libpam loads from.
is_pam_module_installed() {
  local dir
  for dir in "${PREFIX}"/usr/lib/*/security "${PREFIX}"/lib/*/security \
             "${PREFIX}/usr/lib/security" "${PREFIX}/lib/security"; do
    if [[ -f "$dir/$1" ]]; then return 0; fi
  done
  return 1
}

# is_greeter_compiled_stale — gdm has not recompiled since the file changed.
is_greeter_compiled_stale() {
  [[ ! -e "$GREETER_COMPILED" || "$GREETER_COMPILED" -ot "$GREETER_CONFIG" ]]
}

# does_end_in_newline <file> — every edit rewrites whole lines, so a file whose
# last line is unterminated could not be restored byte for byte.
does_end_in_newline() {
  [[ -z "$(tail -c1 "$1")" ]]
}

# ---------------------------------------------------------------------------
# The auth chain a correct password at the stanza skips, read statically.
# ---------------------------------------------------------------------------

# pam_config_path <name> — the file libpam opens for an include of <name>
# (pam.d(5)): an absolute name as it stands, else /etc/pam.d/<name>, else the
# vendor file of that name. Prints nothing when there is none.
pam_config_path() {
  local name="$1" candidate
  if [[ "$name" == /* ]]; then
    candidate="${PREFIX}${name}"
    if [[ -e "$candidate" ]]; then printf '%s\n' "$candidate"; fi
    return 0
  fi
  for candidate in "${PAM_ETC_DIR}/${name}" "${PAM_VENDOR_DIR}/${name}"; do
    if [[ -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 0
}

# included_file_problems <chain> <name> <depth> <files being read...> — the
# problems in the whole file an include names, which sits <depth> levels below
# the service. Fails closed: a name libpam cannot open, a file this check cannot
# read, a loop and nesting deeper than libpam loads are each a problem, since
# what such a chain runs cannot be known.
included_file_problems() {
  local chain="$1" name="$2" depth="$3"; shift 3
  local path line included_chain
  if [[ -z "$name" ]]; then
    printf '%s has an include that names no file\n' "$chain"
    return 0
  fi
  included_chain="${chain} → ${name}"
  if (( depth > MAX_INCLUDE_DEPTH )); then
    printf '%s nests includes deeper than libpam loads (%s levels)\n' "$included_chain" "$MAX_INCLUDE_DEPTH"
    return 0
  fi
  path="$(pam_config_path "$name")"
  if [[ -z "$path" ]]; then
    printf '%s: no such file in %s or %s, so libpam cannot load this chain\n' \
      "$included_chain" "$PAM_ETC_DIR" "$PAM_VENDOR_DIR"
    return 0
  fi
  if [[ ! -f "$path" || ! -r "$path" ]]; then
    printf '%s: %s cannot be read, so what it runs cannot be known\n' "$included_chain" "$path"
    return 0
  fi
  if is_listed "$path" "$@"; then
    printf '%s loops back into a file it is already reading, which libpam cannot load\n' "$included_chain"
    return 0
  fi
  # The loop reads $path and hands its name on as one of the files being read,
  # for the loop guard; nothing writes it.
  # shellcheck disable=SC2094
  while IFS= read -r line || [[ -n "$line" ]]; do
    chain_line_problems "$included_chain" "$line" "$((depth + 1))" "$@" "$path"
  done <"$path"
  return 0
}

# chain_line_problems <chain> <line> <depth> <files being read...> — the
# problems in one line of the chain a correct password at the stanza skips: an
# auth rule (`-auth` too) whose module is outside the known set, and each
# include it brings in that cannot be followed. An include it makes sits
# <depth> levels below the service. The stanza's own include is the other
# checks' to judge, and a line libpam would read differently is refused.
chain_line_problems() {
  local chain="$1" line="$2" depth="$3"; shift 3
  local rule_type control module
  if [[ "$line" =~ $BLANK_RE ]]; then return 0; fi
  if [[ "$line" =~ $CONTINUED_LINE_RE ]]; then
    printf '%s continues a line onto the next (a trailing backslash), which this check does not follow: %s\n' "$chain" "$line"
    return 0
  fi
  if [[ "$line" =~ $COMMENT_RE || "$line" =~ $INCLUDE_RE ]]; then return 0; fi
  if [[ "$line" =~ $AT_LINE_RE ]]; then
    if [[ "$line" =~ $AT_DIRECTIVE_RE && "${BASH_REMATCH[1],,}" == include ]]; then
      included_file_problems "$chain" "${BASH_REMATCH[3]}" "$depth" "$@"
    else
      printf '%s has a directive this check cannot follow: %s\n' "$chain" "$line"
    fi
    return 0
  fi
  if [[ ! "$line" =~ $PAM_RULE_RE ]]; then
    printf '%s has a line this check cannot read as libpam would: %s\n' "$chain" "$line"
    return 0
  fi
  rule_type="${BASH_REMATCH[1],,}"
  rule_type="${rule_type#-}"
  control="${BASH_REMATCH[2],,}"
  module="${BASH_REMATCH[3]}"
  if is_listed "$rule_type" "${NON_AUTH_RULE_TYPES[@]}"; then return 0; fi
  if [[ "$rule_type" != auth ]]; then
    printf '%s has a rule of a type libpam does not know: %s\n' "$chain" "$line"
    return 0
  fi
  if is_listed "$control" "${PAM_INCLUDE_CONTROLS[@]}"; then
    included_file_problems "$chain" "$module" "$depth" "$@"
    return 0
  fi
  if is_listed "${module##*/}" "${SKIPPABLE_AUTH_MODULES[@]}"; then return 0; fi
  printf '%s has %s, which a correct password at the stanza would skip: %s\n' "$chain" "${module##*/}" "$line"
  return 0
}

# rules_after_stanza_problems <service name> <file> <service path> — the
# problems on the chain that follows <file>'s first include of the stanza.
# <service path> is where the service really lives, for the loop guard.
rules_after_stanza_problems() {
  local service_name="$1" file="$2" service_path="$3" line is_after_stanza=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( is_after_stanza )); then
      chain_line_problems "$service_name" "$line" 1 "$service_path"
    elif [[ "$line" =~ $INCLUDE_RE ]]; then
      is_after_stanza=1
    fi
  done <"$file"
  return 0
}

# auth_chain_problems <target|installed> — in each sudo service as the install
# would leave it (target) or as it is (installed), every auth rule after the
# stanza's include whose module is outside the known set, and every include on
# that chain that cannot be followed, one line each.
auth_chain_problems() {
  local mode="$1" service_name service_path chain_source rendered="$WORK/rendered-for-chain"
  while IFS= read -r service_name; do
    [[ -n "$service_name" ]] || continue
    service_path="${PAM_ETC_DIR}/${service_name}"
    chain_source="$service_path"
    if [[ "$mode" == target ]]; then
      render_sudo_service "$service_path" with >"$rendered"
      chain_source="$rendered"
    fi
    rules_after_stanza_problems "$service_name" "$chain_source" "$service_path"
  done < <(probed_services "$mode")
  return 0
}

# ---------------------------------------------------------------------------
# The stanza's control flow, read statically.
# ---------------------------------------------------------------------------

# control_field_problems <where> <rule number> <reader rule number> <control> —
# one line per pair of a [...] control field that libpam would not read as
# written, and per jump that does not land exactly one rule past the reader.
# Jumping N from rule R skips the next N rules and lands on rule R+N+1.
control_field_problems() {
  local where="$1" rule_number="$2" reader_rule_number="$3" control="$4"
  local pair return_code action landing_rule_number
  local -a pairs=()
  read -r -a pairs <<<"${control:1:${#control}-2}"
  if (( ${#pairs[@]} == 0 )); then
    printf '%s: an empty control field\n' "$where"
    return 0
  fi
  for pair in "${pairs[@]}"; do
    if [[ ! "$pair" =~ $CONTROL_PAIR_RE ]]; then
      printf '%s: "%s" is not a <return code>=<action> pair\n' "$where" "$pair"
      continue
    fi
    return_code="${BASH_REMATCH[1]}"
    action="${BASH_REMATCH[2]}"
    if ! is_listed "$return_code" "${PAM_RETURN_CODE_NAMES[@]}"; then
      printf '%s: "%s" is not a return code libpam knows (a typo makes the whole line act as "bad")\n' "$where" "$return_code"
    fi
    if [[ "$action" =~ $JUMP_COUNT_RE ]]; then
      landing_rule_number=$(( rule_number + 10#$action + 1 ))
      if (( landing_rule_number != reader_rule_number + 1 )); then
        printf '%s: %s=%s lands on rule %d, not one past %s (rule %d): a jump must skip exactly the reader\n' \
          "$where" "$return_code" "$action" "$landing_rule_number" "$READER_MODULE" "$reader_rule_number"
      fi
    elif ! is_listed "$action" "${PAM_CONTROL_ACTIONS[@]}"; then
      printf '%s: "%s" is not an action libpam knows\n' "$where" "$action"
    fi
  done
  return 0
}

# stanza_shape_problems <stanza> — one line per way the stanza's control flow
# could be wrong, read statically: a line that is not a plain auth rule, a
# control libpam would not read as written, a stanza that does not run the
# reader exactly once, and any jump that does not land exactly one rule past
# the reader. Printed "<file>:<line>: <problem>".
stanza_shape_problems() {
  local stanza="$1" line line_number=0 rule_count=0 rule_index control
  local -a rule_line_numbers=() rule_controls=() reader_rule_numbers=()
  if [[ ! -r "$stanza" ]]; then
    printf '%s cannot be read\n' "$stanza"
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    if [[ "$line" =~ $COMMENT_RE || "$line" =~ $BLANK_RE ]]; then continue; fi
    if [[ ! "$line" =~ $STANZA_RULE_RE ]]; then
      printf '%s:%d: not a plain auth rule, which is all the stanza may hold: %s\n' "$stanza" "$line_number" "$line"
      continue
    fi
    rule_count=$((rule_count + 1))
    rule_line_numbers+=("$line_number")
    rule_controls+=("${BASH_REMATCH[1]}")
    if [[ "${BASH_REMATCH[2]##*/}" == "$READER_MODULE" ]]; then reader_rule_numbers+=("$rule_count"); fi
  done <"$stanza"
  if (( ${#reader_rule_numbers[@]} != 1 )); then
    printf '%s: runs %s %d times, not once, so its jumps have no single target\n' \
      "$stanza" "$READER_MODULE" "${#reader_rule_numbers[@]}"
    return 0
  fi
  for (( rule_index = 0; rule_index < rule_count; rule_index++ )); do
    control="${rule_controls[$rule_index]}"
    if [[ "$control" == \[* ]]; then
      control_field_problems "$stanza:${rule_line_numbers[$rule_index]}" "$((rule_index + 1))" \
        "${reader_rule_numbers[0]}" "$control"
    elif ! is_listed "$control" "${PAM_CONTROL_KEYWORDS[@]}"; then
      printf '%s:%d: "%s" is not a control libpam knows\n' "$stanza" "${rule_line_numbers[$rule_index]}" "$control"
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# The stanza's control flow, through the REAL libpam.
# ---------------------------------------------------------------------------

# build_probe_confdir <target|installed> — prints a directory holding this
# machine's PAM configuration as libpam reads it (vendor files, then /etc/pam.d
# over them), with sudo, sudo-i and the stanza as the install WOULD leave them
# (target) or as they ARE (installed). Each probe then swaps the stanza's
# modules for its own stand-ins.
build_probe_confdir() {
  local mode="$1" confdir="$WORK/pamconf" file service
  rm -rf "$confdir"
  mkdir -p "$confdir"
  for file in "$PAM_VENDOR_DIR"/* "$PAM_ETC_DIR"/*; do
    if [[ -f "$file" && -r "$file" ]]; then cp "$file" "$confdir/"; fi
  done
  if [[ "$mode" == target ]]; then
    cp "$STANZA_SRC" "$confdir/$STANZA_NAME"
    for service in "${SUDO_SERVICES[@]}"; do
      render_sudo_service "$service" with >"$confdir/${service##*/}"
    done
  fi
  printf '%s\n' "$confdir"
}

# probed_services <target|installed> — the sudo services to probe, one per line:
# both for the target; for the installed state only the readable ones that
# include the stanza (one that does not is not this tool's to judge).
probed_services() {
  local mode="$1" service
  for service in "${SUDO_SERVICES[@]}"; do
    if [[ "$mode" == installed ]]; then
      [[ -r "$service" ]] || continue
      (( $(count_matching_lines "$service" "$INCLUDE_RE") > 0 )) || continue
    fi
    printf '%s\n' "${service##*/}"
  done
  return 0
}

# run_probe <confdir> <service> — the probe's "<result> <prompts>" (or
# "start:<code>"); returns 1, with the reason printed, when it could not run.
run_probe() {
  python3 -I "$PROBE" --confdir "$1" --service "$2" --tty /dev/pts/0 2>&1 </dev/null
}

# count_rules_naming <file> <text> — how many rule lines (not comments) contain
# the text, as a plain substring.
count_rules_naming() {
  local file="$1" text="$2" line count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $COMMENT_RE ]]; then continue; fi
    if [[ "$line" == *"$text"* ]]; then count=$((count + 1)); fi
  done <"$file"
  printf '%s\n' "$count"
}

# right_password_problems <target|installed> — sudo and sudo-i through the REAL
# libpam with a correct password standing in (pam_permit for pam_unix and for
# the gate, pam_deny for the reader): one line per service that does not
# authenticate.
right_password_problems() {
  local mode="$1" confdir name outcome
  confdir="$(build_probe_confdir "$mode")"
  if [[ -f "$confdir/$STANZA_NAME" ]]; then
    sed -i -e 's/pam_unix\.so/pam_permit.so/g' -e 's/pam_exec\.so/pam_permit.so/g' \
           -e 's/pam_fprintd\.so/pam_deny.so/g' "$confdir/$STANZA_NAME"
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if ! outcome="$(run_probe "$confdir" "$name")"; then
      printf '%s could not be loaded through libpam: %s\n' "$name" "$outcome"
      continue
    fi
    if [[ "${outcome%% *}" != "$PAM_SUCCESS" ]]; then
      printf '%s: libpam refuses a CORRECT password through this stack (result %s)\n' "$name" "$outcome"
    fi
  done < <(probed_services "$mode")
  return 0
}

# write_probe_stand_ins — the stand-ins the wrong-password probes run, in $WORK.
# Returns 1 when they cannot run from there (a noexec TMPDIR, say).
write_probe_stand_ins() {
  printf '#!/bin/sh\nexit 0\n' >"$GATE_OFFER_STAND_IN"
  printf '#!/bin/sh\nexit 1\n' >"$GATE_SKIP_STAND_IN"
  # The reader stand-ins take the marker's path as their first argument.
  cat >"$READER_NO_MATCH_STAND_IN" <<'STAND_IN'
#!/bin/sh
: >"$1"
exit 1
STAND_IN
  cat >"$READER_MATCH_STAND_IN" <<'STAND_IN'
#!/bin/sh
: >"$1"
exit 0
STAND_IN
  chmod 755 "$GATE_OFFER_STAND_IN" "$GATE_SKIP_STAND_IN" "$READER_NO_MATCH_STAND_IN" "$READER_MATCH_STAND_IN"
  "$GATE_OFFER_STAND_IN" 2>/dev/null
}

# render_wrong_password_stanza <stanza> <gate stand-in> <reader stand-in> — the
# stanza with its control fields untouched: pam_deny for pam_unix (a wrong
# password), the gate stand-in at the gate's path, and pam_exec running the
# reader stand-in, which records that it was reached, for pam_fprintd.
render_wrong_password_stanza() {
  local stanza="$1" gate_stand_in="$2" reader_stand_in="$3"
  sed -e 's/pam_unix\.so/pam_deny.so/g' \
      -e "s|pam_fprintd\\.so|pam_exec.so quiet ${reader_stand_in} ${READER_REACHED_MARKER}|g" \
      -e "s|${GATE_INSTALLED_PATH}|${gate_stand_in}|g" "$stanza"
}

# wrong_password_problems <target|installed> — sudo and sudo-i through the REAL
# libpam with a WRONG password, the stanza's own control fields, and stand-ins
# for the gate and the reader: one line per case that does not do what it must.
#   a gate that offers   reaches the reader, and is refused
#   a gate that skips    never reaches the reader, and is refused
#   a missing gate       never reaches the reader, and is refused
#   a matching finger    authenticates
# Every credential check in common-auth is pam_deny too, so "refused" is the
# stanza's own doing and not an accident of this machine's accounts.
wrong_password_problems() {
  local mode="$1" confdir stanza_under_probe name case_name gate_stand_in reader_stand_in expectation
  local outcome result is_reader_reached
  confdir="$(build_probe_confdir "$mode")"
  [[ -f "$confdir/$STANZA_NAME" ]] || return 0
  if (( $(count_rules_naming "$confdir/$STANZA_NAME" "$GATE_INSTALLED_PATH") != 1 )); then
    printf '%s does not name the gate at %s exactly once\n' "$STANZA_NAME" "$GATE_INSTALLED_PATH"
    return 0
  fi
  if ! write_probe_stand_ins; then
    printf 'the probe stand-ins cannot run from %s (mounted noexec?): set TMPDIR to a directory that allows exec\n' "$WORK"
    return 0
  fi
  stanza_under_probe="$WORK/stanza-under-probe"
  cp "$confdir/$STANZA_NAME" "$stanza_under_probe"
  if [[ -f "$confdir/common-auth" ]]; then
    sed -i -e 's/pam_unix\.so/pam_deny.so/g' -e 's/pam_sss\.so/pam_deny.so/g' "$confdir/common-auth"
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    while IFS='|' read -r case_name gate_stand_in reader_stand_in expectation; do
      render_wrong_password_stanza "$stanza_under_probe" "$gate_stand_in" "$reader_stand_in" \
        >"$confdir/$STANZA_NAME"
      rm -f "$READER_REACHED_MARKER"
      if ! outcome="$(run_probe "$confdir" "$name")"; then
        printf '%s could not be loaded through libpam: %s\n' "$name" "$outcome"
        continue
      fi
      result="${outcome%% *}"
      is_reader_reached=0
      [[ -e "$READER_REACHED_MARKER" ]] && is_reader_reached=1
      case "$expectation" in
        offered)
          if (( ! is_reader_reached )); then
            printf '%s: a wrong password and %s never reached the reader (the fingerprint would never be asked)\n' "$name" "$case_name"
          fi
          if [[ "$result" == "$PAM_SUCCESS" ]]; then
            printf '%s: a wrong password and %s AUTHENTICATED with no credential\n' "$name" "$case_name"
          fi ;;
        not-offered)
          if (( is_reader_reached )); then
            printf '%s: a wrong password and %s still reached the reader (a fingerprint offered where it must not be)\n' "$name" "$case_name"
          fi
          if [[ "$result" == "$PAM_SUCCESS" ]]; then
            printf '%s: a wrong password and %s AUTHENTICATED with no credential\n' "$name" "$case_name"
          fi ;;
        authenticated)
          if [[ "$result" != "$PAM_SUCCESS" ]]; then
            printf '%s: a wrong password and %s did not authenticate (result %s)\n' "$name" "$case_name" "$outcome"
          fi ;;
      esac
    done <<PROBE_CASES
a gate that offers|$GATE_OFFER_STAND_IN|$READER_NO_MATCH_STAND_IN|offered
a gate that skips|$GATE_SKIP_STAND_IN|$READER_NO_MATCH_STAND_IN|not-offered
a missing gate|$GATE_MISSING_STAND_IN|$READER_NO_MATCH_STAND_IN|not-offered
a matching finger|$GATE_OFFER_STAND_IN|$READER_MATCH_STAND_IN|authenticated
PROBE_CASES
  done < <(probed_services "$mode")
  return 0
}

# stanza_flow_problems <target|installed> <stanza> — every static and libpam
# problem with the stanza's control flow, one per line.
stanza_flow_problems() {
  stanza_shape_problems "$2"
  right_password_problems "$1"
  wrong_password_problems "$1"
}

# ---------------------------------------------------------------------------
# The worktree guard.
# ---------------------------------------------------------------------------

# is_linked_worktree <dir> — is <dir> a linked git worktree (its git dir is not
# the common one)? Not a git checkout at all is a no.
is_linked_worktree() {
  local git_dir common_dir
  git_dir="$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
  common_dir="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$git_dir" && -n "$common_dir" && "$git_dir" != "$common_dir" ]]
}

# linked_worktree_holding_checkout — prints the linked worktree this checkout
# is, or sits in as a submodule at any depth; nothing when there is none. A
# submodule inside a linked worktree has a git dir equal to its common dir, so
# only its superproject can say.
linked_worktree_holding_checkout() {
  local checkout="$REPO_ROOT" superproject depth
  for (( depth = 0; depth < MAX_SUPERPROJECT_DEPTH; depth++ )); do
    if is_linked_worktree "$checkout"; then
      printf '%s\n' "$checkout"
      return 0
    fi
    superproject="$(git -C "$checkout" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
    [[ -n "$superproject" ]] || return 0
    checkout="$superproject"
  done
  return 0
}

# ---------------------------------------------------------------------------
# --check: the INSTALLED STATE, not the install's exit status.
# ---------------------------------------------------------------------------

# check_copy <src> <dst> <want-stat> — a regular file (a symlink back into this
# checkout would hand root a file you can write), byte-identical, owned and
# moded as wanted.
check_copy() {
  local src="$1" dst="$2" want="$3" st
  if [[ -L "$dst" ]]; then
    log ERROR "$dst is a SYMLINK — root would read a file you can write; re-run: ./sudo-fprint-gate.sh"
    return 1
  elif [[ ! -e "$dst" ]]; then
    log ERROR "$dst is not installed — run: ./sudo-fprint-gate.sh"
    return 1
  elif ! cmp -s "$src" "$dst"; then
    log ERROR "$dst DIFFERS from $src — re-run: ./sudo-fprint-gate.sh"
    return 1
  fi
  st="$(stat -c '%U:%G %a' "$dst")"
  if [[ "$st" != "$want" ]]; then
    log ERROR "$dst is ${st}, not ${want} — re-run: ./sudo-fprint-gate.sh"
    return 1
  fi
  log SUCCESS "$dst matches this checkout (${st})"
}

# check_sudo_service <file> — returns 1 on drift, 2 when sudo is BROKEN (it
# includes a stanza that is not there, so libpam aborts every sudo).
check_sudo_service() {
  local file="$1" rendered="$WORK/rendered-sudo"
  if [[ ! -r "$file" ]]; then
    log ERROR "$file cannot be read"
    return 1
  fi
  if (( $(count_matching_lines "$file" "$INCLUDE_RE") > 0 )) && [[ ! -e "$STANZA_DST" ]]; then
    log ERROR "$file includes $STANZA_NAME but $STANZA_DST is MISSING — sudo is BROKEN"
    return 2
  fi
  if (( $(count_matching_lines "$file" "$COMMON_AUTH_RE") != 1 )); then
    log ERROR "$file has no single '@include common-auth' line"
    return 1
  fi
  render_sudo_service "$file" with >"$rendered"
  if ! cmp -s "$rendered" "$file"; then
    log ERROR "$file does not include $STANZA_NAME exactly once, immediately before @include common-auth — re-run: ./sudo-fprint-gate.sh"
    return 1
  fi
  log SUCCESS "$file asks for the password first, then a gated fingerprint"
}

# check_greeter — this tool's greeter lines, when they are there, are intact and
# compiled; when they are not, the greeter is not this tool's.
check_greeter() {
  local rendered="$WORK/rendered-greeter" foreign
  if ! has_greeter_marker; then
    log SUCCESS "the greeter keeps GDM's own fingerprint setting (--greeter-password-only was not used)"
    return 0
  fi
  foreign="$(foreign_greeter_settings "$GREETER_CONFIG")"
  if [[ -n "$foreign" ]]; then
    log ERROR "$GREETER_CONFIG also sets enable-fingerprint-authentication outside this tool's line: $foreign"
    return 1
  fi
  render_greeter "$GREETER_CONFIG" with >"$rendered"
  if ! cmp -s "$rendered" "$GREETER_CONFIG"; then
    log ERROR "$GREETER_CONFIG does not turn the greeter fingerprint off (this tool's two lines, right after $GREETER_SECTION) — re-run: ./sudo-fprint-gate.sh --greeter-password-only"
    return 1
  fi
  if is_greeter_compiled_stale; then
    log ERROR "gdm has not recompiled its greeter config since $GREETER_CONFIG changed"
    log ERROR "  sudo systemctl reload $GDM_UNIT   (it only recompiles; never restart gdm, that ends the session)"
    return 1
  fi
  log SUCCESS "the greeter is password-only, and gdm has compiled it"
}

check_no_fprintd_in_front() {
  local violations
  violations="$(fprintd_in_front_of_a_password)"
  if [[ -n "$violations" ]]; then
    log_each ERROR "$violations"
    log ERROR "  the stock profile does this to common-auth: sudo pam-auth-update --disable fprintd"
    return 1
  fi
  log SUCCESS "no PAM stack puts pam_fprintd in front of a password (gdm-fingerprint runs beside one)"
}

# check_stanza_shape — the installed stanza, read statically.
check_stanza_shape() {
  local problems
  [[ -e "$STANZA_DST" ]] || return 0   # check_copy has already said it is missing
  problems="$(stanza_shape_problems "$STANZA_DST")"
  if [[ -n "$problems" ]]; then
    log_each ERROR "$problems"
    return 1
  fi
  log SUCCESS "every control field in the installed stanza is libpam's, and its jump skips exactly the reader"
}

check_sudo_stack_loads() {
  local problems
  problems="$(right_password_problems installed)"
  if [[ -n "$problems" ]]; then
    log_each ERROR "$problems"
    return 1
  fi
  log SUCCESS "the installed sudo stack loads through the real libpam and accepts a correct password"
}

check_wrong_password_flow() {
  local problems
  problems="$(wrong_password_problems installed)"
  if [[ -n "$problems" ]]; then
    log_each ERROR "$problems"
    return 1
  fi
  log SUCCESS "with a wrong password, the installed stack reaches the reader only when the gate offers, and never authenticates"
}

check_skipped_chain_known() {
  local problems
  problems="$(auth_chain_problems installed)"
  if [[ -n "$problems" ]]; then
    log_each ERROR "$problems"
    log ERROR "  ${SKIP_EXPLANATION}"
    log ERROR "  remove sudo-fprint-gate (--remove) or that rule; docs/guide.md says why"
    return 1
  fi
  log SUCCESS "the auth chain after the stanza runs nothing a password checked first would skip"
}

check_pam_modules() {
  local module bad=0
  for module in "${REQUIRED_PAM_MODULES[@]}"; do
    if ! is_pam_module_installed "$module"; then
      log ERROR "$module is not installed (apt install libpam-fprintd libpam-modules)"
      bad=1
    fi
  done
  (( bad == 0 )) && log SUCCESS "pam_fprintd.so and pam_exec.so are installed"
  return "$bad"
}

check_installed() {
  local bad=0 is_sudo_broken=0 is_flow_wrong=0 service rc
  check_copy "$GATE_SRC" "$GATE_DST" "$GATE_STAT" || bad=1
  check_copy "$STANZA_SRC" "$STANZA_DST" "$STANZA_STAT" || bad=1
  for service in "${SUDO_SERVICES[@]}"; do
    rc=0
    check_sudo_service "$service" || rc=$?
    (( rc == 0 )) || bad=1
    (( rc == 2 )) && is_sudo_broken=1
  done
  check_stanza_shape || { bad=1; is_flow_wrong=1; }
  # A stack libpam refuses is as broken as a missing stanza: either way sudo
  # refuses everyone, and the repair goes through the untouched polkit, ONCE.
  if ! check_sudo_stack_loads; then
    bad=1
    is_sudo_broken=1
  fi
  check_wrong_password_flow || { bad=1; is_flow_wrong=1; }
  if (( is_sudo_broken )); then
    log ERROR "  sudo refuses everyone until this is fixed; repair it from a GNOME dialog (polkit is untouched):"
    log ERROR "    pkexec sed -i '/^@include ${STANZA_NAME}\$/d' ${SUDO_SERVICES[*]}"
  fi
  if (( is_flow_wrong )); then
    log ERROR "  the installed stanza's control flow is wrong; take it out of sudo now (polkit is untouched):"
    log ERROR "    pkexec sed -i '/^@include ${STANZA_NAME}\$/d' ${SUDO_SERVICES[*]}"
  fi
  check_skipped_chain_known || bad=1
  check_greeter || bad=1
  check_no_fprintd_in_front || bad=1
  check_pam_modules || bad=1
  return "$bad"
}

if [[ "$MODE" == check ]]; then
  check_installed   # a plain call: under set -e a failed check exits 1 right here
  exit 0
fi

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

# install_by_rename <mode> <src> <dst> — root-owned <dst>, never half-written.
# Exits on failure rather than returning: it is reached through `||` lists,
# where bash suspends set -e for the whole function body, and a failed write
# must never read as "nothing to do".
install_by_rename() {
  local mode="$1" src="$2" dst="$3"
  if ! sudo install -m "$mode" -o root -g root "$src" "${dst}${TMP_SUFFIX}"; then
    log ERROR "could not write ${dst}${TMP_SUFFIX} — $dst is unchanged"
    exit 1
  fi
  if ! sudo mv -f "${dst}${TMP_SUFFIX}" "$dst"; then
    log ERROR "could not rename ${dst}${TMP_SUFFIX} over $dst — $dst is unchanged"
    exit 1
  fi
}

# replace_if_changed <rendered> <dst> — install <rendered> over <dst> unless they
# already match. Returns 0 when it wrote, 1 when there was nothing to do.
replace_if_changed() {
  local rendered="$1" dst="$2"
  if cmp -s "$rendered" "$dst"; then return 1; fi
  install_by_rename 644 "$rendered" "$dst"
  log SUCCESS "edited $dst"
}

# reload_gdm — recompile the greeter config. RELOAD, never restart: gdm's
# ExecReload is only generate-config, and a restart ends every session.
reload_gdm() {
  if sudo systemctl reload "$GDM_UNIT"; then
    log SUCCESS "gdm recompiled its greeter config"
  else
    log WARNING "could not reload $GDM_UNIT; the greeter changes at the next boot (gdm recompiles when it starts)"
  fi
}

if [[ "$MODE" == remove ]]; then
  is_greeter_changed=0
  # Includes FIRST: a sudo file that includes a stanza that is gone aborts.
  for service in "${SUDO_SERVICES[@]}"; do
    [[ -f "$service" ]] || continue
    render_sudo_service "$service" without >"$WORK/rendered"
    replace_if_changed "$WORK/rendered" "$service" || true
  done
  if [[ -f "$GREETER_CONFIG" ]]; then
    render_greeter "$GREETER_CONFIG" without >"$WORK/rendered"
    if replace_if_changed "$WORK/rendered" "$GREETER_CONFIG"; then is_greeter_changed=1; fi
  fi
  for dst in "$STANZA_DST" "$GATE_DST"; do
    if [[ -e "$dst" || -L "$dst" ]]; then
      sudo rm -f "$dst"
      log SUCCESS "removed $dst"
    fi
  done
  (( is_greeter_changed )) && reload_gdm
  log SUCCESS "sudo-fprint-gate is removed; sudo asks for the password only"
  exit 0
fi

# REFUSE to install out of a linked worktree, or a submodule inside one: root
# would read a copy taken from a branch nobody may have reviewed, and --check
# from the primary checkout would then report it as drift.
linked_worktree="$(linked_worktree_holding_checkout)"
if [[ -n "$linked_worktree" ]]; then
  # With the override set, the refusal is not printed: a wall of red ✗ lines
  # above a successful install reads as a failure.
  if [[ "${SUDO_FPRINT_GATE_ALLOW_WORKTREE:-0}" == "1" ]]; then
    log WARNING "installing from inside a linked WORKTREE ($linked_worktree), as SUDO_FPRINT_GATE_ALLOW_WORKTREE=1 asks"
  else
    log ERROR "refusing to install from inside a linked WORKTREE: $linked_worktree"
    log ERROR "  Run it from the primary checkout (for a submodule, the superproject's primary checkout)."
    log ERROR "  (set SUDO_FPRINT_GATE_ALLOW_WORKTREE=1 to override, e.g. to test a branch.)"
    exit 1
  fi
fi

# EVERY PRECONDITION BEFORE THE FIRST WRITE. A refusal leaves the machine as it
# was; there is no half-installed state to reason about.
log INFO "Checking what the install will meet"
for module in "${REQUIRED_PAM_MODULES[@]}"; do
  if ! is_pam_module_installed "$module"; then
    log ERROR "$module is not installed (apt install libpam-fprintd libpam-modules) — nothing installed"
    exit 2
  fi
done
if ! command -v python3 >/dev/null || [[ ! -r "$PROBE" ]]; then
  log ERROR "python3 and $PROBE are needed to run the stack through libpam before installing it — nothing installed"
  exit 2
fi
for service in "${SUDO_SERVICES[@]}"; do
  if [[ ! -r "$service" ]]; then
    log ERROR "$service is missing or unreadable — nothing installed"
    exit 2
  fi
  if ! does_end_in_newline "$service"; then
    log ERROR "$service does not end in a newline, so --remove could not restore it byte for byte — nothing installed"
    exit 2
  fi
  if (( $(count_matching_lines "$service" "$COMMON_AUTH_RE") != 1 )); then
    log ERROR "$service has no single '@include common-auth' line to put the fingerprint before — nothing installed"
    exit 2
  fi
done
# The greeter is this tool's only with --greeter-password-only; without it the
# file is read only to take out lines an earlier install left.
is_greeter_marked=0
has_greeter_marker && is_greeter_marked=1
if (( IS_GREETER_PASSWORD_ONLY || is_greeter_marked )); then
  if [[ ! -r "$GREETER_CONFIG" ]]; then
    log ERROR "$GREETER_CONFIG is missing or unreadable (is gdm3 installed?) — nothing installed"
    exit 2
  fi
  if ! does_end_in_newline "$GREETER_CONFIG"; then
    log ERROR "$GREETER_CONFIG does not end in a newline, so --remove could not restore it byte for byte — nothing installed"
    exit 2
  fi
fi
if (( IS_GREETER_PASSWORD_ONLY )); then
  if (( $(count_matching_lines "$GREETER_CONFIG" "$GREETER_SECTION_RE") != 1 )); then
    log ERROR "$GREETER_CONFIG has no single $GREETER_SECTION section — nothing installed"
    exit 2
  fi
  foreign="$(foreign_greeter_settings "$GREETER_CONFIG")"
  if [[ -n "$foreign" ]]; then
    log ERROR "$GREETER_CONFIG also sets enable-fingerprint-authentication outside this tool's line: $foreign"
    log ERROR "  remove that line first — nothing installed"
    exit 1
  fi
fi
violations="$(fprintd_in_front_of_a_password)"
if [[ -n "$violations" ]]; then
  log_each ERROR "$violations"
  log ERROR "  that already delays a password; the stock profile is removed with:"
  log ERROR "    sudo pam-auth-update --disable fprintd"
  log ERROR "  — nothing installed"
  exit 1
fi
chain_problems="$(auth_chain_problems target)"
if [[ -n "$chain_problems" ]]; then
  log_each ERROR "$chain_problems"
  log ERROR "  ${SKIP_EXPLANATION}"
  log ERROR "  — nothing installed"
  exit 1
fi
stanza_problems="$(stanza_flow_problems target "$STANZA_SRC")"
if [[ -n "$stanza_problems" ]]; then
  log_each ERROR "$stanza_problems"
  log ERROR "  that is the stanza this install would put in front of common-auth — nothing installed"
  exit 1
fi

log INFO "Installing"
# The stanza before the includes: an include whose target is missing breaks sudo
# outright. The gate's place in the order does not matter (missing = skip).
[[ -d "$GATE_DIR" ]] || sudo install -d -m 755 -o root -g root "$GATE_DIR"
install_by_rename 755 "$GATE_SRC" "$GATE_DST"
log SUCCESS "installed $GATE_DST"
install_by_rename 644 "$STANZA_SRC" "$STANZA_DST"
log SUCCESS "installed $STANZA_DST"
for service in "${SUDO_SERVICES[@]}"; do
  render_sudo_service "$service" with >"$WORK/rendered"
  replace_if_changed "$WORK/rendered" "$service" || log SUCCESS "$service already includes $STANZA_NAME"
done
is_greeter_changed=0
if (( IS_GREETER_PASSWORD_ONLY )); then
  render_greeter "$GREETER_CONFIG" with >"$WORK/rendered"
  if replace_if_changed "$WORK/rendered" "$GREETER_CONFIG"; then
    is_greeter_changed=1
  else
    log SUCCESS "$GREETER_CONFIG already turns the greeter fingerprint off"
  fi
  if (( is_greeter_changed )) || is_greeter_compiled_stale; then reload_gdm; fi
elif (( is_greeter_marked )); then
  render_greeter "$GREETER_CONFIG" without >"$WORK/rendered"
  replace_if_changed "$WORK/rendered" "$GREETER_CONFIG" || true
  log SUCCESS "took this tool's greeter lines out again (no --greeter-password-only)"
  reload_gdm
fi

echo
check_installed || exit 1
echo
log SUCCESS "Done. Enrol a finger (Settings → System → Users → Fingerprint Login, or"
log SUCCESS "  fprintd-enroll), then: sudo -k; sudo true — press Enter at the password"
log SUCCESS "  prompt to switch to the reader. Each decision is in: journalctl -t ${JOURNAL_TAG}"
