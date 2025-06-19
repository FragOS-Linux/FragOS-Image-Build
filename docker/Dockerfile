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

RUN useradd -m builder && echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

WORKDIR /mnt

CMD ["/mnt/scripts/build.sh"]
