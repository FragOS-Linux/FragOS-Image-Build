FROM archlinux:latest

ENV LANG=C.UTF-8
ENV TZ=UTC

RUN pacman -Syu --noconfirm \
    arch-install-scripts \
    btrfs-progs \
    sudo \
    util-linux \
    git \
    xz \
    gawk \
    gnupg \
    openssh \
    nano \
    systemd \
    grub \
    efibootmgr \
    dosfstools \
    e2fsprogs \
    rsync \
    parted \
    shadow \
    mkinitcpio \
    base-devel


COPY scripts/build.sh /workdir/build-image.sh
RUN chmod +x /workdir/build-image.sh

WORKDIR /workdir
