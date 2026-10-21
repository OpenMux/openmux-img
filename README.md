# openmux-img

OpenMux image builds for the **Raspberry Pi Compute Module 5 (BCM2712)**,
produced from source with
[rpi-image-gen](https://github.com/raspberrypi/rpi-image-gen) inside a
pinned, reproducible Docker container.

One entry point — `./build.sh` — produces **two** images:

| Image | Name | What it is |
|---|---|---|
| Target | `openmux-cm5.img` | The installable device image. Accounts, APT repo and packages come from the customer **build spec**. |
| Install medium | `openmux-install-medium-cm5.img` | A fixed factory USB appliance: root autologin (blank password) with a 9-option serial/tty menu; the pre-built target image is embedded in it. |

Typical flow: build both images → flash the **install medium** to a USB
stick → boot the CM5 from it → menu option 1 writes the target image to
eMMC → reboot into the target system.

## Quick start

```sh
cp buildspec.example.yaml my-customer.yaml   # then edit (accounts, keys, repo)
./build.sh --buildspec my-customer.yaml
# -> dist/openmux-cm5.img.xz
# -> dist/openmux-install-medium-cm5.img
```

Useful flags (see `./build.sh -h`):

- `--repo-uri <uri>` / `--repo-gpg <key>` — customer APT repository
  (substituted into the image; the GPG key is staged into the repo layer).
- `--target-image <path>` + `--skip-target` — embed a pre-built target
  image in the medium without rebuilding it.
- `--skip-install-medium` — build only the target.
- `--genpasswd '<pass>'` — print an SHA-512 hash for a `password_hash` field.
- `--docker-image <tag>`, `--force-docker`, `--rig-ref <ref>`, `--out <dir>`.

The build runs in the `openmux/img` Docker image (built from `Dockerfile`)
as a `--privileged` container; the repo is mounted at `/src`, the build spec
directory read-only. Building an arm64 rootfs on an amd64 host works via
qemu-user-static (binfmt is set up automatically).

## The customer build spec

`./build.sh --buildspec <file>` (template: `buildspec.example.yaml`).
Validated by `build/parse-buildspec.py` **before** anything is built; the
file is git-ignored (it carries credentials). `key_file` / `post_install`
paths are relative to the spec's own directory.

- `admin-user:` — the primary account, mapped 1:1 onto rpi-image-gen's
  built-in `user1` mechanism: `name`, `password` **or** `password_hash`
  (neither → locked account), `sudo` (`none`/`passwd`/`nopasswd`),
  `uid`/`gid`, `groups`, and SSH access via one inline `keys:` entry or a
  multi-line `key_file:` (several keys need the file form).
  `openmux` and `root` are reserved names.
- `users:` — optional list of additional accounts (home dir, own sudoers,
  keys; `uid`/`gid` are not settable here). Implemented as a generated
  source-tree customize hook that runs after all layers.
- `post_install:` — optional executable script run at build time with
  `$1` = chroot dir (materialized as a source-tree customize hook).
  The script itself runs on the BUILD HOST, so a shell redirection
  (`… > file`) executes OUTSIDE the chroot — write into the image with
  `echo hi | chroot "$1" sh -c 'cat > /etc/hi'` or a redirect inside
  `chroot "$1" sh -c '… > /etc/…'`.

## Repository layout

```
build.sh                    single outside-Docker entry point
Dockerfile                  build container, rpi-image-gen pinned (ARG RPI_IMAGE_GEN_REF)
buildspec.example.yaml      customer build spec template (git-ignored in production)
build/
  entry.sh                  in-container build flow (debs → overrides → both images)
  parse-buildspec.py        build spec → IGconf_* overrides + generated hooks
  make-deb.sh               package/*/ -> dist/pkgs/*.deb (dpkg-deb --root-owner-group)
config/
  openmux-base.yaml         shared: trixie-minbase base suite + image-rpios layout;
                            layer map: base + serial (one layer PER KEY - the
                            engine's layer: map has no list support)
  openmux-cm5.yaml          TARGET  (device rpi-cm5, no hardcoded accounts);
                            layer map: repo + packages + app (key order is the
                            execution order: repo before packages before app)
  openmux-install-medium.yaml  MEDIUM (root/blank factory appliance); layer map:
                            medium
layer/
  openmux-serial-console/   CM5 serial console: cmdline.d fragment (serial
                            console FIRST, tty1 kept) + config.txt append
                            (uart0/dtparam routing for the 40-pin PL011); login
                            via the getty-generator's serial-getty@ttyAMA0
  openmux-repo/             customer APT repo (DEB822 + GPG); clean no-op without a
                            configured URI (the medium never uses it)
  openmux-packages/         installs the local .debs (hardware, factory-tools) in the
                            target (a config-level packages: section does not exist in
                            the pinned engine; this is the documented mechanism)
  openmux-app/              distro packages (curl, git) + custom-repo packages list
  openmux-install-medium/   factory tuning + embedding the target image + menu deb;
                            .d/overlay/ carries root autologin drop-ins and
                            /root/.bash_profile (runs the menu)
hooks/                      source-tree hooks (auto-discovered, run after all layers);
                            build-time hook materialized by the parser is git-ignored
package/
  openmux-hardware/         udev rules (incl. /dev/serial0 bridge), hw-detect service
  openmux-factory-tools/    eeprom/serial factory utilities
  openmux-install-menu/     the factory boot menu (menu option 9 toggles overlayroot
                            by editing cmdline.txt directly - minbase has no raspi-config)
device/openmux/.keep        (source-root placeholder; the CM5 device layer is the
                            engine's built-in rpi-cm5)
```

## How it maps onto rpi-image-gen

- Configs select `layer.base: trixie-minbase` (the engine's Debian trixie
  multiarch-minimum suite: systemd, openssh-server, timesyncd, rpi
  firmware/skel layers) plus `image.layer: image-rpios` (VFAT boot + ext4
  root, genimage).
- The device layer is the engine's built-in `rpi-cm5` (`device.layer:
  rpi-cm5`; `class: cm5`).
- The target's primary account uses the engine's native `user1` variables
  (`IGconf_device_user1*`, `IGconf_ssh_pubkey_user1`) emitted from the
  build spec — the engine's `device-user-admin`,
  `device-user-credentials` and `openssh-server` layers do the rest.
- Layer local `.deb` installation uses the engine's documented
  customize-hook mechanism (as in `examples/debstore`).
- `layer:` maps are **one layer per key** (scalar values only) - the engine's
  `collect_layers` appends each value verbatim; a YAML list becomes one
  literal string and fails with "Layer not found". The final layer set is
  the union of the base + child keys; dependency order is completed by the
  pipeline, but same-phase ordering follows the key sequence.
- mmdebstrap runs layer **customize-hooks with `sh -c` (dash)** - keep them
  dash-compatible (no arrays, no `[[ ]]`). Source-tree `hooks/` are executed
  directly (shebang honoured), so the parser-generated user hook may use
  bash via its `#!`.
- The config-level `packages:` section is not read by the engine in this
  ref; layer-local debs therefore install from a customize-hook (the
  `examples/debstore` pattern).

## Bumping the rpi-image-gen ref

`Dockerfile` pins the engine to a commit via
`ARG RPI_IMAGE_GEN_REF` (currently `3e10411`). To bump:

1. `./build.sh --rig-ref <new-sha>` (or edit the Dockerfile), which rebuilds
   the container — including the engine's `install_deps.sh` toolchain
   (genimage, bdebstrap, mmdebstrap, …).
2. Re-run the verification checklist below before trusting the new ref.
3. Update `ARG RPI_IMAGE_GEN_REF` in `Dockerfile` to make it permanent.

## Verification

- **Unit (fast):** `python3 build/parse-buildspec.py <spec> <outdir>` —
  spec validation + generated-hook rendering.
- **Config/metadata (fast, needs a reference clone of the engine):**
  `rpi-image-gen metadata --lint <layer>.yaml` and `rpi-image-gen config
  --write-to` for each config.
- **Full:** `./build.sh --buildspec <spec>` — both images are
  produced in `dist/`. Boot test on real CM5 hardware: serial console
  115200 8N1 on `ttyAMA0` (the medium autologins as root into the menu;
  the image is then written to eMMC and the device reboots into the
  target, where the build spec's accounts are active).

## Design notes / caveats

- **Serial console.** `console=serial0,115200` on the CM5 is the PL011
  (`ttyAMA0`). The console token set is guaranteed by a static
  `for/linux-base/cmdline.d` fragment shipped in the layer
  (`-console=* +console=serial0,115200`): the engine assembles
  `cmdline.txt` from the fragment files of the build plan during the preimage
  phase, which is why editing `cmdline.txt` in a customize-hook is a dead end
  (the file is re-generated afterwards). The fragment deliberately ends up with
  **serial as the only `console=` token**. The LAST `console=` parameter is the
  device that becomes `/dev/console`, and the initramfs `init` and PID 1 log
  *only* there: with the engine default `console=serial0,115200 console=tty1`
  the boot log looked fine on serial and then jumped to HDMI exactly when the
  initrd ran (that is when `vc4-kms-v3d` first creates a visible framebuffer).
  Rather than keep `tty1` as an earlier token - which would still duplicate the
  kernel log onto an HDMI port this appliance does not debug over - it is
  dropped: `/dev/console` can then never be the framebuffer. No `console=tty1`
  also means no `getty@tty1` (systemd's `getty-generator` only walks active
  kernel consoles), so HDMI shows nothing after the boot log; that is intended
  for a headless device. The install medium still gets its on-screen menu
  because `openmux-install-medium` enables `getty@tty1.service` explicitly. If
  a bench ever needs VT output, add `console=tty1` at the END of the boot
  partition's `cmdline.txt`. **Plan order, not the fragment's contents, is what
  makes the strip work**: fragments are applied in build-plan order and the
  family-base layer (`rpi-device-base`) contributes the default
  `console=serial0,115200 console=tty1 root=ROOTDEV fsck.repair=yes rootwait`.
  While `openmux-serial-console` required only `rpi-boot-firmware` it was
  planned *before* the family defaults, so `-console=*` had nothing to remove
  and `console=tty1` was appended right after it (its `console=serial0,115200`
  was dropped as a duplicate, which made the fragment look like it was being
  honoured). Two commits changing the fragment were therefore complete no-ops
  and the shipped `cmdline.txt` kept `tty1` last. `X-Env-Layer-Requires:
  rpi-boot-firmware,rpi-device-base` is what makes the override land, and
  `om-verify.sh` asserting exactly one `console=` token is what catches it if
  the ordering is ever broken again. `config.txt` has no fragment mechanism
  either: a **late preimage runner hook** (`hooks/late/preimage20-config.txt`
  in the layer `.d/`) appends `enable_uart=1` plus the `dtparam=uart0*`
  routing lines (from `config-append.txt`) to the template
  `rpi-boot-firmware` installed in the customize phase; late hooks run after
  every layer's step hooks/overlays for the phase, so the append survives
  into the boot vfat.
  The `dtparam` lines are what actually pin the console to `ttyAMA0` (the
  40-pin PL011) on the CM5: a BCM2712 would otherwise route the debug
  console to a debug UART such as `ttyAMA10` that the CM5's pin header does
  not expose. Login comes from systemd's getty-generator
  (`serial-getty@ttyAMA0`) — no hand-enabled getty, so there is no
  double-instance. `earlycon` is deliberately not used.
  Ordering constraints (both verified against the generated build plan):
  the layer must sort AFTER `rpi-boot-firmware` (config.txt append, above)
  and each config's `image:` section must come AFTER `device:` (the image
  layer's `-root=*`/`root=…` cmdline fragment must apply last, replacing the
  `root=ROOTDEV` placeholder).
- **`/dev/serial0`.** Stock minbase has no udev rule for it;
  `openmux-hardware` ships `99-openmux-serial0.rules`
  (SYMLINK for `ttyAMA0`) because the factory menu references `/dev/serial0`.
- **The medium never uses the customer APT repo.** It is a fixed factory
  appliance; `openmux-repo` is only selected by the target, so the medium
  does not need a repo URI or GPG key (the repo layer is a clean no-op
  without a configured URI regardless).
- **Install menu is neutral.** The `openmux-install-menu` deb must never
  contain autologin drop-ins or `/root/.bash_profile` — those belong to
  the `openmux-install-medium` layer overlay (checked by `make-deb.sh`).
- **Secrets.** The build spec (and its keys) is mounted read-only into the
  container as files; nothing credential-based is passed on argv/env.
  Build specs are git-ignored by pattern; only `buildspec.example.yaml`
  is committed.
- **Partition sizes** (boot 200%, root 300%) cap the root at 3 GiB —
  raise `root_part_size` in `config/openmux-base.yaml` if the package set
  grows beyond that.
- **Inline layer hooks MUST sit under `mmdebstrap:`.** A top-level
  `customize-hooks:` in a layer body is silently ignored by the parser —
  the hook simply never runs and nothing reports it (both
  `openmux-serial-console` and `openmux-repo` had this; it stayed hidden
  until the built image was inspected). Every hook-carrying layer here is
  nested accordingly.
- **Inline `mmdebstrap: customize-hooks` do NOT get `$LAYER_DIR`.** The
  runner only exports `LAYER_DIR`/`LAYER_NAME`/... to *per-layer runner hooks*
  (`<layer>.d/hooks/**`), not to bdebstrap's inline customize-hooks, where
  `$LAYER_DIR` expands to empty. If a hook needs to reach files the layer
  ships, use a runner hook (`hooks/late/preimageNN-…` etc.), not an inline
  one. `openmux-serial-console`'s `config.txt` append moved to a late hook for
  exactly this reason.
- **Transient `apt-get update` signature errors.** If essential dies with
  `sqv ... was created after the --not-after date`, the container clock
  briefly trailed the mirror's InRelease re-signing window; re-run the
  build — it is not a reproducible failure. Check `date` in both host and
  container if it ever recurs.
