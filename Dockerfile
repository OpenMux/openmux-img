# rpi-image-gen build container for OpenMux (CM5, Debian Trixie minbase).
#
# Bump RPI_IMAGE_GEN_REF (the commit) to track a new rpi-image-gen release;
# see README "Bumping the rpi-image-gen ref".
#
# The engine is built from source inside the image (its install_deps.sh
# recipes build genimage, bdebstrap, mmdebstrap, etc.), so this first build
# is slow; afterwards it is cached as the docker image.
FROM debian:trixie

ARG RPI_IMAGE_GEN_REF=3e10411

ENV DEBIAN_FRONTEND=noninteractive
# genimage's build tools are only needed while it compiles; keep them in the
# final image only because re-running install_deps.sh must stay possible.
# NOTE: we do NOT run `rm -rf /var/lib/apt/lists/*` here. install_deps.sh
# (next step) runs a bare `apt install` against these lists and does not
# `apt-get update` itself; deleting them makes every later install fail with
# "Unable to locate package <x>". We clean the lists once, at the very end.
RUN apt-get update && apt-get -y --no-install-recommends install \
        git ca-certificates curl \
        build-essential autoconf automake libtool autopoint flex gettext pkgconf make \
        python3 python3-yaml python3-debian python3-jsonschema python3-pip \
        # dpkg-architecture is a BINARY shipped by dpkg-dev, not its own
        # package (same convention as the engine's depends: dpkg-dev).
        dpkg-dev debian-archive-keyring \
        binfmt-support qemu-user-static \
        podman uidmap dbus-user-session \
        zip dosfstools e2fsprogs rsync grep mtools pv btrfs-progs \
        dctrl-tools uuid-runtime fdisk cryptsetup xz-utils \
        openssl

WORKDIR /opt

# Pin the engine to an exact commit (see README for the bump procedure).
# `apt-get update` here re-fetches the index the first RUN left in place
# (it is still needed and not yet cleaned), because buildkit layers commit
# the filesystem as-is. This keeps the layer self-contained if the base
# layer image is rebuilt on its own.
RUN apt-get update && \
    git clone https://github.com/raspberrypi/rpi-image-gen.git /opt/rpi-image-gen && \
    cd /opt/rpi-image-gen && \
    git checkout "$RPI_IMAGE_GEN_REF" && \
    ./install_deps.sh && \
    ln -s /opt/rpi-image-gen/rpi-image-gen /usr/local/bin/rpi-image-gen && \
    rm -rf /var/lib/apt/lists/*

# OpenMux source tree is mounted at /src by build.sh (the repo root).
WORKDIR /src
