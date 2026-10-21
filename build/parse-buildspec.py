#!/usr/bin/env python3
"""parse-buildspec.py - translate the customer OpenMux build spec into the
rpi-image-gen overrides needed to build the target image.

The customer provides ONE YAML file (see buildspec.example.yaml). This tool
maps its `admin-user` section 1:1 onto the generator's built-in `user1`
mechanism (nothing else - unknown keys are rejected), renders the generated
`customize94-openmux-users` hook for the optional additional `users:` list,
and checks the optional `post_install` script (which entry.sh copies into the
source-tree hooks dir as customize95-openmux-postinstall).

Usage:
  parse-buildspec.py <buildspec.yaml> <outdir> [--cwd REPO_ROOT] [--repo-uri URI]

  <buildspec.yaml>   the customer build spec
  <outdir>           directory to write into: overrides.env,
                     hooks/customize94-openmux-users (only if users:),
                     keys/<admin>.pub (only if admin-user has inline keys)
  --specdir DIR      directory `key_file` entries are relative to (the build
                     spec's own directory; defaults to the spec's dir)
  --cwd REPO_ROOT    only used if you pass ABS path semantics; the emitted ssh
                     var is the key_file path as it must appear to the build
  --repo-uri URI     also emit IGconf_om_repo_uri (openmux-repo layer)

Exit codes: 0 ok, 1 spec error (message on stderr), 2 usage error.
The spec is fully validated BEFORE anything is written.
"""

import argparse
import os
import re
import stat
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: PyYAML is required (python3-yaml)", file=sys.stderr)
    sys.exit(2)

# --- constants -------------------------------------------------------------

# The generator's device-user-credentials layer enforces this exact regex on
# the plaintext user1pass; mirror it so the customer sees the error at parse
# time (the layer would reject it later anyway).
PASS_RE = re.compile(r"^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]{8,}$")

# key_file entries in the spec are relative to the BUILD SPEC's directory
# (customer keys live next to the spec). SPECDIR is set in main(); the
# ABS path that ends up in overrides.env must be the one valid at BUILD
# time (entry.sh passes the in-container buildspec dir, so the resolved
# path is valid inside the container).
SPECDIR = os.getcwd()
KEY_FILES = {}  # ctx -> absolute resolved key_file path
# Where INLINE keys are materialized (<outdir>/keys, set in main()). Public
# keys only; lives under work/ (git-ignored) and entry.sh removes it after
# the build.
KEYDIR = None

# Reserved names: 'openmux' is kept for a future OpenMux system account,
# 'root' is not a regular account.
RESERVED = {"openmux", "root"}

# The complete set of options the generator's user1 mechanism can set.
# admin-user MUST stay within this set (the parser rejects anything else).
ADMIN_OPTS = {"name", "password", "password_hash", "sudo", "uid", "gid",
              "groups", "keys", "key_file"}
# Options the generated-hook path (users:) accepts. It is deliberately smaller:
# uid/gid stay on the built-in path only.
USER_OPTS = {"name", "password", "password_hash", "sudo", "groups",
             "keys", "key_file"}

UID_MIN, UID_MAX = 1000, 65533
SUDO_MODES = {"none", "passwd", "nopasswd"}
# OpenSSH public key line: "<type-token> <base64-blob> [comment]".
# Type tokens: ssh-rsa, ssh-dss, ssh-ed25519, ecdsa-sha2-nistp{256,384,521},
# plus the sk- secured-key prefixes.
SSH_KEY_RE = re.compile(
    r"^(sk-)?(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(?:256|384|521))\s+[A-Za-z0-9+/=]+"
)


# --- helpers ---------------------------------------------------------------

def fail(msg):
    print(f"ERROR: buildspec: {msg}", file=sys.stderr)
    sys.exit(1)


def as_str_list(v, ctx):
    """Accept a YAML list of strings (or a single string) -> list[str]."""
    if v is None:
        return []
    if isinstance(v, str):
        v = [v]
    if not isinstance(v, list):
        fail(f"{ctx}: must be a string or a list of strings")
    out = []
    for i, item in enumerate(v):
        if not isinstance(item, str) or not item.strip():
            fail(f"{ctx}[{i}]: entries must be non-empty strings")
        out.append(item)
    return out


def check_key(k, line):
    """One SSH public key line: type token + base64 blob (+ optional comment)."""
    if not k.strip():
        return
    if not SSH_KEY_RE.match(k.strip()):
        fail(f"key near line {line}: does not look like an OpenSSH public key: {k[:40]!r}...")


def keys_or_file(keys, key_file, ctx):
    """Return the resolved list of key lines. key_file and keys are mutually
    exclusive; key_file may hold SEVERAL keys (one per line) and is resolved
    against SPECDIR (the build spec's directory)."""
    if key_file and keys:
        fail(f"{ctx}: use either 'keys' OR 'key_file', not both")
    if key_file:
        full = key_file if os.path.isabs(key_file) else os.path.join(SPECDIR, key_file)
        if not os.path.isfile(full):
            fail(f"{ctx}: key_file does not exist (relative to the build spec's directory): {key_file}")
        KEY_FILES[ctx] = full  # remember the resolved path for emission
        with open(full, encoding="utf-8") as f:
            raw = f.read()
        lines = [l for l in raw.splitlines() if l.strip() and not l.lstrip().startswith("#")]
        if not lines:
            fail(f"{ctx}: key_file has no key lines: {key_file}")
        for i, l in enumerate(lines, 1):
            check_key(l, f"{key_file}:{i}")
        return lines
    out = []
    for i, line in enumerate(keys, 1):
        check_key(line, f"line {i}")
        out.append(line)
    return out


def write_key_file(path, key_lines):
    """Write validated key lines (one per line) to `path`, return its ABS path.

    The generator's user1 ssh hook branches on `[ -f "$IGconf_ssh_pubkey_user1" ]`
    and cats the whole file into authorized_keys, so a file we generate here is
    consumed exactly like a customer-supplied `key_file` - which is how MORE
    THAN ONE inline key reaches the built-in user1 account (the fallback branch
    is a single `echo`, i.e. one key at most).

    Public keys only, hence 0644: the build hook reads it container-side."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for k in key_lines:
            f.write(k.rstrip("\n") + "\n")
    os.chmod(path, 0o644)
    return os.path.abspath(path)


def groups_list(g, ctx):
    if g is None:
        return None
    names = as_str_list(g, ctx)
    pat = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")
    for n in names:
        if not pat.match(n):
            fail(f"{ctx}: invalid group name: {n!r}")
    return ",".join(names)


def validate_account(acct, ctx, opts, default_sudo="none"):
    """Common per-account validation.
    Returns (name, sudo, groups, keylines, password|None, password_hash|None)."""
    if not isinstance(acct, dict):
        fail(f"{ctx}: must be a mapping")
    unknown = set(acct) - opts
    if unknown:
        fail(f"{ctx}: unknown option(s) {sorted(unknown)}; allowed: {sorted(opts)}")

    name = acct.get("name")
    if name is not None:
        if not isinstance(name, str) or not re.match(r"^[a-z_][a-z0-9_-]*$", name):
            fail(f"{ctx}.name: invalid login name: {name!r} (lowercase, must start with a letter)")
    if name in RESERVED:
        fail(f"{ctx}.name: '{name}' is reserved (not allowed on any account)")

    pw = acct.get("password")
    ph = acct.get("password_hash")
    if pw is not None and ph is not None:
        fail(f"{ctx}: use either 'password' OR 'password_hash', not both")
    if pw is not None:
        if not isinstance(pw, str) or not PASS_RE.match(pw):
            fail((f"{ctx}.password: does not meet the policy "
                  "(>=8 chars incl. upper, lower, digit and one of @$!%*?&)"))
    if ph is not None and not isinstance(ph, str):
        fail(f"{ctx}.password_hash: must be a string")

    sudo = acct.get("sudo", default_sudo)
    if sudo not in SUDO_MODES:
        fail(f"{ctx}.sudo: must be one of {sorted(SUDO_MODES)}, got {sudo!r}")

    groups = groups_list(acct.get("groups"), f"{ctx}.groups")

    key_lines = keys_or_file(as_str_list(acct.get("keys"), f"{ctx}.keys"),
                             acct.get("key_file"), ctx)
    return name, sudo, groups, key_lines, pw, ph


def sh_quote(s):
    """Single-quote a value for the generated sh hook (values are pre-validated
    to be shell-safe; this adds the quotes)."""
    return "'" + s.replace("'", "'\\''") + "'"


# --- main ------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("buildspec")
    ap.add_argument("outdir")
    ap.add_argument("--specdir", default=None,
                    help="base dir for key_file/post_install paths (default: "
                         "the spec's own directory)")
    ap.add_argument("--repo-uri", default=None)
    args = ap.parse_args()

    if not os.path.isfile(args.buildspec):
        fail(f"buildspec not found: {args.buildspec}")
    try:
        with open(args.buildspec, encoding="utf-8") as f:
            spec = yaml.safe_load(f) or {}
    except yaml.YAMLError as e:
        fail(f"invalid YAML: {e}")
    if not isinstance(spec, dict):
        fail("top level must be a mapping")

    unknown_top = set(spec) - {"admin-user", "users", "post_install"}
    if unknown_top:
        fail(f"unknown top-level key(s) {sorted(unknown_top)}")

    # key_file / post_install paths are customer paths, relative to the build
    # spec's own directory.
    global SPECDIR, KEYDIR
    SPECDIR = os.path.abspath(args.specdir or os.path.dirname(args.buildspec) or ".")
    os.makedirs(os.path.join(args.outdir, "hooks"), exist_ok=True)
    KEYDIR = os.path.join(args.outdir, "keys")

    # ---- admin-user (the generator's built-in user1 slot) -------------------
    admin = spec.get("admin-user") or {}
    if not isinstance(admin, dict):
        fail("admin-user: must be a mapping")
    unknown = set(admin) - ADMIN_OPTS
    if unknown:
        fail(f"admin-user: option(s) {sorted(unknown)} are not settable by the "
             f"generator's user1 mechanism; allowed: {sorted(ADMIN_OPTS)}")

    name = admin.get("name", "admin")
    if not isinstance(name, str) or not re.match(r"^[a-z_][a-z0-9_-]*$", name):
        fail(f"admin-user.name: invalid login name: {name!r}")
    if name in RESERVED:
        fail(f"admin-user.name: '{name}' is reserved")

    if admin.get("password") is not None and admin.get("password_hash") is not None:
        fail("admin-user: use either 'password' OR 'password_hash', not both")
    if admin.get("password") is not None:
        pw = admin["password"]
        if not isinstance(pw, str) or not PASS_RE.match(pw):
            fail("admin-user.password: does not meet the policy "
                 "(>=8 chars incl. upper, lower, digit and one of @$!%*?&)")

    sudo = admin.get("sudo", "passwd")
    if sudo not in SUDO_MODES:
        fail(f"admin-user.sudo: must be one of {sorted(SUDO_MODES)}, got {sudo!r}")

    uid = admin.get("uid")
    if uid is not None:
        if not isinstance(uid, int) or not (UID_MIN <= uid <= UID_MAX):
            fail(f"admin-user.uid: must be an integer {UID_MIN}-{UID_MAX}")
    gid = admin.get("gid")
    if gid is not None:
        if not isinstance(gid, int) or not (UID_MIN <= gid <= UID_MAX):
            fail(f"admin-user.gid: must be an integer {UID_MIN}-{UID_MAX}")
    groups = groups_list(admin.get("groups"), "admin-user.groups")

    # Any number of inline keys is allowed: they are materialized into a
    # build-time key file below (see write_key_file), which the generator's
    # hook cat's just like a customer key_file.
    admin_keys = keys_or_file(as_str_list(admin.get("keys"), "admin-user.keys"),
                              admin.get("key_file"), "admin-user")

    # ---- users: (generated hook path) --------------------------------------
    users = spec.get("users") or []
    if users is None:
        users = []
    if not isinstance(users, list):
        fail("users: must be a list")
    seen = {name}  # admin-user.name is taken
    rendered_users = []
    for i, acct in enumerate(users):
        ctx = f"users[{i}]"
        n, su, gr, kl, pw, ph = validate_account(acct, ctx, USER_OPTS, default_sudo="none")
        if not n:
            fail(f"{ctx}.name: required for additional accounts")
        if n in seen:
            fail(f"{ctx}.name: '{n}' duplicates an existing account")
        seen.add(n)
        rendered_users.append((n, su, gr, kl, pw, ph, i))

    # ---- post_install -------------------------------------------------------
    post = spec.get("post_install")
    if post is not None:
        post_abs = post if os.path.isabs(post) else os.path.join(SPECDIR, post)
        if not isinstance(post, str) or not os.path.isfile(post_abs):
            fail(f"post_install: script not found (relative to the build "
                 f"spec's directory): {post!r}")
        if not os.access(post_abs, os.X_OK):
            fail(f"post_install: script is not executable: {post}")

    # ---- emit overrides.env + generated hook ---------------------------------
    env = []  # list of (key, value) in IGconf_* form
    env.append(("IGconf_device_user1", name))
    if admin.get("password") is not None:
        env.append(("IGconf_device_user1pass", admin["password"]))
    if admin.get("password_hash") is not None:
        env.append(("IGconf_device_user1passhash", admin["password_hash"]))
    env.append(("IGconf_device_user1sudo", sudo))
    if uid is not None:
        env.append(("IGconf_device_user1uid", str(uid)))
    if gid is not None:
        env.append(("IGconf_device_user1gid", str(gid)))
    if groups:
        env.append(("IGconf_device_user1groups", groups))
    if admin.get("key_file"):
        # The generator's ssh hook treats a PATH to a file specially: it cats
        # the whole file into authorized_keys (multi-key friendly). The hook
        # checks with [ -f <path> ], which is cwd-relative, so hand it the
        # ABSOLUTE resolved path (repo-root-relative key_file -> e.g.
        # /src/keys/my.pub in the container).
        env.append(("IGconf_ssh_pubkey_user1", KEY_FILES["admin-user"]))
    elif admin_keys:
        # Inline (one OR several keys): write them to <outdir>/keys/<name>.pub
        # and hand the generator that path, so every key lands in
        # authorized_keys via the hook's file branch. Materialized here, in the
        # emission section, so the spec stays fully validated before anything
        # is written. entry.sh removes the file after the build.
        env.append(("IGconf_ssh_pubkey_user1",
                    write_key_file(os.path.join(KEYDIR, f"{name}.pub"), admin_keys)))
    if args.repo_uri:
        env.append(("IGconf_om_repo_uri", args.repo_uri))

    with open(os.path.join(args.outdir, "overrides.env"), "w", encoding="utf-8") as f:
        for k, v in env:
            # Single-quote everything; ' must not appear in these values.
            if "'" in v:
                fail(f"internal: value for {k} contains a single quote")
            f.write(f"{k}='{v}'\n")

    if rendered_users:
        hook_path = os.path.join(args.outdir, "hooks", "customize94-openmux-users")
        lines = [
            '#!/bin/sh',
            '# GENERATED by build/parse-buildspec.py - do not edit.',
            '# Creates the additional accounts from the customer build spec',
            '# (users:). Runs on the build host as a source-tree customize',
            '# hook ($1 = chroot dir); auto-discovered by rpi-image-gen. Runs',
            '# after all layer hooks (incl. the built-in user1 setup) and',
            '# before the image is written.',
            'set -eu',
            '',
        ]
        for uname, su, gr, kl, pw, ph, _i in rendered_users:
            lines.append(f'# ---- {uname} ----')
            lines.append(f'chroot "$1" useradd -m -s /bin/sh {uname}')
            if gr:
                # Create any missing groups (as system groups), then add user.
                body = "for g in " + gr + "; do getent group \"$g\" >/dev/null " \
                       "|| groupadd -r \"$g\"; done; usermod -aG " + gr + " " + uname + ";"
                lines.append("chroot \"$1\" sh -c '" + body.replace("'", "'\\''") + "'")
            if pw is not None:
                lines.append(f'printf %s:%s\\n {sh_quote(uname)} {sh_quote(pw)}'
                             ' | chroot "$1" chpasswd')
            elif ph is not None:
                lines.append(f'printf %s:%s\\n {sh_quote(uname)} {sh_quote(ph)}'
                             ' | chroot "$1" chpasswd -e')
            # No password/hash -> account locked (created with ! in shadow);
            # that is the expected behaviour and is warned about by entry.sh.
            if su != "none":
                # Match the built-in user1 sudo handling: sudo group + drop-in.
                lines.append(f'chroot "$1" usermod -aG sudo {uname}')
                spec = f'{uname} ALL=(ALL) ' + (
                    'NOPASSWD:ALL' if su == "nopasswd" else 'ALL')
                lines.append(f'printf %s\\n {sh_quote(spec)}'
                             f' > "$1/etc/sudoers.d/openmux-{uname}"')
                lines.append(f'chmod 0440 "$1/etc/sudoers.d/openmux-{uname}"')
            if kl:
                lines.append(f'install -d -m 0700 "$1/home/{uname}/.ssh"')
                for k in kl:
                    lines.append(f'printf %s\\n {sh_quote(k)}'
                                 f' >> "$1/home/{uname}/.ssh/authorized_keys"')
                lines.append(f'chmod 0600 "$1/home/{uname}/.ssh/authorized_keys"')
                # chown by NAME must run IN the chroot: on the host the user
                # does not exist in /etc/passwd ("chown: invalid user").
                # (Explicit path - $HOME would expand against the HOST env.)
                # Trailing colon is REQUIRED: `chown user` sets the owner
                # ONLY and keeps the existing group (0 here, since the dir
                # and key were created by root host-side); `chown user:`
                # sets owner + the user's PRIMARY group.
                lines.append(f'chroot "$1" chown -R {uname}: /home/{uname}/.ssh')
            lines.append('')
        lines.append('# done')
        with open(hook_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(hook_path, 0o755)
        print(f"OK  (generated hook for {len(rendered_users)} extra user(s))")
    else:
        print("OK")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
