# sudo-fprint-gate: the guide

The fingerprint reader is wired in without ever putting a fingerprint wait in front of a
password. That is the one hard requirement, and it decides where the reader is used and where it
is not.

| Surface | Lid open | Lid closed (docked) |
|---|---|---|
| Lock screen (GDM's own) | touch **or** type, at the same time | type |
| Login screen at cold boot | GDM's default; password only with `--greeter-password-only` | the same |
| `sudo` / `sudo -i` in a terminal | type the password, **or** press Enter on the empty prompt, then touch | type the password; Enter just asks again |
| `sudo` with no terminal (cron, background jobs, an agent's shell tool) | password only | password only |
| GNOME admin dialogs, `pkexec`, `run0`, `su`, TTY login, ssh | password only (untouched) | password only |

## Set it up

You need `fprintd` and `libpam-fprintd`, which Ubuntu installs by default, python3, and a
terminal of your own.

1. **Open a root shell in a second tab first** (`sudo -i`) and leave it open. It is the safety
   net if anything in the PAM stack goes wrong.
2. From a clone of this repository, run `./sudo-fprint-gate.sh`, or
   `./sudo-fprint-gate.sh --greeter-password-only` to also keep the login screen password-only.
   It prints what it installs and finishes with the same verdict as `--check`. From a linked
   git worktree, or a submodule inside one, it refuses unless you set
   `SUDO_FPRINT_GATE_ALLOW_WORKTREE=1`.
3. Enrol two fingers. Use **Settings → System → Users → Fingerprint Login**, or run
   `fprintd-enroll -f right-index-finger`, then `fprintd-enroll -f left-index-finger`. Lift
   fully between touches and shift a little each time. Confirm each finger with
   `fprintd-verify -f <finger>`: with no `-f`, it checks only the first finger enrolled. sudo
   accepts any of them.
4. Try it with `sudo -k; sudo true`. Press Enter at the password prompt, and touch the reader
   when it asks.

The lock screen needs nothing beyond step 3. A greeter change takes effect at the next cold
boot.

## Using it

- **sudo asks for the password first, and it works at once.** To use the reader instead, press
  Enter on the empty prompt (a wrong password does the same). sudo then says "Place your finger
  on the fingerprint reader".
- **Ctrl+C at the finger prompt:** sudo asks for the password again.
- **Each detour costs one of sudo's three tries.** Ctrl+C, a finger that fails twice, and an
  Enter while docked each end that try, and sudo's next try asks for the password again.
  Nothing re-asks inside a single try: `common-auth` re-checks the same password, as
  "The stanza, through the real libpam" below shows.
- **Docked, the reader is never offered:** with the lid closed, Enter on the empty prompt just
  uses up that try, and sudo asks again.
- **The lock screen takes either one, whichever comes first.**
- **Each decision is logged** with the reason: `journalctl -t sudo-fprint-gate`. Expect lines
  such as `offer: lid open, terminal attached`, `skip: lid closed` and `skip: no terminal`.
- **Each switch to the reader logs one `pam_unix` "authentication failure"** in the journal,
  because the empty password really did fail. That is expected.

## Check, remove, repair

```bash
./sudo-fprint-gate.sh --check    # read-only, no sudo; exit 1 on any drift
./sudo-fprint-gate.sh --remove   # takes it all out; the edited files return byte-identical
```

`--check` verifies the installed state, not the install's exit status:

- The gate and the stanza are root-owned regular files, byte-identical to this checkout.
- `sudo` and `sudo-i` include the stanza exactly once, immediately before
  `@include common-auth`.
- **The installed stanza's control flow is right, read statically.** Every control field is
  one libpam knows, and every numeric jump lands exactly one rule past `pam_fprintd`.
- **The installed sudo stack loads through the real libpam and accepts a correct password.**
  This catches a stanza that matches its checkout but cannot be parsed: one misspelled keyword
  makes libpam refuse every sudo.
- **With a wrong password, the installed stack reaches the reader only when the gate offers,
  and never authenticates.** Stand-ins replace the gate (one that offers, one that skips, a
  missing one) and the reader (one that records being reached). A matching finger must
  authenticate.
- **The auth chain after the stanza runs only modules a password checked first may skip.** A
  correct password at the stanza ends the auth chain, so a lockout (`pam_faillock`) or a second
  factor anywhere after its include would be passed over: in `common-auth`, later in `sudo` or
  `sudo-i`, or in any file they include. The install refuses, and `--check` fails, on anything
  outside the known set, and on any include it cannot follow.
- The greeter: when this tool's lines are there, they are the only setting of the key, and gdm
  has recompiled them. Without `--greeter-password-only` the greeter is not this tool's.
- **No effective PAM service except `gdm-fingerprint` and this stanza runs `pam_fprintd`.** This
  last check is the requirement, as a check. The stock `pam-auth-update --enable fprintd` puts
  the reader in front of the password in `common-auth`, which means every service.

The install runs the same static and libpam checks on the stack it *would* leave, and writes
nothing if any of them fails.

**After a `sudo-common` or `gdm3` upgrade, run `--check`.** `/etc/pam.d/sudo` and `sudo-i` are
conffiles, so an upgrade that ships a new one asks whether to keep yours. Taking the maintainer's
version only drops the include, and sudo simply goes back to password-only. Re-run the installer
to put it back.

**If `--check` says sudo "refuses everyone"**, either the stanza is gone while `sudo` still
includes it, or libpam cannot load the stack. Either way every sudo fails before it asks for
anything. **If it says the control flow is wrong**, a wrong password may reach the reader where
it must not, or authenticate outright. Either way, polkit is untouched, so take the stanza out
of sudo from a GNOME dialog:

```bash
pkexec sed -i '/^@include sudo-fingerprint$/d' /etc/pam.d/sudo /etc/pam.d/sudo-i
```

## What is not covered

- **GNOME's admin dialogs, and so a password manager's "unlock with biometrics" that goes
  through polkit.** That dialog runs one serial PAM conversation and will not submit an empty
  password (below), so a fingerprint there could only come first, and wait.
- **Browser passkeys (WebAuthn).** Linux has no biometric platform authenticator.
- **`su`, TTY login and ssh.** They stay on the password. `pam_fprintd` refuses remote sessions
  anyway.
- **"Storage full" on enrolment.** A match-on-chip sensor keeps templates on the chip, and old
  prints (from another operating system, say) can fill it. Delete them with
  `fprintd-delete $USER` and enrol again.

## Design and evidence

### Why it cannot be parallel in sudo or polkit

`pam_fprintd(8)`, LIMITATIONS: "The PAM stack is by design a serialised authentication, so it
is not possible for pam_fprintd to allow authentication through passwords and fingerprints at
the same time. It is up to the application using the PAM services to implement separate PAM
processes." GDM does exactly that: `gdm-password` and `gdm-fingerprint` are separate stacks,
which is why the lock screen takes either.

sudo and polkit run one stack each. Third-party modules that claim to run both at once in one
stack do not belong in a root authentication path:

- **pam-fprint-grosshack**, a fork of `pam_fprintd`, was last updated 2022-07-27. Its author
  warns: "This code may have major security flaws or other unforeseen bugs."
- **pam-any** runs the methods in parallel threads. It had an authentication bypass open until
  2026-05 ("Always unlocks with no checks"), and its safe rewrite is unmerged.
- **The newer parallel modules found in 2026** carry no licence, and push keystrokes into the
  terminal with `TIOCSTI`.

The usual answer, which the Arch wiki gives, is to put the **password first** and have an empty
Enter move on to the fingerprint. That is what sudo does here. It cannot work in GNOME's polkit
dialog: GNOME Shell 50's `ui/components/polkitAgent.js` enables OK only on a non-empty entry
(line 156), and `_onEntryActivate` returns on an empty one (line 220). A Shell extension could
lift that, but `AuthenticationDialog` is not exported (line 26, against `export
{AuthenticationAgent as Component}` at line 472). It would have to patch a live instance at
runtime and be re-checked on every GNOME release. So polkit stays password-only.

### Why sudo is gated

**CVE-2024-37408 concerns a fingerprint offered with no "security attention mechanism".** Any
process that runs sudo can then claim a touch the user meant for something else. The fprintd
maintainers name GDM and GNOME's polkit dialog as the frontends that do ensure attention, and
treat sudo as a policy decision for distributions and administrators. Neither fprintd 1.94.5 nor
Ubuntu's package changes this.

`fingerprint-should-offer` therefore offers the reader only when all four of these hold:

- **The service is `sudo` or `sudo-i`.**
- **`PAM_USER` is a local account** (a line of `/etc/passwd`). The stanza's first check is
  `pam_unix`, which knows only local accounts. For a domain (SSSD) account, a *correct*
  password fails it, and only `common-auth`'s `pam_sss` would accept that password, after the
  reader. That is a fingerprint wait in front of a correct password, which this skip prevents.
- **`PAM_TTY` is a real terminal** (`/dev/pts/N` or `/dev/ttyN`). A tty-less sudo cannot read a
  password, and without this gate that failure falls straight through to a fingerprint wait.
  That is the CVE's shape, exactly.
- **Every lid reads open.** Docked, the reader cannot be touched, and `pam_fprintd` would only
  wait out its timeout. No lid at all, or one it cannot read, counts as unknown.

Anything the gate cannot determine counts as a skip, because the password always works.

**The terminal check is a papercut guard, not a boundary.**

- **It stops the accidental case.** An agent's shell tool, cron and background jobs have no
  terminal, and their sudo never reaches the reader.
- **It does not stop a process that sets out to get a terminal.** `script`, `expect` or a tmux
  pane each present a real `/dev/pts/N`. From there, an empty password sent down that pty
  reaches the reader, with the prompt shown where you cannot see it.
- **Nothing here can tell those terminals apart.** logind registers no session for a terminal
  emulator's pty or a `script` one, so to logind they look the same.
- **What bounds the risk:** such a process runs as you, so it could already take your sudo by
  aliasing it in your shell. With the password first, it must also fail a password before the
  reader is even asked.

If that trade is wrong for you, `./sudo-fprint-gate.sh --remove` restores password-only sudo,
and the lock screen keeps the fingerprint.

### Why the gate fails closed

The stanza runs the gate as
`auth [success=ignore default=1] pam_exec.so quiet quiet_log /usr/local/libexec/fingerprint-should-offer`.
Only the gate's exit 0 is a success, which the stanza ignores, so `pam_fprintd` runs next.
Every other result takes `default=1` and jumps over the reader: an exit 1, and equally a gate
that is missing, not executable, killed by a signal or exiting with any other status. The
state table runs each of those through the real libpam (below).

An earlier shape of this gate had it the other way round: exit 0 meant "skip", and the stanza
read `[success=1 default=ignore]`. That shape **failed open**. A missing gate made `pam_exec`
fail, which it read as "offer", and so the install had to put the gate in before the stanza.
This release turned the gate around. A shape that fails open needs an install order; this one
needs none.

### The stanza, through the real libpam

```
auth  sufficient                    pam_unix.so
auth  [success=ignore default=1]    pam_exec.so quiet quiet_log /usr/local/libexec/fingerprint-should-offer
auth  sufficient                    pam_fprintd.so max-tries=2 timeout=10
```

These are libpam's semantics, measured rather than believed. `pam_start_confdir()` (Linux-PAM
1.4 or later) runs a stack from any directory unprivileged. The state table copies the
**installed** files there, with `pam_permit` and `pam_deny` standing in for a right or wrong
password or finger, and the installed gate still deciding. The results:

| case | result |
|---|---|
| right password first | success; the gate never runs |
| wrong password, terminal, lid open, finger right | success (`offer:` logged) |
| finger wrong, a later `common-auth` module accepts | success: a failed finger decides nothing |
| lid closed, finger *would* match, `common-auth` refuses | refused: the finger was never asked |
| lid closed, a later `common-auth` module accepts | success: the skip's jump poisons nothing |
| no terminal, finger *would* match | refused (`skip: no terminal`) |
| stanza missing while sudo includes it | `pam_start` fails with `PAM_ABORT` (26) before any prompt |
| gate missing, not executable, killed, or exiting 2; finger *would* match | refused: the finger was never asked |
| **real** `pam_unix` in both places, finger wrong | refused after **one** prompt |
| the same, with two `pam_authenticate` calls on one handle | refused after **two** prompts |

"A later `common-auth` module accepts" is a stand-in for `pam_sss` accepting a domain account.
It is **not** a second chance at a typed password. The last two rows, with the real
`pam_unix`, show why: `pam_unix` reads the password through `pam_get_authtok()`, which returns
the one already typed, so `common-auth` re-checks that same typo or empty Enter and fails it.
The new prompt after Ctrl+C, a failed finger, or a docked Enter is **sudo-rs retrying the whole
`pam_authenticate`**, and libpam clears the cached password between attempts. Each detour
therefore costs one of sudo's tries, and with `passwd_tries=1` a failed finger would end sudo.

The stanza-missing row sets the install order: the stanza, then the includes. Removal runs the
other way.

**The shape, measured.** The table also runs purpose-built stanzas, with a wrong password, an
Ubuntu-shaped `common-auth` whose every credential check fails, and a reader stand-in that only
records being reached:

| stanza | result |
|---|---|
| the earlier shape, the gate saying skip | refused, reader not reached |
| the earlier shape, its one jump three rules too far (`success=4`) | **authenticated with no credential** |
| the earlier shape, gate missing | refused, **reader reached** (fails open) |
| this shape, the gate offering | refused, reader reached |
| this shape, the gate skipping, missing or not executable | refused, reader not reached |
| this shape with a control-field typo (`defualt=1`), the gate skipping | refused, **reader reached** |

The second row is why every jump is checked statically. A jump that overshoots past
`common-auth`'s `requisite pam_deny` lands on its `required pam_permit`, and sudo succeeds with
no credential at all. The last row is why the install probes with a wrong password. libpam
reads an unknown key as an error on that one line, every action of which then becomes "bad".
The line no longer jumps, so a skip still reaches the reader. A correct-password probe returns
at the first rule and cannot see it.

### What the install checks before writing

1. **Statically.** Every rule in the stanza is a plain `auth` rule. Every control is one of
   libpam's four keywords, or a `[...]` field of return codes and actions that pam.conf(5)
   lists. The stanza runs `pam_fprintd` exactly once, and every numeric jump lands exactly one
   rule past it. A mutation sweep in the state table changes the jump to 0, 2, 3, 4 and 5; the
   install refuses each.
2. **A correct password, through libpam.** `scripts/pam-stack-probe.py` runs the sudo stack the
   install *would* leave: this machine's PAM files, the stanza from the checkout, and `sudo`
   with the include. `pam_permit` stands in for `pam_unix` and for the gate, and `pam_deny` for
   `pam_fprintd`. The install refuses unless that authenticates. One misspelled control keyword
   (`sufficent`) makes libpam refuse the whole stack with `PAM_PERM_DENIED`, correct password
   or not. Copying it would lock everyone out of sudo while `--check`'s byte comparison
   against the same checkout stayed green.
3. **A wrong password, through libpam.** The same stack, with its control fields untouched:
   - `pam_deny` stands in for `pam_unix`, and for `common-auth`'s `pam_unix` and `pam_sss`;
   - the gate's path runs a stand-in that offers, one that skips, or a path with nothing there;
   - `pam_exec` runs a reader stand-in that records being reached.

   A gate that offers must reach the reader, and one that skips or is missing must not.
   Nothing may authenticate, except a matching finger, which must. The stand-ins run from the
   installer's temporary directory. A `TMPDIR` mounted `noexec` is reported as such, never
   read as a pass.

**Everything after the stanza's include must be a module a password checked first may skip.**
The stanza's `pam_unix` is `sufficient`, so a correct password there ends the auth chain. It
never reaches a `pam_faillock preauth` lockout, a second factor, or anything else that
`pam-auth-update` later adds to `common-auth` or that `sudo` and `sudo-i` list after it. The
known set is `pam_unix`, `pam_sss` (the gate skips non-local accounts), `pam_deny`,
`pam_permit` and `pam_cap`.

The installer reads that whole chain for `sudo` and `sudo-i`: as the install would leave them,
and in `--check` as they are installed. It follows every `@include`, `auth include` and
`auth substack`, resolving each name as libpam does (`/etc/pam.d`, then `/usr/lib/pam.d`), and
holds every auth rule to the known set, `-auth` rules too. It refuses what it cannot follow:

- an include it cannot open or read;
- a loop;
- includes nested deeper than the 15 levels libpam loads;
- a line continued with a backslash.

Rules of other types are left alone, since an `account include` brings in no auth rule. Each
of these behaviours of libpam was measured with the probe on Linux-PAM 1.7.0:

- the depth limit;
- the case-insensitive `AUTH`, `INCLUDE` and `@INCLUDE`;
- the joined backslash line;
- the include filtered to its own type.

**The stanza's `pam_unix` has no `nullok`.** On Ubuntu, `common-auth`'s does, so an account
with an empty password can authenticate there. The stanza's early check does not carry that
over: an empty password never passes it. So it accepts no password that `common-auth`'s own
check would refuse, and an account with an empty password is left to `common-auth`.

`quiet_log` is on the pam_exec line because every skip is a non-zero exit, which pam_exec would
otherwise log as a failed command. The gate logs its own reason.

**The stanza is called `sudo-fingerprint`, with no "password" in its name, on purpose.** Common
secret guards in `.gitignore` files, such as `**/*password*`, silently ignore any such file.

### Why the greeter can be password-only, and the lock screen is not

A fingerprint login leaves the GNOME keyring locked, and with it any tokens and browser keys it
holds. Once you are logged in the keyring stays unlocked, so the lock screen loses nothing.
`--greeter-password-only` is opt-in because it changes the login screen, which a sudo tool would
not be expected to touch.

**One key can split the two.** GNOME Shell's `ShellUserVerifier` (`gdm/util.js`, lines 185 and
858) reads `org.gnome.login-screen enable-fingerprint-authentication` through a plain
`Gio.Settings`:

- **The greeter** runs as the gdm user and reads GDM's compiled defaults.
- **The unlock dialog** runs in your session and reads your own dconf, where the key stays at
  its default, `true`.

**How the greeter's defaults are built on Ubuntu:** `/etc/gdm3/greeter.dconf-defaults` is
symlinked as `/usr/share/gdm/dconf/90-debian-settings`. `/usr/share/gdm/generate-config` compiles
that directory into `/var/lib/gdm3/greeter-dconf-defaults`. It runs as gdm.service's
`ExecStartPre` and as its `ExecReload`, so `systemctl reload gdm.service` recompiles and
nothing more. A gdm restart would end the session, so the installer only ever reloads.

An install without the flag takes this tool's greeter lines out again, so the install always
leaves the greeter as the last command asked.

### The gate's inputs

`pam_exec(8)` builds the child's environment from the PAM environment list plus the PAM items,
and warns that "the user can have control over the environment". Through the real libpam
(2026-11-13), a caller's own `PAM_TTY=/dev/pts/77` and `FOO=bar` did **not** reach the child. It
saw only `PAM_USER`, `PAM_TYPE`, `PAM_SERVICE` and the `PWD` that dash sets. The gate still sets
`PATH` and `IFS` itself, and its test seams (`--lid-dir`, `--passwd-file`, `--log-file`) are
arguments, which in PAM a root-owned file fixes.

### sudo-rs specifics

- **sudo-rs #1307:** `sudo -n` used to print the fingerprint prompt. Fixed in 0.2.9.
- **sudo-rs #1308, fixed by PR #1322:** Ctrl+C at the fingerprint prompt now falls back to the
  password, as classic sudo's does, by masking SIGINT around PAM.
- **Not documented anywhere, so measured:** sudo-rs 0.2.13 passes an *empty* password through
  to PAM. An empty Enter therefore reaches the reader.
- **sudo-rs prints nothing between the two password checks.** A typo therefore looks like a
  password that was accepted and then asked for a finger. `pam_unix`'s "authentication
  failure" line in the journal is how to tell.
- **No terminal, no PAM at all for the password:** with no tty, sudo-rs says "A terminal is
  required to authenticate" and exits at once.
- **`PAM_TTY`:** upstream sudo-rs 0.2.13 sets it from stdin's terminal. Ubuntu's
  0.2.13-0ubuntu1.1 backports a fix to how it is computed (LP: #2153817). What a terminal with
  stdin redirected reports under that build has not been measured.

### Live verification

The live steps below were run on 2026-11-13 on the tested-on machine (README), against this
tool's predecessor. That predecessor had the same stanza order and the same four conditions,
but the gate's exit codes the other way round, and its stanza's `pam_unix` carried `nullok`.
Steps 6 to 8 and 11 must be re-run against 0.1.0, whose gate fails closed and logs under the
`sudo-fprint-gate` tag.

1. **Install:** `./sudo-fprint-gate.sh --check` exits 0 at the end of the install.
2. **Enrolment:** both index fingers enrol (`enroll-completed`). About half the touches came
   back `enroll-retry-scan`, which is normal for this sensor. `fprintd-verify` with no `-f`
   checks only the first enrolled finger, so it reads a correct touch of the other finger as
   `verify-no-match`. Name the finger with `-f`.
3. **The typed password comes first:** `sudo -k; sudo true` with the password typed succeeds
   at once. The gate never runs, and nothing is logged.
4. **An empty Enter reaches the reader:** "Place your finger on the fingerprint reader", then
   the right index finger, succeeds. sudo accepts **any** enrolled finger.
5. **A typo, then Ctrl+C:** typing `x` and Enter brings up the finger prompt, and Ctrl+C brings
   back a password prompt that the real password then passes. That prompt is sudo-rs's next
   try.
6. **No terminal:** from a process with no controlling terminal, `sudo true` fails at once with
   "A terminal is required to authenticate". The journal says
   `skip: no terminal (service=sudo … tty=none …)`.
7. **`PAM_TTY` is sudo-rs's own:** every terminal run logs `tty=/dev/pts/N`.
8. **A forged `PAM_TTY=/dev/pts/9` with no terminal** fails the same way, and still logs
   `tty=none`.
9. **polkit is untouched:** `pkexec true` shows GNOME's dialog with the password field ready at
   once, and no fingerprint text.
10. **The lock screen** (Super+L) unlocks with a touch. It needed nothing beyond enrolment.
11. **Docked, with the lid closed:** an empty Enter uses up that try with no finger prompt, sudo
    asks for the password again, and the journal logs `skip: lid closed`. With
    `--greeter-password-only`, the next cold boot's login screen is password-only and the
    keyring unlocked.

### Designs not taken

- **`pam-auth-update --enable fprintd`.** It puts the reader first in `common-auth`, and so in
  front of every password: sudo, su, login, `gdm-password`, polkit. `--check` fails on it.
- **Fingerprint first in sudo or polkit, behind a lid check.** It still blocks the password for
  the timeout whenever the lid is open.
- **The gate rebuilt on stock modules.** `pam_succeed_if` for the service and the terminal,
  `pam_localuser`, and `pam_exec` running `grep` on one lid file can do the gate's job with no
  script. An independent review ran that stanza through libpam and found three costs:
  - it needs five jumps instead of one, and each jump that overshoots authenticates with no
    credential;
  - the lid file has to be rendered per machine;
  - most of the reason log is lost.

  The script, inverted to fail closed, keeps one fixed jump and one log line per decision.
- **pam-fprint-grosshack and pam-any.** See above.
- **A GNOME Shell extension that lets the polkit dialog submit an empty Enter.** See above.
- **"Any wrong text + Enter" in polkit.** A typo would then wait on the reader in a dialog with
  no Ctrl+C.

### Tests

State table: `scripts/test-sudo-fprint-gate.sh` (198 checks, hermetic, CI job `state-tables`).
It covers the following:

- **The gate**, run as pam_exec runs it: `env -i` plus the PAM items, with no PATH. Local
  accounts come from a passwd fixture.
- **The stanza**, exactly as shipped.
- **The installer**, under a prefix. A `sudo` stub runs `install`, `mv` and `rm` for real but
  confined to the prefix, and models `systemctl reload gdm.service` as gdm's `generate-config`.
- **Every `--check` drift and every install refusal**, byte for byte against Ubuntu 26.04's own
  `sudo`, `sudo-i`, `polkit-1` and `greeter.dconf-defaults` text and `pam-auth-update`'s
  `common-auth`, `common-account` and `common-session` files, including their tabs and trailing
  spaces. Both greeter states are covered, with and without `--greeter-password-only`.
- **The auth chain after the stanza.** The rows cover:
  - an extra auth rule in `sudo` or in `sudo-i`;
  - `@include`, `auth include` and `auth substack` of a file that holds one;
  - `-auth` and upper-case `AUTH`;
  - an include found only in the vendor directory, and one by absolute path;
  - a missing, unreadable, looping or too-deeply nested include.

  The cases that must still install are covered too: includes nested exactly as deep as libpam
  loads, an `/etc/pam.d` file shadowing its vendor twin, an `account include`, and an auth rule
  *before* the stanza.
- **The static check, the correct-password probe and the wrong-password probes.** They are
  run against a misspelled keyword, a control-field typo, an extra rule before the reader, and
  every jump from 0 to 5.
- **The worktree guard**, from a linked worktree and from a submodule inside one.
- **The installed stack through the real libpam** (the tables above), using the same probe the
  install uses, including every way the gate can fail closed.

No row needs a fingerprint reader, `pam_fprintd` or a real lid, so the whole table runs in CI.
It takes about three minutes, most of it the libpam probes that each install and `--check`
runs.

### Sources

- [pam_fprintd(8)](https://www.mankier.com/8/pam_fprintd), LIMITATIONS
- [CVE-2024-37408](https://bugzilla.redhat.com/show_bug.cgi?id=2291438) and the
  [fprintd maintainers' write-up](https://hackmd.io/@3v1n0/HJtDCtdBC)
- sudo-rs [#1307](https://github.com/trifectatechfoundation/sudo-rs/issues/1307) and
  [#1308](https://github.com/trifectatechfoundation/sudo-rs/issues/1308)
- [pam-fprint-grosshack](https://gitlab.com/mishakmak/pam-fprint-grosshack) and
  [pam-any](https://github.com/ChocolateLoverRaj/pam-any)
- [linux-pam #301](https://github.com/linux-pam/linux-pam/issues/301): parallel modules would
  need a redesign of the configuration format
- [Arch wiki, fprint](https://wiki.archlinux.org/title/Fprint): password first, an empty
  Enter for the reader
- [GNOME: disallow fingerprint login](https://help.gnome.org/system-admin-guide/login-fingerprint.html)
  and [Debian: fingerprint and the keyring](https://wiki.debian.org/SecurityManagement/fingerprint%20authentication)
- [The lid-closed sudo wait](https://community.frame.work/t/when-in-clamshell-mode-how-do-you-disable-fingerprint-prompts-for-sudo/21295)
