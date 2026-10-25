# openmux-img

OpenMux image builds for the **Raspberry Pi Compute Module 5 (BCM2712)**,
produced from source with
[rpi-image-gen](https://github.com/raspberrypi/rpi-image-gen) inside a
pinned, reproducible Docker container.

One entry point — `./build.sh` — produces **two** images:

| Image | Name | What it is |
|---|---|---|
| Target | `openmux-cm5.img` | The installable device image. Accounts, APT repo and packages come from the customer **build spec**. |
| Install medium | `openmux-install-medium-cm5.img` | A fixed factory USB appliance: root autologin (blank password) with an 8-option serial/tty menu; the pre-built target image is embedded in it. Its root filesystem is **read-only by default**, so nothing a session writes on the stick survives a reboot (menu option 8 is the escape hatch). |

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
                            .d/overlay/ carries root autologin drop-ins,
                            /root/.bash_profile (runs the menu) and an
                            initramfs-tools hook that gives the initrd
                            grep/sed and a mount that knows --move (overlayroot
                            needs all three); .d/for/linux-base/
                            cmdline.d/30-openmux-overlay adds the
                            overlayroot=tmpfs parameter that makes the stick's
                            root read-only by default, and
                            .d/hooks/late/postimage30-overlayroot-
                            check fails the build by reading the finished
                            boot.vfat
hooks/                      source-tree hooks (auto-discovered, run after all layers);
                            build-time hook materialized by the parser is git-ignored
package/
  openmux-hardware/         udev rules (incl. /dev/serial0 bridge), hw-detect service
  openmux-factory-tools/    eeprom/serial factory utilities
  openmux-install-menu/     the factory boot menu (option 8 toggles the stick's
                            read-only root by rewriting the ONE line of
                            cmdline.txt - minbase has no raspi-config, and the
                            parameter itself is an image default from the layer
                            fragment above; option 3 is a boot-order/bootloader
                            sub-menu that shows the current BOOT_ORDER and the
                            running vs. on-stick bootloader version before any
                            SPI write, and refuses downgrades, frozen modules
                            and unverifiable writes)
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

## Factory and field-service tools

`openmux-factory-tools` installs to `/opt/openmux-factory-tools` on **both**
images: the install medium's menu drives the same files a technician uses by
hand, so there is one behaviour to learn. Menu option 2 is a sub-menu
(console serial, adapter serial, identify, test console, test adapter); the
same steps exist as commands:

Every FTDI part on this hardware is an FT4232H with the same `0403:6011`, and an
unprogrammed chip reports **no serial at all**, so nothing here decides what a
device is by its USB strings. Role comes from the topology:

| what | serial | where it sits | ports |
|---|---|---|---|
| the console's own FTDI chips (permanently present) | `OMC000000-A`/`-B` | internal paths `2-1.1`, `2-1.2` | 8, flat: `/dev/openmux/port1..8` |
| an EX-12 adapter (plug-in) | `OMX000000-A`/`-B`/`-C` | 3 chips behind the card's own hub, typically `2-1.4` → `.2/.3/.4` | 12, per card: `/dev/openmux/OMX000042/port1..12` |

`OMC` is **OpenMux Console** (the chassis' own chips) and `OMX` is **OpenMux
eXtention** (a card). The digit run after the prefix is left unspecified on
purpose: nothing in the tools, the udev rules or the boot script enforces a
width, so a four-digit and a six-digit serial are equally valid and name the same
kind of thing. The numbers throughout this file are examples, not a required
shape. Policing the length would make an odd-looking chassis unprogrammable,
which is the wrong trade for cosmetics.

`99-openmux-ftdi.rules` (shipped by `openmux-hardware`) is what turns a serial
into a port number: chip `A`→1-4, `B`→5-8, `C`→9-12, i.e.
$port = 4 \times chip\_index + interface + 1$, and it splits the serial at its
first dash, so **a serial base must never contain `-`**. The rules also accept a
third console chip (`OMC…-C` → ports 9-12) even though this board fits two.

A prefix is matched in **three places across two packages**, and they must move
together: the rules above, `openmux-detect-hardware.sh` (which finds the console
chip with a shell `case "$serial" in OMC*-A)`), and `PREFIX_*_DEFAULT` in
`scan_ftdi.py`. Change one and nothing errors — the flash succeeds, the chip
re-enumerates with a serial no rule claims, and the board simply has no
`/dev/openmux` ports. `om-verify.sh` asserts the three agree.

```
scan-ftdi-adapters.py              # what is on the bus, which is console vs card, what is programmed
  --serials                        # one programmed base per line + the ports it covers
  --format tsv                     # machine-readable, what the menu parses
  --snapshot f --diff-with f       # unplug/replug and it names the hub that changed
  --check-base OMX000042           # would the rules match this? no hardware needed
  --verify OMX000042               # numbering audit of a programmed card (see below)
program-ftdi-internal.py OMC000001 # exactly the two console chips -> OMC000001-A/-B
program-ftdi-external.py OMX000042 # all three chips of the one card on the bus (--adapter 2-1.4)
run-board-tests.sh --port-base /dev/openmux/OMX000042 --pairs card
```

Write order after plugging in a virgin card, and why each step is there:

```
scan-ftdi-adapters.py                    # shows the hub and that the chips have no serial
program-ftdi-external.py OMX000042  # prints the 3 chips and the console chips it will NOT touch
#            ...then unplug the card and plug it back: the EEPROM is only read at plug-in
scan-ftdi-adapters.py --verify OMX000042   # port numbers checked against sysfs, with no wiring at all
run-board-tests.sh --port-base /dev/openmux/OMX000042 --pairs card
```

`run-board-tests.sh` prints the patch-cord plan **before** running anything, so
the plugs go in from the same screen, and it runs the numbering audit first
(`--no-audit` to skip). Pair profiles: `console` = 2-3, 4-5, 6-7, 8-1 and `card`
= 2-3, 4-5, 6-7, 8-9, 10-11, 12-1 — both rings, both deliberately crossing the
chip seams, because the seams are where a wrong numbering shows up.
`--pairs 2:3,4:5` is accepted for a one-off; `legacy-console` reproduces the old
1-2, 3-4, 5-6, 7-8. Every tool also takes `--devices-dir`/`--sys-tty-dir`, which
is how the offline tests drive them against a fake sysfs tree with no hardware.

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
- **Read-only root on the install medium.** The medium boots with
  `overlayroot=tmpfs`: the initramfs mounts the stick's ext4 read-only at
  `/media/root-ro` and puts a tmpfs-backed overlay over `/`, so an operator's
  `apt install`, `passwd`, hand edits, freshly generated SSH host keys and the
  whole journal are gone at the next reboot and the same stick presents the same
  state to the next console. Like the console tokens above, the parameter comes
  from a `cmdline.d` fragment (`30-openmux-overlay` in `openmux-install-medium`)
  - which is also the only place it could reliably live: `linux-base` applies the
  fragments from a **late preimage** hook, i.e. after every layer's customize
  hooks and deb installs, so nothing later can overwrite it, and at boot the
  kernel command line outranks `/etc/overlayroot.conf` anyway
  (`conf-hooks.d/90-kernel` is the last config hook). That file is therefore
  left stock, and `overlayroot-chroot` keeps working as the way to inspect a
  running stick's real root.
  Two parameters are deliberately left OUT. `ro` is the tempting one, and does
  the opposite of what it looks like: the lower layer is read-only because
  Debian's initramfs `export`s `readonly=y`, while an `ro` on the command line
  sets overlayroot's `cmdline_ro`, which remounts the **overlay** read-only -
  apt, `passwd` and the menu's EEPROM staging would then fail mid-session. And
  `:recurse=0` would look necessary to keep `/boot/firmware` writable, but
  overlayroot only recurses into block-device fstab entries and passes `vfat`
  through as an unsupported filesystem (replaying the shipped
  `overlayrootify_fstab` over this image's fstab with `recurse=1` and `0`
  produced byte-identical output).
  Installing the `overlayroot` package is necessary but NOT sufficient,
  and neither shortfall shows up in the config: both leave an ordinary
  read-write boot with `overlayroot=tmpfs` plainly in `/proc/cmdline`,
  because overlayroot's failure path is `fail(){ log_fail "$@"; exit 0; }`.
  Its initramfs script *is* in the initrd, and first in `init-bottom/ORDER`,
  but it picks the overlay driver by grepping `/proc/filesystems` twice
  (`grep -q "\t$module$"` before and after `modprobe -qb`), and **this initrd
  has no `grep`**: the image is minbase with `--no-install-recommends`,
  and `BUSYBOX=auto` only pays off through a busybox-initramfs hook,
  which is not among this image's hooks (`dmsetup fsck keymap klibc-utils
  kmod overlayroot raspi-firmware-fsck resume thermal udev`). Clearing
  that meets the next one: the initrd's `mount` is klibc's, which takes
  no long options, so `mount --move "$ROOTMNT" "$root_ro"` - the call
  that installs the read-only lower layer - fails the same silent way.
  `.d/overlay/etc/initramfs-tools/hooks/openmux-overlayroot-tools` therefore
  copies `grep`, `sed` and `rm` in and replaces `mount` with util-linux's,
  rather than adding busybox for three call sites - which would not settle it
  anyway, since busybox's mount takes `-o move` and has no `--move`. Raspberry
  Pi forum thread 398145 ("Get overlayroot to work on a rpi-image-gen image
  for RPI5", also `trixie-minbase`) reaches the same diagnosis and does
  install busybox. Because the entire failure is one console line, the
  build checks the artifact: `postimage30-overlayroot-check` reads the
  finished `boot.vfat` and runs `lsinitramfs`, plus an unpack of the
  initrd, through the rootfs just built, failing unless the initrd the
  firmware loads contains `scripts/init-bottom/overlayroot`, `bin/grep`,
  `bin/sed`, `overlay.ko` and a mount that can do `--move` - a name in a
  listing says nothing about which implementation it is. Postimage is the
  only phase that can: `linux-base` assembles the `cmdline.d` fragments
  from a **late preimage** hook and `rpi-linux-base` installs the result
  over `/boot/firmware/cmdline.txt`, and both layers sort after this
  one, so a preimage hook sees only the template (`root=ROOTDEV`) and can
  only reject it. On a booted stick, overlayroot keeps its own record at
  `/run/initramfs/overlayroot.log` (it survives `pivot_root`): `Unable to
  find driver/module. searched: overlay overlayfs` is the missing-`grep`
  case, `failed to move root away from` the missing-`--move` case, and a
  `configured root with 'tmpfs'` line means it worked.
  The guard reads `boot.vfat` through `mdu` only, in a new session (`setsid`). A
  stray prompt is a hang rather than an error, because mtools asks on `/dev/tty`,
  and neither `</dev/null` nor `timeout` ends one. `build.sh` runs the container
  without `-t`, so a build has no terminal to answer on. `mdu` is the only verb
  that neither asks nor misreports: `mmd` exits 0 for a *missing* member, `mdir`
  pads and 8.3-abbreviates names so they cannot be matched, and `mtype` exits 0
  for a directory. Loop-mounting would sidestep all of it (`build.sh` passes
  `--privileged`), but a mount leaked by a killed hook leaves a loop device
  attached to the image file.
  `cmdline.txt` has to stay a SINGLE line, because the firmware appends the file to
  the kernel command line and ignores everything after the first line - so a toggle
  that `>>` appends a second line is silently a no-op in both directions. The
  verifier pins the token, the one-line shape and the absence of `ro`; that a
  booted stick really is overlaid can only be seen on the stick itself -
  `findmnt /` must report `overlay` and `findmnt -o OPTIONS /media/root-ro` must
  contain `ro`.
- **`/dev/serial0`.** Stock minbase has no udev rule for it;
  `openmux-hardware` ships `99-openmux-serial0.rules`
  (SYMLINK for `ttyAMA0`) because the factory menu references `/dev/serial0`.
- **A loopback test cannot prove port numbering.** Pairwise loopback proves that
  two names are wired together; it says nothing about whether the chip behind a
  name is the one the name promises. Program chip `A` with `-B` and every port of
  a card shifts by four: the ring still passes, and the port labelled 5 is
  physically interface 0 of the chip the rules call `A`. That is why
  `scan-ftdi-adapters.py --audit/--verify` exists, why it derives the expectation
  from sysfs (which USB interface each `portN` symlink actually resolves to)
  rather than from the serial, and why `run-board-tests.sh` runs it before asking
  anyone to fit a plug. A numbering failure is reported as not a wiring fault.
- **Console chips and adapter chips are told apart by path, never by content.**
  Both are `0403:6011`, both take the same EEPROM format, and an unprogrammed chip
  has no serial to filter on, so the only stable discriminator is where the chip
  hangs: `2-1.1`/`2-1.2` are the console's, and an adapter's chips are the group
  of more than one FTDI under a hub of its own. The guards are therefore
  bidirectional and live in `scan_ftdi.py`, which the scanner, both flashers and
  the runner all import: `program-ftdi-external.py` refuses a hub containing a
  console chip, and `program-ftdi-internal.py` refuses a sibling FTDI that is not
  one of the console's paths even when it is named explicitly on the command line
  — the failure being guarded against is an operator pointing the console tool at
  a card because the card was the only thing they could see. There is deliberately
  no `--force` that bypasses this: `--internal PATHS` re-declares the paths, which
  keeps the guard armed against whatever the new declaration says.
- **Flashing an EEPROM re-enumerates the whole hub**, so a device list taken
  before the first write is stale by the second write: bus number and devnum
  change under you and `ftdi_eeprom` addresses a device by exactly those two.
  Both flashers therefore re-scan, re-run the guards, re-check the serial they saw
  at plan time and only then read bus/devnum, immediately before each invocation
  (`reassert()`), and stop if the chip they are about to write is not the one they
  described to the operator.
- **`ftdi_eeprom` is a `Depends` of `openmux-factory-tools`**, which is where a
  binary some of its scripts exec belongs: the distro ships it as `ftdi-eeprom`
  (1.5-10, source `libftdi1`, trixie main), and a dependency rides along with the
  package onto the target, onto the medium and onto any unit a technician installs
  the deb on by hand. Listing it per-image would have taken two entries - the
  medium selects no package layer at all - and both would have been able to drift
  from the scripts that need it. That the deb's `Depends` are really resolved at
  build time is not assumed: `usbutils` and `python3-serial` are in no layer's
  package list and appear in both images' manifests anyway - read back out of the
  built target with `debugfs -R "dump /var/lib/dpkg/status"`, because that install
  hook runs `apt-get install` with no `apt-get update` first. Worth re-checking on
  a fresh build: `libftdi1-2` is already installed at the version `ftdi-eeprom`
  needs (1.5-10, pulled in by `flashrom`), and being the same source package, its
  presence shows the apt lists that build used contain that package set.
  Hyphenated package name, underscored binary - the mismatch is why this sat
  unconfirmed, while the flashers printed the right package name all along and
  both images shipped a flasher that could only refuse to run.
- **`sudo` is a dependency too, and was undeclared until it was audited.** Both
  flashers build `["sudo", "ftdi_eeprom", ...]` unconditionally, so the binary has
  to exist even when the tools already run as root - which is how the medium runs
  them, where `sudo` would only ever be a no-op. Its `Priority` is `optional` and
  no other dependency of the package pulled it: both images carried it purely
  because the generator's `device-user-admin` layer (the customer admin account)
  lists it. A tool's ability to flash therefore rested on an unrelated layer's
  package list - true in every build to date, and invisible if that ever changed.
  The other externals are `python3` (also `optional`; previously guaranteed only
  *transitively*, via `python3-serial`'s `Depends: python3:any`, now stated
  outright) and `bash` + `coreutils`, deliberately left undeclared because Debian
  marks both `Essential: yes` - required to be present, so a dependency would add
  nothing. `usbutils` goes the other way: declared, never execed, because nothing
  runs `lsusb` now that the scanner reads sysfs. It stays because it is what gets
  typed next to a USB problem, not because a script needs it.
- **Flashing needs ftdi_sio off the chip**, per that tool's own man page, and every
  interface of an already-programmed chip is bound to it by default. This kernel
  ships `ftdi_sio.ko.xz` modular, so the chip can be released - but this has not
  been exercised on hardware, so treat it as the first thing to check if a flash
  cannot open a chip, not as a solved step.
- **A serial prefix is matched in three places, shipped by two packages.**
  `99-openmux-ftdi.rules` (as `OMC[0-9]*-A`), `openmux-detect-hardware.sh` (as a
  shell `case` looking for `OMC*-A`) and `PREFIX_*_DEFAULT` in `scan_ftdi.py`.
  They are not derived from each other and nothing errors when they disagree: the
  flash succeeds, the chip re-enumerates with a serial no rule claims, and the
  unit has no `/dev/openmux` ports at all - which looks like a dead card. The
  prefix lives in a conffile, so `om-verify.sh` reads it back out of all three
  shipped files and asserts they agree, rather than restating a literal.
- **Menu structure is asserted, not assumed.** `om-verify.sh` pins the top-level
  menu at its option count, and the serial sub-menu nests under option 2 for that
  reason: adding a top-level entry means updating that pin. The sub-menu never
  passes `--yes` to a flasher (the confirmation belongs to the operator) and never
  runs a test after programming (the card has to be replugged first, so any port
  it looked at would be the pre-flash one).
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
