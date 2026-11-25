# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-25

The first release: a fingerprint for `sudo` and `sudo -i` that comes only after the
password, on Ubuntu 26.04 with sudo-rs and gdm3.

### Added

- **The stanza and the gate.** `/etc/pam.d/sudo-fingerprint` checks the password first. Only
  after it fails does `fingerprint-should-offer` decide whether to offer the reader: for sudo
  or sudo-i, a local account, a real terminal and every lid open.
- **The gate fails closed.** Only its exit 0 offers the reader. A gate that skips, is missing,
  is not executable or crashes leaves the reader out.
- **Install-time checks.** Before any write, `sudo-fprint-gate.sh` checks the stanza
  statically: every control field must be one libpam knows, and every jump must land exactly
  one rule past `pam_fprintd`. It then runs the stack through the real libpam, once with a
  correct password and once with a wrong password and stand-ins for the gate and the reader.
  `--check` runs the same checks against the installed files.
- **The stock fprintd profile, refused.** The install refuses, and `--check` fails, when any
  PAM service other than `gdm-fingerprint` and this stanza runs `pam_fprintd`.
- **The early password check has no `nullok`.** An empty password never passes it, and an
  account with an empty password is left to `common-auth`.
- **The skipped auth chain must be known.** A correct password at the stanza ends the auth
  chain. The install refuses, and `--check` fails, when anything after the stanza's include in
  `sudo` or `sudo-i` holds an auth module that would then be skipped, such as `pam_faillock`.
  That covers `common-auth` and every file an `@include`, `auth include` or `auth substack`
  brings in. The same goes for an include that cannot be followed.
- **`--greeter-password-only`, opt-in.** It turns the fingerprint off at the login screen
  only, so the GNOME keyring unlocks at login.
- **The worktree guard.** The install refuses to run from a linked git worktree, or from a
  submodule inside one.
- **`--remove`.** It restores every edited file byte for byte.

[0.1.0]: https://github.com/ZviBaratz/sudo-fprint-gate/releases/tag/v0.1.0
