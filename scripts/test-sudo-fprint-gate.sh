#!/usr/bin/env bash
#
# scripts/test-sudo-fprint-gate.sh
# =================================
#
# State table for sudo-fprint-gate.sh and what it installs:
# pam/sudo-fingerprint (→ /etc/pam.d/), pam/fingerprint-should-offer
# (→ /usr/local/libexec/), one `@include` line in /etc/pam.d/sudo and sudo-i,
# and, with --greeter-password-only, two lines in /etc/gdm3/greeter.dconf-defaults.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# HERMETIC via a `sudo` stub at the front of PATH. It runs `install`, `mv` and
# `rm` for real, but only under an ABSOLUTE SUDO_FPRINT_GATE_PREFIX, and it
# MODELS `systemctl reload gdm.service` without running systemctl: gdm's
# ExecReload is /usr/share/gdm/generate-config, which recompiles
# /var/lib/gdm3/greeter-dconf-defaults, so the stub touches that file under the
# prefix. The machine running this has live PAM stacks; a row that reached a
# real `sudo install` into /etc/pam.d could break sudo for everyone on it.
#
# THE GATE is run the way pam_exec runs it: `env -i` plus the PAM items, so no
# PATH at all, with its lid directory and log file given as ARGUMENTS. Those
# are its only seams, because in PAM its arguments are fixed by a root-owned
# file and its environment is not the caller's to choose.
#
# THE STANZA'S CONTROL FLOW runs through the REAL libpam: pam_start_confdir()
# reads a service from any directory, unprivileged (scripts/pam-stack-probe.py,
# which the installer uses too). The files a real install wrote under the prefix
# are copied there with pam_permit/pam_deny standing in for "this password / this
# finger is right / wrong", and the installed gate still deciding. So
# `[success=ignore default=1]`, `sufficient` and @include are libpam's
# semantics, not this suite's belief about them. Two rows keep the REAL
# pam_unix, for an account that does not exist, to count prompts: one per
# attempt, because pam_unix reuses the cached password, so a second prompt is
# the caller's retry.
#
# No row needs a fingerprint reader, pam_fprintd or a real lid: the reader is
# always a stand-in and the lid a fixture directory, so the table runs in CI.
#
# The fixture /etc is Ubuntu 26.04's own text (sudo-common, polkitd, gdm3, and
# pam-auth-update's common-auth, common-account and common-session files),
# tabs and trailing spaces included, so every edit and every read is tested
# against what it will meet. Only common-password, which polkit-1 alone
# includes, is a one-line stand-in.
#
# "Could not run" is exit 2, never a pass. The suite asserts its own row total.
#
# Requires: bash, sh, git, cmp, stat, env, touch, sha256sum, python3 and a
# libpam with pam_start_confdir (Linux-PAM >= 1.4). No sudo, no root, no network.
#
# Usage: scripts/test-sudo-fprint-gate.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/.." && pwd -P)"
SETUP="$REPO_ROOT/sudo-fprint-gate.sh"
STANZA_SRC="$REPO_ROOT/pam/sudo-fingerprint"
GATE_SRC="$REPO_ROOT/pam/fingerprint-should-offer"
PROBE="$HERE/pam-stack-probe.py"
# Where the stanza says the gate lives, and so where the install must put it.
GATE_INSTALLED_PATH="/usr/local/libexec/fingerprint-should-offer"
STANZA_INSTALLED_PATH="/etc/pam.d/sudo-fingerprint"
INCLUDE_LINE="@include sudo-fingerprint"
GREETER_KEY_LINE="enable-fingerprint-authentication=false"
GREETER_FLAG="--greeter-password-only"
# The gate's exit statuses.
GATE_OFFERS=0
GATE_SKIPS=1
# libpam's return codes, as pam_authenticate and pam_start report them.
PAM_SUCCESS=0
PAM_AUTH_ERR=7
PAM_ABORT=26
# The shipped stanza's gate line, whose jump the mutation rows change.
SHIPPED_GATE_CONTROL='[success=ignore default=1]'
# What the installer says when nothing on the auth chain after the stanza
# would be skipped, and an auth rule it must refuse there.
CHAIN_CLEAN='the auth chain after the stanza runs nothing a password checked first would skip'
SKIPPED_RULE='auth required pam_faillock.so authfail'
# How deep includes may nest below a service before libpam stops loading them.
MAX_INCLUDE_DEPTH=15

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for f in "$SETUP" "$STANZA_SRC" "$GATE_SRC" "$PROBE"; do
  [[ -r "$f" ]] || fatal "cannot read $f"
done
for t in git cmp stat env touch sh sha256sum python3; do
  command -v "$t" >/dev/null || fatal "$t is required"
done

T="$(mktemp -d)" || fatal "mktemp"
trap 'rm -rf "$T"' EXIT
# git must never find a repository above the fixtures, so a row's answer cannot
# depend on where the suite happens to be checked out.
export GIT_CEILING_DIRECTORIES="$T"
STUBBIN="$T/bin"
export STUBLOG="$T/stub.log"
mkdir -p "$STUBBIN" || fatal setup
: >"$STUBLOG"
ME="$(id -un):$(id -gn)"

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
cat >"$STUBBIN/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$STUBLOG"
pfx="${SUDO_FPRINT_GATE_PREFIX:-}"
if [ -z "$pfx" ]; then
  echo "sudo stub: refused (no SUDO_FPRINT_GATE_PREFIX, so nothing may be written)" >&2
  exit 1
fi
# A RELATIVE prefix confines nothing: `relative/etc/x` is "inside" it and lands
# in whatever directory the caller is sitting in.
case "$pfx" in
  /*) ;;
  *) echo "sudo stub: REFUSED a relative prefix: $pfx" >&2; exit 97 ;;
esac
inside() { case "$1" in "$pfx"/*) return 0 ;; *) return 1 ;; esac; }
cmd="${1:-}"
shift
case "$cmd" in
  systemctl)
    # Modelled, never executed. gdm's ExecReload only recompiles the greeter
    # config; nothing else here may reach systemctl at all.
    if [ "${1:-}:${2:-}" = "reload:gdm.service" ]; then
      [ "${STUB_GDM_RELOAD_FAIL:-0}" = 1 ] && exit 1
      mkdir -p "$pfx/var/lib/gdm3" && touch "$pfx/var/lib/gdm3/greeter-dconf-defaults" || exit 98
      exit 0
    fi
    echo "sudo stub: unmodelled systemctl call: $*" >&2
    exit 99 ;;
  rm | mv)
    for a in "$@"; do
      case "$a" in
        -*) ;;
        *) inside "$a" || { echo "sudo stub: REFUSED $cmd outside the prefix: $a" >&2; exit 97; } ;;
      esac
    done
    exec "$cmd" "$@" ;;
  install) ;;
  *) echo "sudo stub: unmodelled command: $cmd $*" >&2; exit 96 ;;
esac
has_d=0; flags=(); ops=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o | -g) shift 2 ;;   # cannot work unprivileged; the RECORDED argv keeps them
    -m) flags+=("$1" "${2:-}"); shift 2 ;;
    -d) has_d=1; flags+=("$1"); shift ;;
    -*) flags+=("$1"); shift ;;
    *)  ops+=("$1"); shift ;;
  esac
done
# For `install SRC DST` only the last operand is a target; with -d all are.
if [ "$has_d" -eq 0 ] && [ "${#ops[@]}" -gt 1 ]; then
  targets=("${ops[$((${#ops[@]} - 1))]}")
else
  targets=("${ops[@]}")
fi
for t in "${targets[@]}"; do
  inside "$t" || { echo "sudo stub: REFUSED a destination outside the prefix: $t" >&2; exit 97; }
done
exec install "${flags[@]}" "${ops[@]}"
STUB

# Nothing in the setup may call systemctl except through sudo, and through
# sudo it is modelled above. A direct call is a bug: fail it loudly.
cat >"$STUBBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STUBLOG"
echo "systemctl stub: called directly, not through sudo: $*" >&2
exit 99
STUB
chmod +x "$STUBBIN"/* || fatal setup

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
# A checkout laid out like the repo, holding only what the installer reads.
mkroot() {
  mkdir -p "$1/scripts" "$1/pam" || fatal "mkroot $1"
  if ! { cp "$SETUP" "$1/" && cp "$PROBE" "$1/scripts/" && cp -p "$STANZA_SRC" "$GATE_SRC" "$1/pam/"; }; then
    fatal "mkroot $1"
  fi
}
# mutate_stanza <checkout> <sed expression> <grep needle> — edit the checkout's
# stanza, and stop the suite unless the edit applied exactly once.
mutate_stanza() {
  sed -i "$2" "$1/pam/sudo-fingerprint" || fatal "mutate $1"
  [[ "$(grep -c -F -- "$3" "$1/pam/sudo-fingerprint")" == 1 ]] || fatal "the stanza fixture in $1 did not apply"
}
ROOT="$T/root"; mkroot "$ROOT"
# A checkout whose stanza has ONE misspelled control keyword: libpam refuses the
# whole stack for it, correct password or not.
ROOT_BAD="$T/root-bad"; mkroot "$ROOT_BAD"
mutate_stanza "$ROOT_BAD" 's/^\(auth  \)sufficient\( *pam_unix\)/\1sufficent\2/' 'auth  sufficent'
# A checkout whose gate line misspells a return code: libpam still loads the
# stack and still accepts a correct password, but the line acts as "bad" for
# every result, so a gate that skips no longer jumps over the reader.
ROOT_TYPO="$T/root-typo"; mkroot "$ROOT_TYPO"
mutate_stanza "$ROOT_TYPO" 's/default=1\]/defualt=1]/' 'defualt=1]'
# A checkout with an extra rule between the gate and the reader, so the jump
# that was right lands ON the reader.
ROOT_EXTRA_RULE="$T/root-extra-rule"; mkroot "$ROOT_EXTRA_RULE"
mutate_stanza "$ROOT_EXTRA_RULE" 's/^auth  sufficient  *pam_fprintd/auth  optional  pam_echo.so an extra rule\n&/' 'pam_echo.so an extra rule'
# A checkout without the libpam probe.
ROOT_NO_PROBE="$T/root-no-probe"; mkroot "$ROOT_NO_PROBE"; rm -f "$ROOT_NO_PROBE/scripts/pam-stack-probe.py"
# The jump's mutants: every count from 1-1 to 1+4 but the shipped 1 (a negative
# count does not parse as a jump). Each lands somewhere other than one past the
# reader.
JUMP_MUTANTS=(0 2 3 4 5)
for jump in "${JUMP_MUTANTS[@]}"; do
  mkroot "$T/root-jump-$jump"
  mutate_stanza "$T/root-jump-$jump" "s/default=1\]/default=$jump]/" "default=$jump]"
done

# write_ubuntu_etc <dir> — Ubuntu 26.04's own files, as the install meets them.
write_ubuntu_etc() {
  local p="$1"
  mkdir -p "$p/etc/pam.d" "$p/usr/lib/pam.d" "$p/etc/gdm3" "$p/var/lib/gdm3" \
           "$p/usr/lib/x86_64-linux-gnu/security" || fatal "fixture $p"
  cat >"$p/etc/pam.d/sudo" <<'EOF' || fatal "fixture $p"
#%PAM-1.0

# Set up user limits from /etc/security/limits.conf.
session    required   pam_limits.so

session    required   pam_env.so readenv=1 user_readenv=0
session    required   pam_env.so readenv=1 envfile=/etc/default/locale user_readenv=0

@include common-auth
@include common-account
@include common-session-noninteractive
EOF
  cat >"$p/etc/pam.d/sudo-i" <<'EOF' || fatal "fixture $p"
#%PAM-1.0

# Set up user limits from /etc/security/limits.conf.
session    required   pam_limits.so

session    required   pam_env.so readenv=1 user_readenv=0
session    required   pam_env.so readenv=1 envfile=/etc/default/locale user_readenv=0

@include common-auth
@include common-account
@include common-session
EOF
  # Its rules exactly as pam-auth-update writes them (tabs, and a trailing space
  # after pam_cap.so); its long comment block is left out.
  printf '%s\n' '#' '# /etc/pam.d/common-auth - authentication settings common to all services' '#' \
    '# here are the per-package modules (the "Primary" block)' \
    $'auth\t[success=2 default=ignore]\tpam_unix.so nullok' \
    $'auth\t[success=1 default=ignore]\tpam_sss.so use_first_pass' \
    "# here's the fallback if no module succeeds" \
    $'auth\trequisite\t\t\tpam_deny.so' \
    "# prime the stack with a positive return value if there isn't one already;" \
    $'auth\trequired\t\t\tpam_permit.so' \
    '# and here are more per-package modules (the "Additional" block)' \
    $'auth\toptional\t\t\tpam_cap.so ' \
    '# end of pam-auth-update config' >"$p/etc/pam.d/common-auth" || fatal "fixture $p"
  cat >"$p/etc/pam.d/gdm-fingerprint" <<'EOF' || fatal "fixture $p"
#%PAM-1.0
auth    requisite       pam_nologin.so
auth    required        pam_succeed_if.so user != root quiet_success
auth    required        pam_fprintd.so
auth    optional        pam_gnome_keyring.so
@include common-account
password required       pam_fprintd.so
EOF
  cat >"$p/usr/lib/pam.d/polkit-1" <<'EOF' || fatal "fixture $p"
#%PAM-1.0

@include common-auth
@include common-account
@include common-password
session       required   pam_env.so readenv=1 user_readenv=0
@include common-session-noninteractive
EOF
  # What sudo and sudo-i include after common-auth, as pam-auth-update writes
  # them (sssd's profile enabled): the auth chain the installer reads runs
  # through them. printf, not a heredoc, for the trailing spaces.
  local -a managed_notice=(
    '# As of pam 1.0.1-6, this file is managed by pam-auth-update by default.'
    '# To take advantage of this, it is recommended that you configure any'
    '# local modules either before or after the default block, and use'
    '# pam-auth-update to manage selection of other modules.  See'
    '# pam-auth-update(8) for details.'
  )
  local -a prime_comment=(
    "# prime the stack with a positive return value if there isn't one already;"
    '# this avoids us returning an error just because nothing sets a success code'
    '# since the modules above will each just jump around'
  )
  local -a session_rules=(
    '# here are the per-package modules (the "Primary" block)'
    $'session\t[default=1]\t\t\tpam_permit.so'
    "# here's the fallback if no module succeeds"
    $'session\trequisite\t\t\tpam_deny.so'
    "${prime_comment[@]}"
    $'session\trequired\t\t\tpam_permit.so'
    '# The pam_umask module will set the umask according to the system default in'
    '# /etc/login.defs and user settings, solving the problem of different'
    '# umask settings with different shells, display managers, remote sessions etc.'
    '# See "man pam_umask".'
    $'session optional\t\t\tpam_umask.so'
    '# and here are more per-package modules (the "Additional" block)'
    $'session\trequired\tpam_unix.so '
  )
  printf '%s\n' '#' '# /etc/pam.d/common-account - authorization settings common to all services' '#' \
    '# This file is included from other service-specific PAM config files,' \
    '# and should contain a list of the authorization modules that define' \
    '# the central access policy for use on the system.  The default is to' \
    '# only deny service to users whose accounts are expired in /etc/shadow.' '#' \
    "${managed_notice[@]}" '#' '' \
    '# here are the per-package modules (the "Primary" block)' \
    $'account\t[success=1 new_authtok_reqd=done default=ignore]\tpam_unix.so ' \
    "# here's the fallback if no module succeeds" \
    $'account\trequisite\t\t\tpam_deny.so' \
    "${prime_comment[@]}" \
    $'account\trequired\t\t\tpam_permit.so' \
    '# and here are more per-package modules (the "Additional" block)' \
    $'account\tsufficient\t\t\tpam_localuser.so ' \
    $'account\t[default=bad success=ok user_unknown=ignore]\tpam_sss.so ' \
    '# end of pam-auth-update config' >"$p/etc/pam.d/common-account" || fatal "fixture $p"
  printf '%s\n' '#' '# /etc/pam.d/common-session - session-related modules common to all services' '#' \
    '# This file is included from other service-specific PAM config files,' \
    '# and should contain a list of modules that define tasks to be performed' \
    '# at the start and end of interactive sessions.' '#' \
    "${managed_notice[@]}" '' "${session_rules[@]}" \
    $'session\toptional\t\t\tpam_sss.so ' $'session\toptional\tpam_systemd.so ' \
    '# end of pam-auth-update config' >"$p/etc/pam.d/common-session" || fatal "fixture $p"
  printf '%s\n' '#' '# /etc/pam.d/common-session-noninteractive - session-related modules' \
    '# common to all non-interactive services' '#' \
    '# This file is included from other service-specific PAM config files,' \
    '# and should contain a list of modules that define tasks to be performed' \
    '# at the start and end of all non-interactive sessions.' '#' \
    "${managed_notice[@]}" '' "${session_rules[@]}" \
    '# end of pam-auth-update config' >"$p/etc/pam.d/common-session-noninteractive" || fatal "fixture $p"
  # polkit-1 alone includes this one. Never run by pam_authenticate, but libpam
  # aborts a whole stack whose include target is missing, so it must exist.
  printf 'password required pam_permit.so\n' >"$p/etc/pam.d/common-password" || fatal "fixture $p"
  # printf, not a heredoc: four of these lines END IN A SPACE in Ubuntu's file,
  # and a whitespace hook would strip them silently out of a heredoc here.
  printf '%s\n' \
    '# These are the options for the greeter session that can be set ' \
    '# through GSettings. Any GSettings setting that is used by the ' \
    '# greeter session can be set here.' \
    '' \
    '# Note that you must configure the path used by dconf to store the ' \
    '# configuration, not the GSettings path.' \
    '' \
    '' \
    '# Login manager options' \
    '# =====================' \
    '[org/gnome/login-screen]' \
    '# See /usr/share/glib-2.0/schemas/org.gnome.login-screen.gschema.xml' \
    '# - Distro logo shown below the user list or username box' \
    "#logo='/usr/share/images/vendor-logos/logo-text-version-64.png'" \
    '' \
    "# - Don't use a fingerprint reader for authentication" \
    '# enable-fingerprint-authentication=false' \
    '' \
    '# Automatic suspend' \
    '# =================' \
    '[org/gnome/settings-daemon/plugins/power]' \
    '# sleep-inactive-ac-timeout=1200' \
    >"$p/etc/gdm3/greeter.dconf-defaults" || fatal "fixture $p"
  : >"$p/usr/lib/x86_64-linux-gnu/security/pam_fprintd.so" || fatal "fixture $p"
  : >"$p/usr/lib/x86_64-linux-gnu/security/pam_exec.so" || fatal "fixture $p"
  # gdm compiled its greeter config AFTER the file last changed: fresh.
  : >"$p/var/lib/gdm3/greeter-dconf-defaults" || fatal "fixture $p"
  touch -d '2026-01-02 00:00' "$p/etc/gdm3/greeter.dconf-defaults" || fatal "fixture $p"
  touch -d '2026-01-03 00:00' "$p/var/lib/gdm3/greeter-dconf-defaults" || fatal "fixture $p"
}
PRISTINE="$T/pristine"; write_ubuntu_etc "$PRISTINE"

newprefix() { local p; p="$(mktemp -d "$T/prefix.XXXXXX")" || fatal "mktemp prefix"; write_ubuntu_etc "$p"; printf '%s' "$p"; }
logged()    { grep -c -x -F -- "$1" "$STUBLOG"; }
logged_re() { grep -c -E -- "$1" "$STUBLOG"; }
# The first STUBLOG line matching an ERE, as a line number (0 when none).
logged_at() { local n; n="$(grep -n -E -- "$1" "$STUBLOG" | head -1 | cut -d: -f1)"; printf '%s' "${n:-0}"; }
out_has()   { grep -c -F -- "$1" "$T/out"; }
stubs()     { PATH="$STUBBIN:$PATH" "$@"; }
same_as_pristine() { cmp -s "$PRISTINE/$2" "$1/$2" && echo same || echo differs; }
# One hash over every file's path and bytes (not its mtime) under a directory.
tree_hash() {
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1
}

# run_setup <checkout> <prefix> [args...] — prints the exit status; the output
# lands in $T/out and the stubs' argv in $STUBLOG (cleared first). Variables the
# caller puts in front of it reach the stubs. Runs from inside $T, so nothing a
# row does can land in the directory the suite was started from.
run_setup() {
  local root="$1" pfx="$2"; shift 2
  : >"$STUBLOG"
  ( cd "$T" && PATH="$STUBBIN:$PATH" SUDO_FPRINT_GATE_PREFIX="$pfx" \
      bash "$root/sudo-fprint-gate.sh" "$@" ) >"$T/out" 2>&1
  echo $?
}
# installed_prefix [args...] — a fresh fixture with a successful install on it.
installed_prefix() {
  local p rc
  p="$(newprefix)"
  rc="$(run_setup "$ROOT" "$p" "$@")"
  [[ "$rc" == 0 ]] || { cat "$T/out" >&2; fatal "the baseline install failed (exit $rc)"; }
  printf '%s' "$p"
}

# mklid <dir> <name> <state line> — one lid, as /proc/acpi/button/lid shows it.
mklid() { { mkdir -p "$1/$2" && printf '%s\n' "$3" >"$1/$2/state"; } || fatal "mklid $1/$2"; }
LID_OPEN="$T/lid-open";     mklid "$LID_OPEN" LID 'state:      open'
LID_CLOSED="$T/lid-closed"; mklid "$LID_CLOSED" LID 'state:      closed'
GATE_LOG="$T/gate.log"
# The gate's local accounts. fingerprint-test-nobody is local HERE and unknown to
# the real system, so the real pam_unix rows reach the gate's offer.
PASSWD_FIXTURE="$T/passwd"
printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' 'someone:x:1000:1000::/home/someone:/bin/sh' \
  'fingerprint-test-nobody:x:1001:1001::/nonexistent:/bin/sh' >"$PASSWD_FIXTURE" || fatal "passwd fixture"

# run_gate <service|UNSET> <tty|UNSET> <lid-dir> [extra args] — pam_exec's view of
# it: no environment but the PAM items. Prints the exit status (0 offer, 1 skip).
# The user is GATE_USER (UNSET for none), "someone" by default, a local account.
run_gate() {
  local service="$1" tty="$2" lid="$3" user="${GATE_USER:-someone}"; shift 3
  local items=(PAM_TYPE=auth)
  [[ "$user" != UNSET ]] && items+=("PAM_USER=$user")
  [[ "$service" != UNSET ]] && items+=("PAM_SERVICE=$service")
  [[ "$tty" != UNSET ]] && items+=("PAM_TTY=$tty")
  : >"$GATE_LOG"
  env -i "${items[@]}" "$GATE_SRC" --lid-dir "$lid" --passwd-file "$PASSWD_FIXTURE" \
    --log-file "$GATE_LOG" "$@" >/dev/null 2>&1
  echo $?
}
gate_said() { grep -c -F -- "$1" "$GATE_LOG"; }

# ---------------------------------------------------------------------------
printf '\nthe stubs (a stub that cannot fail is decoration; a stub is a claim about the real tool)\n'
check "sudo resolves to the stub" "$(stubs bash -c 'command -v sudo')" "$STUBBIN/sudo"
P="$(newprefix)"
rc="$(SUDO_FPRINT_GATE_PREFIX="$P" stubs sudo install -m 644 "$STANZA_SRC" "$T/outside" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses a destination outside the prefix" \
  "$rc:$([[ -e $T/outside ]] && echo written || echo absent)" "97:absent"
before="$(tree_hash "$P")"
rc="$(SUDO_FPRINT_GATE_PREFIX='' stubs sudo install -m 644 "$STANZA_SRC" "$P/etc/x" >/dev/null 2>&1; echo $?)"
check "with no prefix the sudo stub writes nothing" "$rc:$(tree_hash "$P")" "1:$before"
rc="$(cd "$T" && SUDO_FPRINT_GATE_PREFIX='rel' stubs sudo install -D -m 644 "$STANZA_SRC" "rel/x" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses a relative prefix, which confines nothing" \
  "$rc:$([[ -e $T/rel ]] && echo written || echo absent)" "97:absent"
rc="$(SUDO_FPRINT_GATE_PREFIX="$P" stubs sudo mv -f "$P/etc/pam.d/sudo" "$T/moved" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses an mv out of the prefix" \
  "$rc:$([[ -e $T/moved ]] && echo moved || echo absent)" "97:absent"
rc="$(SUDO_FPRINT_GATE_PREFIX="$P" stubs sudo systemctl restart gdm.service >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses any systemctl call but a gdm reload (a restart ends the session)" "$rc" 99
rc="$(SUDO_FPRINT_GATE_PREFIX="$P" stubs sudo sed -i d "$P/etc/pam.d/sudo" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses a command it does not model" "$rc:$(same_as_pristine "$P" etc/pam.d/sudo)" "96:same"

# ---------------------------------------------------------------------------
printf '\nthe gate: who is offered a fingerprint (exit 0 offer, 1 skip)\n'
check "sudo, a terminal, the lid open: offered, and logged" \
  "$(run_gate sudo /dev/pts/3 "$LID_OPEN"):$(gate_said 'offer:')" "$GATE_OFFERS:1"
check "sudo -i: offered the same way" "$(run_gate sudo-i /dev/pts/3 "$LID_OPEN")" "$GATE_OFFERS"
check "a virtual console (/dev/tty3) is a terminal: offered" "$(run_gate sudo /dev/tty3 "$LID_OPEN")" "$GATE_OFFERS"
check "sudo with no PAM_TTY at all (an agent, a background job): skipped, and logged" \
  "$(run_gate sudo UNSET "$LID_OPEN"):$(gate_said 'skip: no terminal')" "$GATE_SKIPS:1"
check "sudo with an empty PAM_TTY: skipped" "$(run_gate sudo '' "$LID_OPEN")" "$GATE_SKIPS"
check "sudo with an X display for a tty (:0): skipped" "$(run_gate sudo ':0' "$LID_OPEN")" "$GATE_SKIPS"
check "sudo with /dev/null for a tty: skipped" "$(run_gate sudo /dev/null "$LID_OPEN")" "$GATE_SKIPS"
check "a serial line (/dev/ttyS0) is not a console here: skipped" "$(run_gate sudo /dev/ttyS0 "$LID_OPEN")" "$GATE_SKIPS"
check "sudo, a terminal, the lid CLOSED (docked, unreachable): skipped, and logged" \
  "$(run_gate sudo /dev/pts/3 "$LID_CLOSED"):$(gate_said 'skip: lid closed')" "$GATE_SKIPS:1"
check "polkit-1 is never offered, even with a tty and the lid open" \
  "$(run_gate polkit-1 /dev/pts/3 "$LID_OPEN"):$(gate_said 'skip: service is not sudo')" "$GATE_SKIPS:1"
check "login is never offered" "$(run_gate login /dev/tty3 "$LID_OPEN")" "$GATE_SKIPS"
check "a service whose name merely starts with sudo is never offered" "$(run_gate sudoedit /dev/pts/3 "$LID_OPEN")" "$GATE_SKIPS"
check "no PAM_SERVICE at all: skipped" "$(run_gate UNSET /dev/pts/3 "$LID_OPEN")" "$GATE_SKIPS"

printf '\nthe gate: local accounts only (pam_unix, first in the stanza, knows no other)\n'
check "a user not in the passwd file (a domain account a correct password would pass later): skipped, and logged" \
  "$(GATE_USER=stranger run_gate sudo /dev/pts/3 "$LID_OPEN"):$(gate_said 'skip: not a local account')" "$GATE_SKIPS:1"
check "no PAM_USER at all: skipped" "$(GATE_USER=UNSET run_gate sudo /dev/pts/3 "$LID_OPEN")" "$GATE_SKIPS"
check "a user whose name is only a prefix of a local one: skipped" "$(GATE_USER=some run_gate sudo /dev/pts/3 "$LID_OPEN")" "$GATE_SKIPS"
check "the local account on the passwd file's last line: offered" \
  "$(GATE_USER=fingerprint-test-nobody run_gate sudo /dev/pts/3 "$LID_OPEN")" "$GATE_OFFERS"
check "a passwd file that does not exist: skipped" \
  "$(run_gate sudo /dev/pts/3 "$LID_OPEN" --passwd-file "$T/no/such/passwd")" "$GATE_SKIPS"

printf '\nthe gate: reading the lid (anything it cannot read is a skip; the password always works)\n'
L="$T/lid-none"; mkdir -p "$L" || fatal "lid fixture"
check "no lid at all (an empty directory): skipped, and logged" \
  "$(run_gate sudo /dev/pts/3 "$L"):$(gate_said 'skip: lid state unknown')" "$GATE_SKIPS:1"
check "a lid directory that does not exist: skipped" "$(run_gate sudo /dev/pts/3 "$T/no/such/lid")" "$GATE_SKIPS"
L="$T/lid-garbage"; mklid "$L" LID 'state:      ajar'
check "a state it does not know: skipped" "$(run_gate sudo /dev/pts/3 "$L")" "$GATE_SKIPS"
L="$T/lid-empty"; { mkdir -p "$L/LID" && : >"$L/LID/state"; } || fatal "lid fixture"
check "an empty state file: skipped" "$(run_gate sudo /dev/pts/3 "$L")" "$GATE_SKIPS"
# The closed one sorts FIRST, so a later "open" overwriting it would be caught.
L="$T/lid-two-one-closed"; mklid "$L" LID0 'state:      closed'; mklid "$L" LID1 'state:      open'
check "two lids, the first closed and the second open: skipped" "$(run_gate sudo /dev/pts/3 "$L")" "$GATE_SKIPS"
L="$T/lid-two-open"; mklid "$L" LID0 'state:      open'; mklid "$L" LID1 'state:      open'
check "two lids, both open: offered" "$(run_gate sudo /dev/pts/3 "$L")" "$GATE_OFFERS"
L="$T/lid-no-newline"; { mkdir -p "$L/LID" && printf 'state:      open' >"$L/LID/state"; } || fatal "lid fixture"
check "a state line without a final newline still reads as open" "$(run_gate sudo /dev/pts/3 "$L")" "$GATE_OFFERS"

printf '\nthe gate: its arguments and its shape\n'
check "an unknown argument: skipped, and logged" \
  "$(run_gate sudo /dev/pts/3 "$LID_OPEN" --bogus):$(gate_said "skip: bad argument '--bogus'")" "$GATE_SKIPS:1"
: >"$GATE_LOG"
rc="$(env -i PAM_SERVICE=sudo PAM_USER=someone PAM_TTY=/dev/pts/3 "$GATE_SRC" --log-file "$GATE_LOG" --lid-dir >/dev/null 2>&1; echo $?)"
check "--lid-dir with no value: skipped, and logged" "$rc:$(gate_said "skip: bad argument '--lid-dir'")" "$GATE_SKIPS:1"
run_gate sudo /dev/pts/3 "$LID_OPEN" >/dev/null
check "one decision is one log line" "$(wc -l <"$GATE_LOG" | tr -d ' ')" 1
check "the gate is executable in the checkout (pam_exec execs it directly)" \
  "$([[ -x "$GATE_SRC" ]] && echo executable || echo not)" executable
check "the gate is POSIX sh: sh -n parses it" "$(sh -n "$GATE_SRC" 2>&1; echo $?)" 0
# The literal text of the gate's one offering exit; nothing in it is expanded.
# shellcheck disable=SC2016
OFFER_EXIT_LINE='exit "$EXIT_OFFER"'
check "only the very last line offers: exactly one exit with the offer status, at the end" \
  "$(grep -c -x -F "$OFFER_EXIT_LINE" "$GATE_SRC"):$(tail -n 1 "$GATE_SRC")" "1:$OFFER_EXIT_LINE"

# ---------------------------------------------------------------------------
printf '\nthe shipped stanza, exactly\n'
want_stanza="auth sufficient pam_unix.so
auth $SHIPPED_GATE_CONTROL pam_exec.so quiet quiet_log $GATE_INSTALLED_PATH
auth sufficient pam_fprintd.so max-tries=2 timeout=10"
check "the password, then the gate (any failure jumps over the reader), then the fingerprint, and nothing else" \
  "$(grep -v -e '^#' -e '^$' "$STANZA_SRC" | tr -s ' \t' ' ')" "$want_stanza"
stanza_unix_rules="$(grep -E '^[[:space:]]*auth[[:space:]].*pam_unix\.so' "$STANZA_SRC")"
check "its one pam_unix rule carries no nullok (an empty password never passes the early check)" \
  "$(grep -c . <<<"$stanza_unix_rules"):$(grep -c -w nullok <<<"$stanza_unix_rules")" "1:0"

# ---------------------------------------------------------------------------
printf '\narguments\n'
check "an unknown argument is exit 2" "$(run_setup "$ROOT" "" --bogus)" 2
rc="$(run_setup "$ROOT" "" --help)"
check "--help is exit 0 and prints the usage, the greeter flag included" \
  "$rc:$(out_has 'Usage: sudo-fprint-gate.sh'):$(out_has "$GREETER_FLAG  install")" "0:1:1"
check "--check and --remove together is exit 2" "$(run_setup "$ROOT" "" --check --remove)" 2
check "$GREETER_FLAG with --check is exit 2 (it belongs to an install)" "$(run_setup "$ROOT" "" --check "$GREETER_FLAG")" 2
check "$GREETER_FLAG with --remove is exit 2" "$(run_setup "$ROOT" "" "$GREETER_FLAG" --remove)" 2
check "a relative prefix is refused, exit 2" "$(run_setup "$ROOT" "relative/dir")" 2
check "a prefix that does not exist is refused, exit 2" "$(run_setup "$ROOT" "$T/no/such/dir")" 2

# ---------------------------------------------------------------------------
printf '\ninstall (the greeter left alone)\n'
P="$(newprefix)"
rc="$(run_setup "$ROOT" "$P" --check)"
check "--check before any install: exit 1, and blames nothing on libpam (sudo includes no stanza yet)" \
  "$rc:$(out_has 'libpam refuses'):$(out_has 'AUTHENTICATED')" "1:0:0"
rc="$(run_setup "$ROOT" "$P")"
check "installs, exit 0" "$rc" 0
check "$STANZA_INSTALLED_PATH is a byte-identical copy of pam/sudo-fingerprint" \
  "$(cmp -s "$STANZA_SRC" "$P$STANZA_INSTALLED_PATH" && echo same || echo differs)" same
check "$GATE_INSTALLED_PATH (the path the stanza names) is a byte-identical copy of the gate" \
  "$(cmp -s "$GATE_SRC" "$P$GATE_INSTALLED_PATH" && echo same || echo differs)" same
check "the stanza is installed root-owned 0644" \
  "$(logged_re "^sudo install -m 644 -o root -g root [^ ]+ [^ ]+/etc/pam\.d/sudo-fingerprint\.sudo-fprint-gate\.tmp$")" 1
check "the gate is installed root-owned 0755" \
  "$(logged_re "^sudo install -m 755 -o root -g root [^ ]+ [^ ]+/usr/local/libexec/fingerprint-should-offer\.sudo-fprint-gate\.tmp$")" 1
check "every file lands by a rename, so a concurrent sudo never reads half a stack" \
  "$(logged_re '^sudo mv -f [^ ]+\.sudo-fprint-gate\.tmp [^ ]+$')" 4
stanza_at="$(logged_at 'mv -f .*/pam\.d/sudo-fingerprint$')"
sudo_at="$(logged_at 'mv -f .*/pam\.d/sudo$')"
sudo_i_at="$(logged_at 'mv -f .*/pam\.d/sudo-i$')"
check "the stanza, then the includes (a missing include target breaks sudo outright)" \
  "$(( stanza_at > 0 && stanza_at < sudo_at && stanza_at < sudo_i_at ))" 1
check "/etc/pam.d/sudo: the include sits immediately before @include common-auth" \
  "$(grep -n -x -F -e "$INCLUDE_LINE" -e '@include common-auth' "$P/etc/pam.d/sudo" | cut -d: -f1 | tr '\n' ' ')" "9 10 "
check "/etc/pam.d/sudo: and nothing else changed" \
  "$(grep -v -x -F "$INCLUDE_LINE" "$P/etc/pam.d/sudo" | cmp -s - "$PRISTINE/etc/pam.d/sudo" && echo same || echo differs)" same
check "/etc/pam.d/sudo-i: the include sits immediately before @include common-auth" \
  "$(grep -n -x -F -e "$INCLUDE_LINE" -e '@include common-auth' "$P/etc/pam.d/sudo-i" | cut -d: -f1 | tr '\n' ' ')" "9 10 "
check "/etc/pam.d/sudo-i: and nothing else changed" \
  "$(grep -v -x -F "$INCLUDE_LINE" "$P/etc/pam.d/sudo-i" | cmp -s - "$PRISTINE/etc/pam.d/sudo-i" && echo same || echo differs)" same
check "without $GREETER_FLAG the greeter file is untouched, and gdm is never reloaded" \
  "$(same_as_pristine "$P" etc/gdm3/greeter.dconf-defaults):$(logged_re 'systemctl')" "same:0"
check "common-auth, polkit-1 and gdm-fingerprint are untouched" \
  "$(same_as_pristine "$P" etc/pam.d/common-auth) $(same_as_pristine "$P" usr/lib/pam.d/polkit-1) $(same_as_pristine "$P" etc/pam.d/gdm-fingerprint)" \
  "same same same"
rc="$(run_setup "$ROOT" "$P" --check)"
check "--check after the install: exit 0" "$rc" 0
check "--check needs no sudo" "$(logged_re '^sudo ')" 0
check "--check says gdm-fingerprint's own pam_fprintd is fine (GDM runs it beside the password)" \
  "$(out_has 'no PAM stack puts pam_fprintd in front of a password')" 1
check "--check reads the installed stanza's control fields and its jump statically" \
  "$(out_has 'its jump skips exactly the reader')" 1
check "--check loads the installed sudo stack through the real libpam with a correct password" \
  "$(out_has 'loads through the real libpam and accepts a correct password')" 1
check "--check runs the installed stack through the real libpam with a wrong password" \
  "$(out_has 'reaches the reader only when the gate offers, and never authenticates')" 1
check "--check on Ubuntu's own chain (common-auth, common-account, common-session*): nothing the early password check would skip" \
  "$(out_has "$CHAIN_CLEAN"):$(out_has 'which a correct password at the stanza would skip')" "1:0"
check "--check says the greeter keeps GDM's own setting" "$(out_has "keeps GDM's own fingerprint setting")" 1
before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "a second install changes no byte: no second include" "$rc:$(tree_hash "$P")" "0:$before"
P="$(newprefix)"; rm -f "$P/etc/gdm3/greeter.dconf-defaults"
rc="$(run_setup "$ROOT" "$P")"
check "no greeter file at all (no gdm3), without $GREETER_FLAG: installs, exit 0" "$rc" 0
P="$(newprefix)"
sed -i 's/^# enable-fingerprint-authentication=false$/enable-fingerprint-authentication=true/' "$P/etc/gdm3/greeter.dconf-defaults"
rc="$(run_setup "$ROOT" "$P")"
check "a greeter key of the user's own, without $GREETER_FLAG: installs, and leaves it alone" \
  "$rc:$(grep -c -x 'enable-fingerprint-authentication=true' "$P/etc/gdm3/greeter.dconf-defaults")" "0:1"

# ---------------------------------------------------------------------------
printf '\ninstall %s\n' "$GREETER_FLAG"
P="$(newprefix)"
rc="$(run_setup "$ROOT" "$P" "$GREETER_FLAG")"
check "installs, exit 0" "$rc" 0
check "every file lands by a rename, the greeter's too" \
  "$(logged_re '^sudo mv -f [^ ]+\.sudo-fprint-gate\.tmp [^ ]+$')" 5
check "the greeter: the marker and the key, right after [org/gnome/login-screen]" \
  "$(sed -n '11p;13p' "$P/etc/gdm3/greeter.dconf-defaults"):$(sed -n '12p' "$P/etc/gdm3/greeter.dconf-defaults" | cut -c1-20)" \
  "[org/gnome/login-screen]
$GREETER_KEY_LINE:# sudo-fprint-gate: "
check "the greeter: and nothing else changed (Ubuntu's trailing spaces kept)" \
  "$(sed '12,13d' "$P/etc/gdm3/greeter.dconf-defaults" | cmp -s - "$PRISTINE/etc/gdm3/greeter.dconf-defaults" && echo same || echo differs)" same
check "gdm recompiles the greeter config (reload, all its ExecReload does)" "$(logged 'sudo systemctl reload gdm.service')" 1
check "nothing is ever restarted, started or stopped (a gdm restart ends the session)" \
  "$(logged_re 'systemctl (restart|start|stop)')" 0
rc="$(run_setup "$ROOT" "$P" --check)"
check "--check after the install: exit 0, and says the greeter is password-only" \
  "$rc:$(out_has 'the greeter is password-only, and gdm has compiled it')" "0:1"
before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P" "$GREETER_FLAG")"
check "a second install changes no byte: no second include, no second marker" "$rc:$(tree_hash "$P")" "0:$before"
check "... and does not reload gdm, whose compiled config is already fresh" "$(logged 'sudo systemctl reload gdm.service')" 0
rc="$(run_setup "$ROOT" "$P")"
check "an install WITHOUT the flag takes this tool's greeter lines out again, and reloads gdm" \
  "$rc:$(same_as_pristine "$P" etc/gdm3/greeter.dconf-defaults):$(logged 'sudo systemctl reload gdm.service')" "0:same:1"

# ---------------------------------------------------------------------------
printf '\n--check: each piece out of place (exit 1, and it says which)\n'
P="$(installed_prefix)"; printf '# drift\n' >>"$P$STANZA_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the stanza edited in place" "$rc:$(out_has 'sudo-fingerprint DIFFERS')" "1:1"
P="$(installed_prefix)"; ln -sf "$STANZA_SRC" "$P$STANZA_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the stanza replaced by a symlink into the checkout" "$rc:$(out_has 'sudo-fingerprint is a SYMLINK')" "1:1"
P="$(installed_prefix)"; rm -f "$P$STANZA_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the stanza gone while sudo still includes it: says sudo is BROKEN, and how to repair it" \
  "$rc:$(out_has 'sudo is BROKEN'):$(out_has 'pkexec sed -i')" "1:2:1"
P="$(installed_prefix)"; printf '# drift\n' >>"$P$GATE_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the gate edited in place" "$rc:$(out_has 'fingerprint-should-offer DIFFERS')" "1:1"
P="$(installed_prefix)"; rm -f "$P$GATE_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the gate gone (a skip for every sudo: the reader is never offered)" \
  "$rc:$(out_has 'fingerprint-should-offer is not installed')" "1:1"
P="$(installed_prefix)"; chmod 644 "$P$GATE_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the gate not executable" "$rc:$(out_has "is $ME 644, not $ME 755")" "1:1"
P="$(installed_prefix)"; sed -i "/^$INCLUDE_LINE\$/d" "$P/etc/pam.d/sudo"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the include gone from sudo" \
  "$rc:$(out_has "$P/etc/pam.d/sudo does not include sudo-fingerprint exactly once")" "1:1"
P="$(installed_prefix)"; sed -i "/^$INCLUDE_LINE\$/d" "$P/etc/pam.d/sudo-i"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the include gone from sudo-i" \
  "$rc:$(out_has "$P/etc/pam.d/sudo-i does not include sudo-fingerprint exactly once")" "1:1"
P="$(installed_prefix)"
sed -i -e "/^$INCLUDE_LINE\$/d" -e "s/^@include common-auth\$/@include common-auth\n$INCLUDE_LINE/" "$P/etc/pam.d/sudo"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the include AFTER common-auth (it would never be reached on a wrong password)" \
  "$rc:$(out_has 'immediately before @include common-auth')" "1:1"
P="$(installed_prefix)"; sed -i "s/^$INCLUDE_LINE\$/&\n&/" "$P/etc/pam.d/sudo"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the include twice" "$rc:$(out_has 'exactly once, immediately before')" "1:1"
P="$(installed_prefix "$GREETER_FLAG")"; sed -i '12d' "$P/etc/gdm3/greeter.dconf-defaults"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the greeter's marker gone, its key left (no longer this tool's line, so a foreign setting)" \
  "$rc:$(out_has 'keeps GDM'"'"'s own fingerprint setting')" "0:1"
P="$(installed_prefix "$GREETER_FLAG")"; sed -i "13s/=false/=true/" "$P/etc/gdm3/greeter.dconf-defaults"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the greeter key flipped to true under this tool's marker (no longer its line, so a foreign setting)" \
  "$rc:$(out_has 'outside this tool'"'"'s line: enable-fingerprint-authentication=true')" "1:1"
P="$(installed_prefix "$GREETER_FLAG")"; sed -i '13d' "$P/etc/gdm3/greeter.dconf-defaults"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the greeter's key gone, its marker left" "$rc:$(out_has 'does not turn the greeter fingerprint off')" "1:1"
# Cut the file after the login-screen section, so a line appended lands in it.
P="$(installed_prefix "$GREETER_FLAG")"; sed -i '/^\[org\/gnome\/settings-daemon/,$d' "$P/etc/gdm3/greeter.dconf-defaults"
printf 'enable-fingerprint-authentication=true\n' >>"$P/etc/gdm3/greeter.dconf-defaults"
rc="$(run_setup "$ROOT" "$P" --check)"
check "another line in the login-screen section setting the key (the later one would win)" \
  "$rc:$(out_has 'also sets enable-fingerprint-authentication')" "1:1"
P="$(installed_prefix "$GREETER_FLAG")"; touch -d '2025-01-01 00:00' "$P/var/lib/gdm3/greeter-dconf-defaults"
rc="$(run_setup "$ROOT" "$P" --check)"
check "gdm's compiled greeter config older than the file (never reloaded)" "$rc:$(out_has 'has not recompiled')" "1:1"
P="$(installed_prefix "$GREETER_FLAG")"; rm -f "$P/var/lib/gdm3/greeter-dconf-defaults"
rc="$(run_setup "$ROOT" "$P" --check)"
check "gdm's compiled greeter config missing" "$rc:$(out_has 'has not recompiled')" "1:1"
P="$(installed_prefix)"; sed -i '0,/pam_unix/s/^auth.*pam_unix.*/auth [success=end default=ignore] pam_fprintd.so max-tries=1 timeout=10\n&/' "$P/etc/pam.d/common-auth"
rc="$(run_setup "$ROOT" "$P" --check)"
check "common-auth runs pam_fprintd (the stock pam-auth-update profile): names it and the remedy" \
  "$rc:$(out_has 'common-auth puts pam_fprintd where it would delay a password'):$(out_has 'pam-auth-update --disable fprintd')" "1:1:1"
P="$(installed_prefix)"
{ printf 'auth sufficient pam_fprintd.so\n'; cat "$P/usr/lib/pam.d/polkit-1"; } >"$P/etc/pam.d/polkit-1"
rc="$(run_setup "$ROOT" "$P" --check)"
check "an /etc/pam.d/polkit-1 override running pam_fprintd" "$rc:$(out_has 'polkit-1 puts pam_fprintd where it would delay a password')" "1:1"
P="$(installed_prefix)"; sed -i '1a auth sufficient pam_fprintd.so' "$P/usr/lib/pam.d/polkit-1"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the vendor polkit-1 running pam_fprintd, with no override" "$rc:$(out_has 'polkit-1 puts pam_fprintd where it would delay a password')" "1:1"
cp "$PRISTINE/usr/lib/pam.d/polkit-1" "$P/etc/pam.d/polkit-1" || fatal "polkit override fixture"
rc="$(run_setup "$ROOT" "$P" --check)"
check "... but shadowed by a clean /etc/pam.d/polkit-1 it is not effective: exit 0" "$rc" 0
P="$(installed_prefix)"; sed -i '1a # auth sufficient pam_fprintd.so' "$P/etc/pam.d/common-auth"
rc="$(run_setup "$ROOT" "$P" --check)"
check "a COMMENTED pam_fprintd line runs nothing: exit 0" "$rc" 0
P="$(installed_prefix)"; rm -f "$P/usr/lib/x86_64-linux-gnu/security/pam_fprintd.so"
rc="$(run_setup "$ROOT" "$P" --check)"
check "pam_fprintd.so not installed" "$rc:$(out_has 'pam_fprintd.so is not installed')" "1:1"
P="$(installed_prefix)"; sed -i '0,/pam_unix/s/^auth.*pam_unix.*/auth requisite pam_faillock.so preauth\n&/' "$P/etc/pam.d/common-auth"
rc="$(run_setup "$ROOT" "$P" --check)"
check "common-auth gains pam_faillock (a correct password at the stanza would skip its lockout): named on sudo's and sudo-i's chains" \
  "$rc:$(out_has 'sudo → common-auth has pam_faillock.so, which'):$(out_has 'sudo-i → common-auth has pam_faillock.so, which')" "1:1:1"
P="$(installed_prefix)"; printf '@include common-auth-extra\n' >>"$P/etc/pam.d/common-auth"
rc="$(run_setup "$ROOT" "$P" --check)"
check "common-auth includes a file that does not exist (libpam cannot load that chain)" \
  "$rc:$(out_has 'common-auth → common-auth-extra: no such file in')" "1:2"
P="$(installed_prefix)"; cp "$ROOT_BAD/pam/sudo-fingerprint" "$P$STANZA_INSTALLED_PATH"
rc="$(run_setup "$ROOT_BAD" "$P" --check)"
check "an installed stanza libpam cannot load, though it matches its checkout: says sudo refuses everyone" \
  "$rc:$(out_has 'libpam refuses a CORRECT password'):$(out_has 'sudo refuses everyone'):$(out_has 'sudo-fingerprint matches this checkout')" \
  "1:2:1:1"

printf '\n--check: an installed stanza whose control flow is wrong, though it matches its checkout\n'
P="$(installed_prefix)"; cp "$T/root-jump-4/pam/sudo-fingerprint" "$P$STANZA_INSTALLED_PATH"
rc="$(run_setup "$T/root-jump-4" "$P" --check)"
check "a jump three rules too far (onto common-auth's pam_permit): the static check names it" \
  "$rc:$(out_has 'default=4 lands on rule 7, not one past pam_fprintd.so (rule 3)'):$(out_has 'sudo-fingerprint matches this checkout')" "1:1:1"
check "... the wrong-password probe sees a skip and a missing gate AUTHENTICATE with no credential, in sudo and sudo-i" \
  "$(out_has 'a gate that skips AUTHENTICATED with no credential'):$(out_has 'a missing gate AUTHENTICATED with no credential')" "2:2"
check "... and --check says to take the stanza out of sudo now" "$(out_has 'take it out of sudo now')" 1
P="$(installed_prefix)"; cp "$ROOT_TYPO/pam/sudo-fingerprint" "$P$STANZA_INSTALLED_PATH"
rc="$(run_setup "$ROOT_TYPO" "$P" --check)"
check "a typo in the gate's control field: the static check names the unknown return code" \
  "$rc:$(out_has '"defualt" is not a return code libpam knows')" "1:1"
check "... the correct-password probe cannot see it (it returns at the first rule)" \
  "$(out_has 'accepts a correct password')" 1
check "... the wrong-password probe sees a skip still reach the reader, in sudo and sudo-i" \
  "$(out_has 'a gate that skips still reached the reader')" 2

# ---------------------------------------------------------------------------
printf '\ninstall refuses, and writes nothing\n'
P="$(newprefix)"; sed -i '/^@include common-auth$/d' "$P/etc/pam.d/sudo"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "a sudo file with no @include common-auth to put the fingerprint before: exit 2" \
  "$rc:$(tree_hash "$P"):$(logged_re '^sudo '):$(out_has "has no single '@include common-auth'")" "2:$before:0:1"
P="$(newprefix)"; printf '@include common-auth\n' >>"$P/etc/pam.d/sudo-i"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "a sudo-i file with two of them (which one?): exit 2" "$rc:$(tree_hash "$P")" "2:$before"
P="$(newprefix)"; sed -i '0,/pam_unix/s/^auth.*pam_unix.*/auth [success=end default=ignore] pam_fprintd.so\n&/' "$P/etc/pam.d/common-auth"
before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "common-auth already running pam_fprintd: exit 1, names the remedy" \
  "$rc:$(tree_hash "$P"):$(out_has 'pam-auth-update --disable fprintd')" "1:$before:1"
P="$(newprefix)"; sed -i 's/^# enable-fingerprint-authentication=false$/enable-fingerprint-authentication=true/' "$P/etc/gdm3/greeter.dconf-defaults"
before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P" "$GREETER_FLAG")"
check "$GREETER_FLAG, and the greeter key already set by someone else: exit 1, shows the line" \
  "$rc:$(tree_hash "$P"):$(out_has 'also sets enable-fingerprint-authentication')" "1:$before:1"
P="$(newprefix)"; sed -i 's/^\[org\/gnome\/login-screen\]$/[org\/gnome\/other]/' "$P/etc/gdm3/greeter.dconf-defaults"
before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P" "$GREETER_FLAG")"
check "$GREETER_FLAG, and a greeter file with no [org/gnome/login-screen] section: exit 2" "$rc:$(tree_hash "$P")" "2:$before"
P="$(newprefix)"; rm -f "$P/etc/gdm3/greeter.dconf-defaults"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P" "$GREETER_FLAG")"
check "$GREETER_FLAG, and no greeter file at all: exit 2" "$rc:$(tree_hash "$P")" "2:$before"
P="$(newprefix)"; truncate -s -1 "$P/etc/gdm3/greeter.dconf-defaults"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P" "$GREETER_FLAG")"
check "$GREETER_FLAG, and a greeter file with no final newline: exit 2" "$rc:$(tree_hash "$P")" "2:$before"
P="$(newprefix)"; rm -f "$P/usr/lib/x86_64-linux-gnu/security/pam_fprintd.so"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "libpam-fprintd not installed: exit 2" "$rc:$(tree_hash "$P"):$(out_has 'apt install libpam-fprintd')" "2:$before:1"
P="$(newprefix)"; rm -f "$P/etc/pam.d/sudo-i"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "no /etc/pam.d/sudo-i: exit 2" "$rc:$(tree_hash "$P")" "2:$before"
P="$(newprefix)"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT_BAD" "$P")"
check "a stanza libpam cannot load (one misspelled keyword would refuse EVERY sudo): exit 1, nothing written" \
  "$rc:$(tree_hash "$P"):$(logged_re '^sudo '):$(out_has 'libpam refuses a CORRECT password')" "1:$before:0:2"
check "... and the static check names the keyword too" "$(out_has '"sufficent" is not a control libpam knows')" 1
P="$(newprefix)"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT_TYPO" "$P")"
check "a typo in the gate's control field (the line then acts as bad): exit 1, nothing written" \
  "$rc:$(tree_hash "$P"):$(logged_re '^sudo ')" "1:$before:0"
check "... named statically" "$(out_has '"defualt" is not a return code libpam knows')" 1
check "... and caught through libpam: a skip and a missing gate both still reach the reader" \
  "$(out_has 'a gate that skips still reached the reader'):$(out_has 'a missing gate still reached the reader')" "2:2"
P="$(newprefix)"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT_EXTRA_RULE" "$P")"
check "an extra rule between the gate and the reader (the jump lands ON the reader): exit 1, nothing written" \
  "$rc:$(tree_hash "$P"):$(out_has 'default=1 lands on rule 4, not one past pam_fprintd.so (rule 4)')" "1:$before:1"
P="$(newprefix)"; sed -i '0,/pam_unix/s/^auth.*pam_unix.*/auth requisite pam_faillock.so preauth\n&/' "$P/etc/pam.d/common-auth"
before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "common-auth with pam_faillock: exit 1, nothing written, named on both sudo services' chains" \
  "$rc:$(tree_hash "$P"):$(out_has 'pam_faillock.so, which a correct password at the stanza would skip')" "1:$before:2"
P="$(newprefix)"; truncate -s -1 "$P/etc/pam.d/sudo"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "a sudo file with no final newline (--remove could not restore it byte for byte): exit 2" \
  "$rc:$(tree_hash "$P"):$(out_has 'does not end in a newline')" "2:$before:1"
P="$(newprefix)"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT_NO_PROBE" "$P")"
check "a checkout without the libpam probe (nothing to validate the stack with): exit 2, nothing written" \
  "$rc:$(tree_hash "$P"):$(out_has 'are needed to run the stack')" "2:$before:1"
P="$(newprefix)"
rc="$(STUB_GDM_RELOAD_FAIL=1 run_setup "$ROOT" "$P" "$GREETER_FLAG")"
check "$GREETER_FLAG, and a gdm reload that fails: exit 1, and says the greeter changes at the next boot" \
  "$rc:$(out_has 'at the next boot')" "1:1"

# ---------------------------------------------------------------------------
printf '\nthe auth chain a correct password at the stanza skips (everything after its include, includes followed)\n'
# check_chain_refused <row> <prefix> <needle> <times> — an install on a prefix
# whose chain was edited: exit 1, no byte written, no sudo, and the needle named
# <times> times (once per sudo service whose chain holds it).
check_chain_refused() {
  local row="$1" pfx="$2" needle="$3" times="$4" before rc
  before="$(tree_hash "$pfx")"
  rc="$(run_setup "$ROOT" "$pfx")"
  check "$row" "$rc:$(tree_hash "$pfx"):$(logged_re '^sudo '):$(out_has "$needle")" "1:$before:0:$times"
}
# check_chain_accepted <row> <prefix> — an install on a prefix whose chain was
# edited: exit 0 (its libpam probes included), and --check then finds the chain clean.
check_chain_accepted() {
  local row="$1" pfx="$2" install_rc check_rc
  install_rc="$(run_setup "$ROOT" "$pfx")"
  check_rc="$(run_setup "$ROOT" "$pfx" --check)"
  check "$row" "$install_rc:$check_rc:$(out_has "$CHAIN_CLEAN")" "0:0:1"
}
# nest_includes <prefix> <files> — common-auth includes nest-1, which includes
# nest-2, and so on; the last holds a known rule. common-auth sits one level
# below sudo, so nest-N sits N+1 levels below it.
nest_includes() {
  local pfx="$1" files="$2" i
  printf '@include nest-1\n' >>"$pfx/etc/pam.d/common-auth" || fatal "nest fixture"
  for (( i = 1; i < files; i++ )); do
    printf '@include nest-%s\n' "$((i + 1))" >"$pfx/etc/pam.d/nest-$i" || fatal "nest fixture"
  done
  printf 'auth required pam_permit.so\n' >"$pfx/etc/pam.d/nest-$files" || fatal "nest fixture"
}

P="$(newprefix)"; sed -i "s/^@include common-auth\$/&\n$SKIPPED_RULE/" "$P/etc/pam.d/sudo"
check_chain_refused "an auth rule in sudo after @include common-auth: exit 1, nothing written, named" \
  "$P" "sudo has pam_faillock.so, which a correct password at the stanza would skip: $SKIPPED_RULE" 1
P="$(newprefix)"; sed -i "s/^@include common-auth\$/&\n$SKIPPED_RULE/" "$P/etc/pam.d/sudo-i"
check_chain_refused "an auth rule in sudo-i after @include common-auth: exit 1, nothing written, named" \
  "$P" "sudo-i has pam_faillock.so, which a correct password at the stanza would skip: $SKIPPED_RULE" 1
P="$(newprefix)"; printf '@include extra-auth\n' >>"$P/etc/pam.d/common-auth"
printf '%s\n' "$SKIPPED_RULE" >"$P/etc/pam.d/extra-auth" || fatal "chain fixture"
check_chain_refused "common-auth @includes a file holding an auth rule: named through the include, on both chains" \
  "$P" "common-auth → extra-auth has pam_faillock.so, which" 2
P="$(newprefix)"; printf 'auth include extra-auth\n' >>"$P/etc/pam.d/common-auth"
printf '%s\n' "$SKIPPED_RULE" >"$P/etc/pam.d/extra-auth" || fatal "chain fixture"
check_chain_refused "common-auth has 'auth include' of such a file: named through it" \
  "$P" "common-auth → extra-auth has pam_faillock.so, which" 2
P="$(newprefix)"; printf 'auth substack extra-auth\n' >>"$P/etc/pam.d/common-auth"
printf '%s\n' "$SKIPPED_RULE" >"$P/etc/pam.d/extra-auth" || fatal "chain fixture"
check_chain_refused "common-auth has 'auth substack' of such a file: named through it" \
  "$P" "common-auth → extra-auth has pam_faillock.so, which" 2
P="$(newprefix)"; printf -- '-auth optional pam_gnome_keyring.so\n' >>"$P/etc/pam.d/common-auth"
check_chain_refused "a -auth rule (its module may not even be installed) is an auth rule too: named" \
  "$P" "common-auth has pam_gnome_keyring.so, which a correct password at the stanza would skip: -auth optional" 2
P="$(newprefix)"; printf 'AUTH required pam_faillock.so authfail\n' >>"$P/etc/pam.d/common-auth"
check_chain_refused "an upper-case AUTH rule (libpam reads the type case-insensitively): named" \
  "$P" "common-auth has pam_faillock.so, which a correct password at the stanza would skip: AUTH required" 2
P="$(newprefix)"; printf '%s\n' $'auth required \\' 'pam_faillock.so authfail' >>"$P/etc/pam.d/common-auth"
check_chain_refused "a rule continued onto the next line with a backslash (libpam joins them): refused" \
  "$P" "common-auth continues a line onto the next" 2
P="$(newprefix)"; printf '@include vendor-auth\n' >>"$P/etc/pam.d/common-auth"
printf '%s\n' "$SKIPPED_RULE" >"$P/usr/lib/pam.d/vendor-auth" || fatal "chain fixture"
check_chain_refused "an include found only in the vendor directory (libpam's fallback): read there, and named" \
  "$P" "common-auth → vendor-auth has pam_faillock.so, which" 2
P="$(newprefix)"; printf '@include /etc/security/extra-auth\n' >>"$P/etc/pam.d/common-auth"
{ mkdir -p "$P/etc/security" && printf '%s\n' "$SKIPPED_RULE" >"$P/etc/security/extra-auth"; } || fatal "chain fixture"
check_chain_refused "an include by absolute path: read where it points, and named" \
  "$P" "common-auth → /etc/security/extra-auth has pam_faillock.so, which" 2
P="$(newprefix)"; printf '@include no-such-file\n' >>"$P/etc/pam.d/common-auth"
check_chain_refused "an include of a file that exists nowhere: refused (libpam cannot load that chain)" \
  "$P" "common-auth → no-such-file: no such file in" 2
# Outside /etc/pam.d, where the pam_fprintd guard would refuse an unreadable
# file first: this row is the chain check's own.
P="$(newprefix)"; UNREADABLE_INCLUDE="$P/etc/security/unreadable-auth"
printf '@include /etc/security/unreadable-auth\n' >>"$P/etc/pam.d/common-auth"
{ mkdir -p "$P/etc/security" && printf 'auth required pam_permit.so\n' >"$UNREADABLE_INCLUDE"; } || fatal "chain fixture"
before="$(tree_hash "$P")"
chmod 000 "$UNREADABLE_INCLUDE" || fatal "chain fixture"
[[ -r "$UNREADABLE_INCLUDE" ]] && fatal "the unreadable include is readable (is the suite running as root?)"
rc="$(run_setup "$ROOT" "$P")"
chmod 644 "$UNREADABLE_INCLUDE" || fatal "chain fixture"
check "an include this check cannot read: exit 1, nothing written, and refused (what it runs cannot be known)" \
  "$rc:$(tree_hash "$P"):$(logged_re '^sudo '):$(out_has "$UNREADABLE_INCLUDE cannot be read")" "1:$before:0:2"
P="$(newprefix)"; printf '@include loop-a\n' >>"$P/etc/pam.d/common-auth"
{ printf '@include loop-b\n' >"$P/etc/pam.d/loop-a" && printf '@include loop-a\n' >"$P/etc/pam.d/loop-b"; } \
  || fatal "chain fixture"
check_chain_refused "an include loop (libpam cannot load it): refused, the loop named" \
  "$P" "common-auth → loop-a → loop-b → loop-a loops back into a file it is already reading" 2
P="$(newprefix)"; nest_includes "$P" "$((MAX_INCLUDE_DEPTH - 1))"
check_chain_accepted "includes nested $MAX_INCLUDE_DEPTH levels deep, as deep as libpam loads: installs, its libpam probes too" "$P"
P="$(newprefix)"; nest_includes "$P" "$MAX_INCLUDE_DEPTH"
check_chain_refused "one level deeper: refused, the level named" \
  "$P" "→ nest-$MAX_INCLUDE_DEPTH nests includes deeper than libpam loads" 2
P="$(newprefix)"; printf '@include shadowed-auth\n' >>"$P/etc/pam.d/common-auth"
{ printf '%s\n' "$SKIPPED_RULE" >"$P/usr/lib/pam.d/shadowed-auth" \
    && printf 'auth optional pam_permit.so\n' >"$P/etc/pam.d/shadowed-auth"; } || fatal "chain fixture"
check_chain_accepted "an /etc/pam.d file shadows its vendor twin, whose auth rule is then not on the chain: installs" "$P"
P="$(newprefix)"; printf 'account include auth-and-account\n' >>"$P/etc/pam.d/common-account"
printf '%s\n' "$SKIPPED_RULE" 'account required pam_permit.so' >"$P/etc/pam.d/auth-and-account" || fatal "chain fixture"
check_chain_accepted "an 'account include' of a file that also holds an auth rule brings in no auth rule: installs" "$P"
P="$(newprefix)"; sed -i '1a auth optional pam_echo.so runs before the stanza' "$P/etc/pam.d/sudo"
check_chain_accepted "an auth rule BEFORE the stanza's include runs before the password check, so nothing skips it: installs" "$P"
P="$(installed_prefix)"; sed -i "s/^@include common-auth\$/&\n$SKIPPED_RULE/" "$P/etc/pam.d/sudo-i"
rc="$(run_setup "$ROOT" "$P" --check)"
check "--check: an auth rule added to sudo-i after common-auth, after the install: exit 1, named" \
  "$rc:$(out_has "sudo-i has pam_faillock.so, which a correct password at the stanza would skip"):$(out_has "$CHAIN_CLEAN")" "1:1:0"

printf '\ninstall refuses every jump but the one that skips exactly the reader (a mutation sweep)\n'
# Where each count lands, counting the stanza's three rules and then
# common-auth's: 2 on pam_sss, 3 on its pam_deny, 4 on its pam_permit
# (authenticated with no credential), 5 on pam_cap; 0 is the reader itself.
for jump in "${JUMP_MUTANTS[@]}"; do
  P="$(newprefix)"; before="$(tree_hash "$P")"
  rc="$(run_setup "$T/root-jump-$jump" "$P")"
  check "default=$jump: exit 1, nothing written, and the static check names the jump" \
    "$rc:$(tree_hash "$P"):$(logged_re '^sudo '):$(out_has "default=$jump lands on rule")" "1:$before:0:1"
done

# ---------------------------------------------------------------------------
printf '\n--remove\n'
P="$(installed_prefix "$GREETER_FLAG")"
rc="$(run_setup "$ROOT" "$P" --remove)"
check "--remove: exit 0" "$rc" 0
check "sudo, sudo-i and the greeter file are byte-identical to before the install" \
  "$(same_as_pristine "$P" etc/pam.d/sudo) $(same_as_pristine "$P" etc/pam.d/sudo-i) $(same_as_pristine "$P" etc/gdm3/greeter.dconf-defaults)" \
  "same same same"
check "the stanza and the gate are gone" \
  "$([[ -e $P$STANZA_INSTALLED_PATH || -e $P$GATE_INSTALLED_PATH ]] && echo present || echo gone)" gone
sudo_at="$(logged_at 'mv -f .*/pam\.d/sudo$')"
stanza_at="$(logged_at '^sudo rm -f .*/pam\.d/sudo-fingerprint$')"
check "the includes come out BEFORE the stanza does (a missing include target breaks sudo outright)" \
  "$(( sudo_at > 0 && sudo_at < stanza_at ))" 1
check "gdm recompiles the greeter config" "$(logged 'sudo systemctl reload gdm.service')" 1
check "--check after --remove: exit 1" "$(run_setup "$ROOT" "$P" --check)" 1
P="$(installed_prefix)"
rc="$(run_setup "$ROOT" "$P" --remove)"
check "--remove of an install without the greeter: exit 0, and gdm is not reloaded" \
  "$rc:$(logged_re 'systemctl')" "0:0"
P="$(newprefix)"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P" --remove)"
check "--remove with nothing installed: exit 0, no sudo, no byte changed" \
  "$rc:$(logged_re '^sudo '):$(tree_hash "$P")" "0:0:$before"

# ---------------------------------------------------------------------------
printf '\nthe worktree guard\n'
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null
   -c protocol.file.allow=always -c init.defaultBranch=main)
mkroot "$T/repo"
{ "${G[@]}" -C "$T/repo" init -q && "${G[@]}" -C "$T/repo" add -A \
    && "${G[@]}" -C "$T/repo" commit -q -m fixture \
    && "${G[@]}" -C "$T/repo" worktree add -q -b feature "$T/wt"; } >/dev/null 2>&1 \
  || fatal "could not build the worktree fixtures"
# A superproject holding the repo as a submodule, and a linked worktree of the
# superproject with the submodule checked out in it. Inside that worktree the
# submodule's own git dir equals its common dir, so only the superproject tells.
mkdir -p "$T/super" || fatal "superproject fixture"
{ "${G[@]}" -C "$T/super" init -q && "${G[@]}" -C "$T/super" submodule add -q "$T/repo" gate \
    && "${G[@]}" -C "$T/super" commit -q -m fixture \
    && "${G[@]}" -C "$T/super" worktree add -q -b feature "$T/super-wt" \
    && "${G[@]}" -C "$T/super-wt" submodule update -q --init; } >/dev/null 2>&1 \
  || fatal "could not build the submodule fixtures"
[[ -f "$T/super-wt/gate/sudo-fprint-gate.sh" ]] || fatal "the submodule in the superproject's worktree is not checked out"
P="$(newprefix)"; before="$(tree_hash "$P")"
rc="$(run_setup "$T/wt" "$P")"
check "from a linked worktree: exit 1, nothing written, and the refusal names the remedy" \
  "$rc:$(tree_hash "$P"):$(out_has 'Run it from the primary checkout')" "1:$before:1"
P="$(newprefix)"
rc="$(SUDO_FPRINT_GATE_ALLOW_WORKTREE=1 run_setup "$T/wt" "$P")"
check "SUDO_FPRINT_GATE_ALLOW_WORKTREE=1 overrides it, with a warning and no red refusal" \
  "$rc:$([[ -f $P$STANZA_INSTALLED_PATH ]] && echo installed):$(out_has 'refusing to install'):$(out_has 'as SUDO_FPRINT_GATE_ALLOW_WORKTREE=1 asks')" \
  "0:installed:0:1"
P="$(newprefix)"
rc="$(run_setup "$T/repo" "$P")"
check "the primary checkout of the same repo is not a worktree: installs" "$rc" 0
P="$(newprefix)"
rc="$(run_setup "$T/wt" "$P" --check)"
check "--check runs from a worktree (it writes nothing), and is not refused" \
  "$rc:$(out_has 'refusing to install'):$(out_has 'is not installed')" "1:0:2"
P="$(newprefix)"; before="$(tree_hash "$P")"
rc="$(run_setup "$T/super-wt/gate" "$P")"
check "from a submodule inside a linked worktree of its superproject: exit 1, nothing written, names that worktree" \
  "$rc:$(tree_hash "$P"):$(out_has "refusing to install from inside a linked WORKTREE: $T/super-wt")" "1:$before:1"
P="$(newprefix)"
rc="$(run_setup "$T/super/gate" "$P")"
check "from a submodule of the superproject's primary checkout (the pinned use): installs" "$rc" 0

# ---------------------------------------------------------------------------
# The installed files, run through the REAL libpam. pam_start_confdir() reads
# the service from a directory of our choosing, so no root and no /etc.
printf '\nthe installed stack, through the real libpam (permit/deny stand in for right/wrong)\n'
P="$(installed_prefix)"
CONF="$T/pamconf"
# stack <first password> <finger> <second password> <lid dir> — the installed
# sudo, stanza and common-auth in $CONF, each real module swapped for its
# stand-in (pam_permit = right, pam_deny = wrong), and the INSTALLED gate.
stack() {
  { rm -rf "$CONF" && mkdir -p "$CONF"; } || fatal "pamconf"
  cp "$P/etc/pam.d/sudo" "$P/etc/pam.d/common-auth" "$P$STANZA_INSTALLED_PATH" "$CONF/" || fatal "pamconf"
  printf 'account required pam_permit.so\n' >"$CONF/common-account"
  printf 'session required pam_permit.so\n' >"$CONF/common-session-noninteractive"
  sed -i -e "s|pam_unix\.so\$|pam_$1.so|" -e "s|pam_fprintd\.so max-tries=2 timeout=10|pam_$2.so|" \
         -e "s|$GATE_INSTALLED_PATH|$P$GATE_INSTALLED_PATH --lid-dir $4 --passwd-file $PASSWD_FIXTURE --log-file $GATE_LOG|" \
         "$CONF/sudo-fingerprint" || fatal "pamconf"
  sed -i -e "s|pam_unix\.so nullok|pam_$3.so|" -e 's|pam_sss\.so use_first_pass|pam_deny.so|' \
         -e 's|pam_cap\.so|pam_permit.so|' "$CONF/common-auth" || fatal "pamconf"
  : >"$GATE_LOG"
}
# probe [args] — the shared probe on $CONF's sudo: "<result> <prompts>".
probe() { python3 -I "$PROBE" --confdir "$CONF" --service sudo "$@" 2>&1; }
# authenticate <tty> — the result alone, as the local account "someone".
authenticate() { local outcome; outcome="$(probe --user someone --tty "$1")"; printf '%s' "${outcome%% *}"; }

stack permit deny deny "$LID_OPEN"
python3 -I "$PROBE" --confdir "$CONF" --service sudo >/dev/null 2>&1
[[ $? == 2 ]] && fatal "the probe cannot run here: no libpam with pam_start_confdir (Linux-PAM < 1.4)"
check "the stand-ins replaced every real module and the gate path (else this section tests nothing)" \
  "$(cat "$CONF"/* | grep -v '^[[:space:]]*#' | grep -c -E "pam_unix|pam_fprintd|pam_sss|pam_cap| $GATE_INSTALLED_PATH")" 0
result="$(authenticate /dev/pts/3)"
check "the right password first: authenticated, and the gate never even runs" \
  "$result:$(wc -l <"$GATE_LOG" | tr -d ' ')" "$PAM_SUCCESS:0"
stack deny permit deny "$LID_OPEN"
check "a wrong (or empty) password, a terminal, the lid open: the finger authenticates" \
  "$(authenticate /dev/pts/3):$(gate_said 'offer:')" "$PAM_SUCCESS:1"
stack deny deny permit "$LID_OPEN"
check "the finger fails, and common-auth's own check accepts: authenticated (a failed finger decides nothing)" \
  "$(authenticate /dev/pts/3)" "$PAM_SUCCESS"
stack deny permit deny "$LID_CLOSED"
check "lid closed: the finger is never asked, though it would have matched" \
  "$(authenticate /dev/pts/3):$(gate_said 'skip: lid closed')" "$PAM_AUTH_ERR:1"
stack deny deny permit "$LID_CLOSED"
check "lid closed, and common-auth's own check accepts: authenticated (the skip's jump poisons nothing)" \
  "$(authenticate /dev/pts/3)" "$PAM_SUCCESS"
stack deny permit deny "$LID_OPEN"
check "no terminal: the finger is never asked, though it would have matched" \
  "$(authenticate ''):$(gate_said 'skip: no terminal')" "$PAM_AUTH_ERR:1"
stack deny deny deny "$LID_OPEN"
check "everything wrong: refused" "$(authenticate /dev/pts/3)" "$PAM_AUTH_ERR"
stack permit permit permit "$LID_OPEN"; rm -f "$CONF/sudo-fingerprint"
check "the stanza missing while sudo includes it: libpam aborts before any password is asked" \
  "$(authenticate /dev/pts/3)" "start:$PAM_ABORT"

printf '\nthe gate fails closed: a gate that cannot answer is a skip (a finger that would match is never asked)\n'
stack deny permit deny "$LID_OPEN"
sed -i "s|$P$GATE_INSTALLED_PATH|$T/no/such/gate|" "$CONF/sudo-fingerprint"
check "the gate missing, the lid open and a terminal attached: refused" "$(authenticate /dev/pts/3)" "$PAM_AUTH_ERR"
GATE_NOT_EXECUTABLE="$T/gate-not-executable"
{ cp "$GATE_SRC" "$GATE_NOT_EXECUTABLE" && chmod 644 "$GATE_NOT_EXECUTABLE"; } || fatal "gate fixture"
stack deny permit deny "$LID_OPEN"
sed -i "s|$P$GATE_INSTALLED_PATH|$GATE_NOT_EXECUTABLE|" "$CONF/sudo-fingerprint"
check "the gate not executable: refused" "$(authenticate /dev/pts/3)" "$PAM_AUTH_ERR"
GATE_KILLED="$T/gate-killed"
{ printf '#!/bin/sh\nkill -9 $$\n' >"$GATE_KILLED" && chmod 755 "$GATE_KILLED"; } || fatal "gate fixture"
stack deny permit deny "$LID_OPEN"
sed -i "s|$P$GATE_INSTALLED_PATH|$GATE_KILLED|" "$CONF/sudo-fingerprint"
check "the gate killed by a signal: refused" "$(authenticate /dev/pts/3)" "$PAM_AUTH_ERR"
GATE_ERRORS="$T/gate-errors"
{ printf '#!/bin/sh\nexit 2\n' >"$GATE_ERRORS" && chmod 755 "$GATE_ERRORS"; } || fatal "gate fixture"
stack deny permit deny "$LID_OPEN"
sed -i "s|$P$GATE_INSTALLED_PATH|$GATE_ERRORS|" "$CONF/sudo-fingerprint"
check "the gate exiting with any other status: refused" "$(authenticate /dev/pts/3)" "$PAM_AUTH_ERR"

# ---------------------------------------------------------------------------
# Why the stanza is shaped as it is, measured on purpose-built stanzas rather
# than the shipped one: the password stand-in fails, every credential check in
# an Ubuntu-shaped common-auth fails, and the reader stand-in only records that
# it was reached.
printf '\nthe shape, measured (a wrong password everywhere; the reader only records being reached)\n'
SHAPE_CONF="$T/shapeconf"
READER_REACHED="$T/reader-reached"
mkdir -p "$SHAPE_CONF" || fatal "shape fixture"
{ printf '#!/bin/sh\nexit 0\n' >"$T/shape-gate-offers" && printf '#!/bin/sh\nexit 1\n' >"$T/shape-gate-skips" \
    && cp "$T/shape-gate-offers" "$T/shape-gate-not-executable" \
    && chmod 755 "$T/shape-gate-offers" "$T/shape-gate-skips" && chmod 644 "$T/shape-gate-not-executable"; } \
  || fatal "shape fixture"
cat >"$SHAPE_CONF/common-auth" <<'EOF' || fatal "shape fixture"
auth    [success=2 default=ignore]      pam_deny.so
auth    [success=1 default=ignore]      pam_deny.so
auth    requisite                       pam_deny.so
auth    required                        pam_permit.so
auth    optional                        pam_permit.so
EOF
printf '@include sudo-fingerprint\n@include common-auth\naccount required pam_permit.so\n' >"$SHAPE_CONF/sudo" \
  || fatal "shape fixture"
# shape <gate line> — "<authenticated|refused>, <reader reached|reader not reached>"
shape() {
  printf 'auth  sufficient  pam_deny.so\n%s\nauth  optional  pam_exec.so quiet /usr/bin/touch %s\n' \
    "$1" "$READER_REACHED" >"$SHAPE_CONF/sudo-fingerprint" || fatal "shape fixture"
  rm -f "$READER_REACHED"
  local outcome verdict reader_state
  outcome="$(python3 -I "$PROBE" --confdir "$SHAPE_CONF" --service sudo --tty /dev/pts/3 2>&1)"
  verdict=refused
  [[ "${outcome%% *}" == "$PAM_SUCCESS" ]] && verdict=authenticated
  reader_state="reader not reached"
  [[ -e "$READER_REACHED" ]] && reader_state="reader reached"
  printf '%s, %s' "$verdict" "$reader_state"
}
check "an older shape (exit 0 = skip, [success=1 default=ignore]), the gate skipping: refused, reader not reached" \
  "$(shape "auth [success=1 default=ignore] pam_exec.so quiet quiet_log $T/shape-gate-offers")" "refused, reader not reached"
check "that shape with its one jump three rules too far (success=4): AUTHENTICATED with no credential" \
  "$(shape "auth [success=4 default=ignore] pam_exec.so quiet quiet_log $T/shape-gate-offers")" "authenticated, reader not reached"
check "that shape with its gate MISSING: the reader is reached (it failed open)" \
  "$(shape "auth [success=1 default=ignore] pam_exec.so quiet quiet_log $T/no/such/gate")" "refused, reader reached"
check "this shape ($SHIPPED_GATE_CONTROL), the gate offering: the reader is reached" \
  "$(shape "auth $SHIPPED_GATE_CONTROL pam_exec.so quiet quiet_log $T/shape-gate-offers")" "refused, reader reached"
check "this shape, the gate skipping: the reader is not reached" \
  "$(shape "auth $SHIPPED_GATE_CONTROL pam_exec.so quiet quiet_log $T/shape-gate-skips")" "refused, reader not reached"
check "this shape, the gate MISSING: the reader is not reached (it fails closed)" \
  "$(shape "auth $SHIPPED_GATE_CONTROL pam_exec.so quiet quiet_log $T/no/such/gate")" "refused, reader not reached"
check "this shape, the gate not executable: the reader is not reached" \
  "$(shape "auth $SHIPPED_GATE_CONTROL pam_exec.so quiet quiet_log $T/shape-gate-not-executable")" "refused, reader not reached"
check "this shape with a control-field typo (defualt=1), the gate skipping: the reader IS reached (why the install probes)" \
  "$(shape "auth [success=ignore defualt=1] pam_exec.so quiet quiet_log $T/shape-gate-skips")" "refused, reader reached"

printf '\nthe probe itself (its prompt count is what the next two rows rest on)\n'
PROBE_CONF="$T/probeconf"
mkdir -p "$PROBE_CONF" || fatal "probe fixture"
printf 'auth optional pam_echo.so an info message, not a prompt\nauth required pam_permit.so\n' \
  >"$PROBE_CONF/echo-then-permit" || fatal "probe fixture"
check "an info message (what pam_fprintd's 'Place your finger' is) is not counted as a prompt" \
  "$(python3 -I "$PROBE" --confdir "$PROBE_CONF" --service echo-then-permit 2>&1)" "$PAM_SUCCESS 0"
check "a service that does not exist: pam_start's own refusal, never a result" \
  "$(python3 -I "$PROBE" --confdir "$PROBE_CONF" --service no-such-service 2>&1)" "start:$PAM_ABORT"
check "bad arguments: exit 2 (could not run), never a result" \
  "$(python3 -I "$PROBE" --service no-confdir-given >/dev/null 2>&1; echo $?)" 2

printf '\nthe re-prompt is the caller retrying, not common-auth (the REAL pam_unix, an account it does not know)\n'
stack unix deny unix "$LID_OPEN"
check "one attempt asks ONCE: common-auth's pam_unix re-checks the cached password, and the attempt fails" \
  "$(probe --user fingerprint-test-nobody --tty /dev/pts/3):$(gate_said 'offer:')" "$PAM_AUTH_ERR 1:1"
stack unix deny unix "$LID_OPEN"
check "a second attempt on the same handle (sudo's retry) is what asks again" \
  "$(probe --user fingerprint-test-nobody --tty /dev/pts/3 --attempts 2)" "$PAM_AUTH_ERR 2"

EXPECTED_ROWS=198

# --- the count this suite is documented as running ---------------------------
docs_claim() {
  local f="$REPO_ROOT/$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-sudo-fprint-gate.sh\` ($EXPECTED_ROWS checks"
}

printf '\nthe count this suite is documented as running\n'
check "docs/guide.md says $EXPECTED_ROWS checks" "$(docs_claim docs/guide.md)" 1
check "a documented file that cannot be read is not a pass" \
      "$(docs_claim no/such/file.md)" "cannot read no/such/file.md"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
