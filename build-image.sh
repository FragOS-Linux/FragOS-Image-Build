#! /bin/bash

set -e
set -x

if [ $EUID -ne 0 ]; then
	echo "$(basename $0) must be run as root"
	exit 1
fi

BUILD_USER=${BUILD_USER:-}
OUTPUT_DIR=${OUTPUT_DIR:-}


source manifest

if [ -z "${SYSTEM_NAME}" ]; then
  echo "SYSTEM_NAME must be specified"
  exit
fi

if [ -z "${VERSION}" ]; then
  echo "VERSION must be specified"
  exit
fi

DISPLAY_VERSION=${VERSION}
LSB_VERSION=${VERSION}
VERSION_NUMBER=${VERSION}

if [ -n "$1" ]; then
	DISPLAY_VERSION="${VERSION} (${1})"
	VERSION="${VERSION}_${1}"
	LSB_VERSION="${LSB_VERSION}　(${1})"
	BUILD_ID="${1}"
fi

MOUNT_PATH=/tmp/${SYSTEM_NAME}-build
BUILD_PATH=${MOUNT_PATH}/subvolume
SNAP_PATH=${MOUNT_PATH}/${SYSTEM_NAME}-${VERSION}
BUILD_IMG=/output/${SYSTEM_NAME}-build.img

mkdir -p ${MOUNT_PATH}

fallocate -l ${SIZE} ${BUILD_IMG}
mkfs.btrfs -f ${BUILD_IMG}
mount -t btrfs -o loop,compress-force=zstd:15 ${BUILD_IMG} ${MOUNT_PATH}
btrfs subvolume create ${BUILD_PATH}

# copy the makepkg.conf into chroot
cp /etc/makepkg.conf rootfs/etc/makepkg.conf

# bootstrap using our configuration
pacstrap -K -C rootfs/etc/pacman.conf ${BUILD_PATH}

# copy the builder mirror list into chroot
mkdir -p rootfs/etc/pacman.d
cp /etc/pacman.d/mirrorlist rootfs/etc/pacman.d/mirrorlist

# copy files into chroot
cp -R manifest rootfs/. ${BUILD_PATH}/

mkdir ${BUILD_PATH}/override_pkgs
# Copy compiled pkgs
mkdir ${BUILD_PATH}/local_pkgs
cp -rv pkgs/*.pkg.tar* ${BUILD_PATH}/local_pkgs

if [ -n "${PACKAGE_OVERRIDES}" ]; then
	wget --directory-prefix=${BUILD_PATH}/override_pkgs ${PACKAGE_OVERRIDES}
fi

# chroot into target
mount --bind ${BUILD_PATH} ${BUILD_PATH}
arch-chroot ${BUILD_PATH} /bin/bash <<EOF
set -e
set -x

source /manifest

pacman-key --populate

echo "LANG=en_US.UTF-8" > /etc/locale.conf
locale-gen

# Disable parallel downloads
sed -i '/ParallelDownloads/s/^/#/g' /etc/pacman.conf

# Cannot check space in chroot
sed -i '/CheckSpace/s/^/#/g' /etc/pacman.conf

# update package databases
pacman --noconfirm -Syy

# Disable check and debug for makepkg on the final image
sed -i '/BUILDENV/s/ check/ !check/g' /etc/makepkg.conf
sed -i '/OPTIONS/s/ debug/ !debug/g' /etc/makepkg.conf

# install kernel package
if [ "$KERNEL_PACKAGE_ORIGIN" == "local" ] ; then
	pacman --noconfirm -U --overwrite '*' \
	/override_pkgs/${KERNEL_PACKAGE}-*.pkg.tar.zst
else
	pacman --noconfirm -S "${KERNEL_PACKAGE}" "${KERNEL_PACKAGE}-headers"
fi

# install local packages
pacman --noconfirm -U --overwrite '*' /local_pkgs/*
rm -rf /var/cache/pacman/pkg


# remove jack2 to prevent conflict with pipewire-jack
pacman --noconfirm -Rdd jack2 || true

# install packages
pacman --noconfirm -S --overwrite '*' --disable-download-timeout ${PACKAGES}
rm -rf /var/cache/pacman/pkg

# install flatpak packages
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
if [ -n "${FLATPAK_PACKAGES}" ]; then
    flatpak install -y --noninteractive flathub ${FLATPAK_PACKAGES}
fi


# Install the new iptables
# See https://gitlab.archlinux.org/archlinux/packaging/packages/iptables/-/issues/1
# Since base package group adds iptables by default
# pacman will ask for confirmation to replace that package
# but the default answer is no.
# doing yes | pacman omitting --noconfirm is a necessity
yes | pacman -S iptables-nft

# enable services
systemctl enable ${SERVICES}

# enable user services
systemctl --global enable ${USER_SERVICES}

# disable root login
passwd --lock root

# create user
groupadd -r autologin
useradd -m ${USERNAME} -G autologin,wheel,plugdev
echo "${USERNAME}:${USERNAME}" | chpasswd

# set the default editor, so visudo works
echo "export EDITOR=/usr/bin/vim" >> /etc/bash.bashrc

# Set SDDM AutoLogin
mkdir -p /etc/sddm.conf.d
echo "[Autologin]
User=${USERNAME}
Session=plasma.desktop" > /etc/sddm.conf.d/00-autologin.conf


echo "${SYSTEM_NAME}" > /etc/hostname

# enable multicast dns in avahi
sed -i "/^hosts:/ s/resolve/mdns resolve/" /etc/nsswitch.conf

# configure ssh
echo "
AuthorizedKeysFile	.ssh/authorized_keys
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PrintMotd no # pam does that
Subsystem	sftp	/usr/lib/ssh/sftp-server
" > /etc/ssh/sshd_config

echo "
LABEL=zenkai_root /var       btrfs     defaults,subvolid=256,rw,noatime,nodatacow,nofail                                                                                                                                                                                                                      0   0
LABEL=zenkai_root /home      btrfs     defaults,subvolid=257,rw,noatime,nodatacow,nofail                                                                                                                                                                                                                      0   0
LABEL=zenkai_root /zenkai_root btrfs     defaults,subvolid=5,rw,noatime,nodatacow,x-initrd.mount                                                                                                                                                                                                                0   2
overlay         /etc       overlay   defaults,x-systemd.requires-mounts-for=/zenkai_root,x-systemd.requires-mounts-for=/sysroot/zenkai_root,x-systemd.rw-only,lowerdir=/sysroot/etc,upperdir=/sysroot/zenkai_root/etc,workdir=/sysroot/zenkai_root/.etc,index=off,metacopy=off,comment=etcoverlay,x-initrd.mount    0   0
" > /etc/fstab

echo "
LSB_VERSION=1.4
DISTRIB_ID=${SYSTEM_NAME}
DISTRIB_RELEASE=\"${LSB_VERSION}\"
DISTRIB_DESCRIPTION=${SYSTEM_DESC}
" > /etc/lsb-release

echo 'NAME="${SYSTEM_DESC}"
VERSION="${DISPLAY_VERSION}"
VERSION_ID="${VERSION_NUMBER}"
BUILD_ID="${BUILD_ID}"
PRETTY_NAME="${SYSTEM_DESC} ${DISPLAY_VERSION}"
ID=${SYSTEM_NAME}
ID_LIKE=arch
ANSI_COLOR="1;36"
HOME_URL="${WEBSITE}"
DOCUMENTATION_URL="${DOCUMENTATION_URL}"
BUG_REPORT_URL="${BUG_REPORT_URL}"' > /usr/lib/os-release

# run post install hook
postinstallhook

# record installed packages & versions
pacman -Q > /manifest

# preserve installed package database
mkdir -p /usr/var/lib/pacman
cp -r /var/lib/pacman/local /usr/var/lib/pacman/

# move kernel image and initrd to a defualt location if "linux" is not used
if [ ${KERNEL_PACKAGE} != 'linux' ] ; then
	mv /boot/vmlinuz-${KERNEL_PACKAGE} /boot/vmlinuz-linux
	mv /boot/initramfs-${KERNEL_PACKAGE}.img /boot/initramfs-linux.img
	mv /boot/initramfs-${KERNEL_PACKAGE}-fallback.img /boot/initramfs-linux-fallback.img
fi

# clean up/remove unnecessary files
rm -rf \
/home \
/var \

rm -rf ${FILES_TO_DELETE}

# create necessary directories
mkdir -p /home
mkdir -p /var
mkdir -p /zenkai_root
mkdir -p /efi
EOF

#defrag the image
btrfs filesystem defragment -r ${BUILD_PATH}

# copy files into chroot again
cp -R rootfs/. ${BUILD_PATH}/

echo "${SYSTEM_NAME}-${VERSION}" > ${BUILD_PATH}/build_info
echo "" >> ${BUILD_PATH}/build_info
cat ${BUILD_PATH}/manifest >> ${BUILD_PATH}/build_info
rm ${BUILD_PATH}/manifest

# freeze archive date of build to avoid package drift on unlock
# if no archive date is set
if [ -z "${ARCHIVE_DATE}" ]; then
	export TODAY_DATE=$(date +%Y/%m/%d)
	echo "Server=https://archive.archlinux.org/repos/${TODAY_DATE}/\$repo/os/\$arch" > \
	${BUILD_PATH}/etc/pacman.d/mirrorlist
fi

btrfs subvolume snapshot -r ${BUILD_PATH} ${SNAP_PATH}
btrfs send -f ${SYSTEM_NAME}-${VERSION}.img ${SNAP_PATH}

cp ${BUILD_PATH}/build_info build_info.txt

# clean up
umount -l ${BUILD_PATH}
umount -l ${MOUNT_PATH}
rm -rf ${MOUNT_PATH}
rm -rf ${BUILD_IMG}

IMG_FILENAME="${SYSTEM_NAME}-${VERSION}.img"
COMPRESSED_IMG="${IMG_FILENAME}.tar.xz"
SPLIT_PREFIX="${COMPRESSED_IMG}.part."

# Compress the image with strong xz compression (change to zstd if desired)
tar -I 'xz -9 -e' -cf "${COMPRESSED_IMG}" "${IMG_FILENAME}"

# Remove the original uncompressed image
rm -f "${IMG_FILENAME}"

# Check the size of the compressed file
FILESIZE=$(stat -c%s "${COMPRESSED_IMG}")

# If larger than 2GB, split into 1900MB parts
if [ "${FILESIZE}" -gt 2147483648 ]; then
    echo "File exceeds 2 GB – splitting into 1900 MB parts..."
    split -b 1900M "${COMPRESSED_IMG}" "${SPLIT_PREFIX}"
    rm "${COMPRESSED_IMG}"  # remove original compressed file after splitting

    # Generate SHA256 checksums for all parts
    sha256sum ${SPLIT_PREFIX}* > sha256sum.txt
else
    # If file is less than 2GB, keep it as is
    sha256sum "${COMPRESSED_IMG}" > sha256sum.txt
fi

# Move files to OUTPUT_DIR if specified
if [ -n "${OUTPUT_DIR}" ]; then
    mkdir -p "${OUTPUT_DIR}"

    # Move split parts if they exist
    if ls ${SPLIT_PREFIX}* 1>/dev/null 2>&1; then
        mv ${SPLIT_PREFIX}* "${OUTPUT_DIR}"
    else
        mv "${COMPRESSED_IMG}" "${OUTPUT_DIR}"
    fi

    mv sha256sum.txt "${OUTPUT_DIR}"
    mv build_info.txt "${OUTPUT_DIR}"
fi

# Set GitHub Actions outputs if available
if [ -n "${GITHUB_OUTPUT}" ] && [ -f "${GITHUB_OUTPUT}" ]; then
    echo "version=${VERSION}" >> "${GITHUB_OUTPUT}"
    echo "display_version=${DISPLAY_VERSION}" >> "${GITHUB_OUTPUT}"
    echo "display_name=${SYSTEM_DESC}" >> "${GITHUB_OUTPUT}"

    if ls ${SPLIT_PREFIX}* 1>/dev/null 2>&1; then
        echo "image_filename=${SPLIT_PREFIX}*" >> "${GITHUB_OUTPUT}"
    else
        echo "image_filename=${COMPRESSED_IMG}" >> "${GITHUB_OUTPUT}"
    fi
else
    echo "No github output file set"
fi


