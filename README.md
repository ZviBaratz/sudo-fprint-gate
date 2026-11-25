# sudo-fprint-gate

A fingerprint for `sudo` that comes **after** the password, never in front of it.

sudo asks for your password as always, and a typed password works at once. Press Enter on the
empty prompt instead, and sudo offers the fingerprint reader. It offers the reader only when a
person is plainly there to touch it: sudo or `sudo -i`, a local account, a real terminal, and
the lid open.

Every other PAM service keeps the password alone: polkit's dialogs, `su`, TTY login and ssh.
The lock screen needs nothing from this tool, because GDM already offers the fingerprint
*beside* the password there.

## Why the password comes first

The usual setup, Ubuntu's `pam-auth-update --enable fprintd`, puts the reader **in front of
every password** on the machine. Every sudo then waits on the reader, even when you are about
to type the password. With the lid closed on a dock, that wait is a timeout you cannot cut
short.

PAM runs one stack per service, in order, and cannot ask for a password and a finger at the
same time (`pam_fprintd(8)`, LIMITATIONS). So one of the two has to come first. Here it is
the password.

## Threat model

**CVE-2024-37408.** A fingerprint offered with no "security attention mechanism" lets any
process that runs sudo claim a touch you meant for something else. It is unfixed upstream:
the fprintd maintainers treat it as a matter of configuration. This tool's answer is the gate,
`fingerprint-should-offer`. It offers the reader only for sudo or sudo-i, a local account, a
real terminal (`/dev/pts/N` or `/dev/ttyN`) and every lid open.

**The gate fails closed.** Only its exit 0 offers the reader. A gate that skips, is missing,
is not executable or crashes leaves the reader out, and sudo goes on to the password.

**The terminal check is a papercut guard, not a boundary.**

- A sudo with no terminal never reaches the reader: cron, a background job, or an agent's
  shell tool.
- A process that sets out to get a terminal does reach it. `script`, `expect` or a tmux pane
  each present a real `/dev/pts/N`, and an empty Enter sent down that pty reaches the reader
  with the prompt shown where you cannot see it.
- What bounds this: such a process already runs as you, so it could take your sudo by
  wrapping it in your shell. It must also fail a password before the reader is even asked.
- **Do not count on `sudo … </dev/null` to keep the reader out.** `PAM_TTY` is whatever sudo
  computes it to be. Ubuntu's sudo-rs 0.2.13 carries a backported change to that computation
  (LP: #2153817), so whether a terminal with stdin redirected still counts has not been
  verified here.

**A wrong control field in the stanza must not slip through.** One misspelled keyword in a
sudo stack refuses every sudo. A jump three rules too far lands on `common-auth`'s
`pam_permit` and authenticates with **no credential**. The install therefore checks the
stanza statically and through the real libpam, with a correct password and with a wrong one,
before it writes anything. `--check` does the same on the installed files.
[docs/guide.md](docs/guide.md) has the measurements.

## Supported platform

**Ubuntu 26.04 with sudo-rs and gdm3, only.** That is where it was built and measured:
sudo-rs 0.2.13, Linux-PAM 1.7.0, fprintd 1.94.5 and GNOME 50.

- **Fedora (authselect) and Arch (`system-auth`):** not handled. The installer edits Ubuntu's
  `/etc/pam.d/sudo`, `sudo-i` and `common-auth` layout and refuses anything else.
- **Classic sudo:** not verified. The empty-Enter path depends on sudo passing an empty
  password through to PAM. sudo-rs 0.2.13 does (measured); classic sudo has not been checked.
- **Laptops only.** The gate reads `/proc/acpi/button/lid/*/state`. With no lid, every sudo is
  a skip, and the reader is never offered.

## Install

You need `fprintd` and `libpam-fprintd` (Ubuntu installs both by default), python3, and a
terminal of your own: the installer calls `sudo` for each write.

1. **Open a root shell in a second terminal first** (`sudo -i`) and leave it open. It is your
   way back if anything in the PAM stack goes wrong.
2. Clone this repository and run the installer from the clone:

   ```bash
   git clone https://github.com/ZviBaratz/sudo-fprint-gate.git
   cd sudo-fprint-gate
   ./sudo-fprint-gate.sh                          # sudo only
   ./sudo-fprint-gate.sh --greeter-password-only  # also: no fingerprint at the login screen
   ```

   `--greeter-password-only` turns the fingerprint off at the login screen alone, so a
   login unlocks the GNOME keyring. The lock screen keeps the fingerprint.
3. Enrol a finger: **Settings → System → Users → Fingerprint Login**, or `fprintd-enroll`.
4. Try it: `sudo -k; sudo true`. Press Enter at the password prompt, then touch the reader.

Each of the gate's decisions is logged: `journalctl -t sudo-fprint-gate`.

## Check and remove

```bash
./sudo-fprint-gate.sh --check    # read-only, no sudo; exit 1 on any drift
./sudo-fprint-gate.sh --remove   # takes it all out; edited files return byte for byte
```

**Run `--check` after a `sudo-common` or `gdm3` upgrade.** `/etc/pam.d/sudo` and `sudo-i` are
conffiles, and taking the maintainer's version drops the include. That is safe, because sudo
just goes back to password-only. Re-run the installer to put the include back.

## Tested on

- **Machine:** ThinkPad X1 Carbon Gen 13, with a Synaptics Prometheus match-on-chip sensor
  (USB `06cb:0123`) driven by stock libfprint 1.95.
- **Software:** Ubuntu 26.04.1, GNOME Shell 50.1 and sudo-rs 0.2.13.

## Development

```bash
bash scripts/test-sudo-fprint-gate.sh   # the state table: hermetic, no sudo, no root
pre-commit run --all-files
```

The state table runs the installer under a prefix, with a confined `sudo` stub. It runs the
stanza through the real libpam with `pam_start_confdir` (Linux-PAM 1.4 or later), with stand-ins
for the reader. No row needs a fingerprint reader or root.

## Licence

GPL-2.0-or-later; see [LICENSE](LICENSE). That matches fprintd. Linux-PAM itself is
distributed under a BSD-style licence or, at your option, the GPL.
