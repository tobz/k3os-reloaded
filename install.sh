#!/bin/bash
set -e

PROG=$0
PROGS="dd curl mkfs.ext4 mkfs.vfat fatlabel parted partprobe grub-install"
DISTRO=/run/k3os/iso

if [ "$K3OS_DEBUG" = true ]; then
    set -x
fi

get_url()
{
    FROM=$1
    TO=$2

    echo "[*] Downloading ${FROM}, saving to ${TO}..."

    case $FROM in
        ftp*|http*|tftp*)
            n=0
            attempts=5
            until [ "$n" -ge "$attempts" ]
            do
                curl -o "${TO}" -fL "${FROM}" && break
                n=$((n+1))
                echo "Failed to download, retry attempt ${n} out of ${attempts}"
                sleep 2
            done
            ;;
        *)
            cp -f "${FROM}" "${TO}"
            ;;
    esac
}

cleanup2()
{
    if [ -n "${TARGET}" ]; then
        umount "${TARGET}/boot/efi" || true
        umount "${TARGET}" || true
    fi

    losetup -d "${ISO_DEVICE}" || losetup -d "${ISO_DEVICE%?}" || true
    umount "${DISTRO}" || true
}

cleanup()
{
    EXIT=$?
    cleanup2 2>/dev/null || true
    return $EXIT
}

usage()
{
    echo "Usage: $PROG [--force-efi] [--debug] [--tty TTY] [--poweroff] [--takeover] [--no-format] [--config https://.../config.yaml] DEVICE ISO_URL"
    echo ""
    echo "Example: $PROG /dev/vda https://github.com/rancher/k3os/releases/download/v0.8.0/k3os.iso"
    echo ""
    echo "DEVICE must be the disk that will be partitioned (/dev/vda). If you are using --no-format it should be the device of the K3OS_STATE partition (/dev/vda2)"
    echo ""
    echo "The parameters names refer to the same names used in the cmdline, refer to README.md for"
    echo "more info."
    echo ""
    exit 1
}

do_format()
{
    # If we've been instructed to not format the state device, simply try to see if there's already
    # a device with the state label. If not, and a state device has been specified, add the state
    # label to that device before we skip formatting.
    if [ "${K3OS_INSTALL_NO_FORMAT}" = "true" ]; then
        STATE=$(blkid -L K3OS_STATE || true)
        if [ -z "${STATE}" ] && [ -n "${DEVICE}" ]; then
            tune2fs -L K3OS_STATE "${DEVICE}" >/dev/null
            STATE=$(blkid -L K3OS_STATE)
        fi

        echo "[*] Formatting of install device disabled by user. Skipping."
        return 0
    fi

    # Zero out any partition table information on the state device.
    echo "[*] Zeroing out install device and building state/boot partitions..."
    dd if=/dev/zero of=${DEVICE} bs=1M count=1 >/dev/null

    # Label our state device with the partition table type (GPT, MSDOS i.e. MBR) that we're using,
    # and partition the drive accordingly.
    parted -s ${DEVICE} mklabel ${PARTTABLE}
    if [ "${PARTTABLE}" = "gpt" ]; then
        BOOT_NUM=1
        STATE_NUM=2
        parted -s ${DEVICE} mkpart primary fat32 0% 64MB
        parted -s ${DEVICE} mkpart primary ext4 64MB 1024MB
    else
        BOOT_NUM=
        STATE_NUM=1
        parted -s ${DEVICE} mkpart primary ext4 0% 1024MB
    fi

    # Set the boot flag for the boot partition, and probe the device to update all of the partition
    # information, which includes briefly sleeping afterwards to make sure things have settled.
    parted -s ${DEVICE} set 1 ${BOOTFLAG} on
    partprobe ${DEVICE} &>/dev/null || true
    sleep 2

    # Figure out the necessary device prefixes so we can refer to the boot and state partitions.
    PREFIX="${DEVICE}"
    if [ ! -e "${PREFIX}${STATE_NUM}" ]; then
        PREFIX="${DEVICE}p"
    fi

    if [ ! -e "${PREFIX}${STATE_NUM}" ]; then
        echo "[!] Failed to find ${PREFIX}${STATE_NUM} or ${DEVICE}${STATE_NUM} to format."
        exit 1
    fi

    if [ -n "${BOOT_NUM}" ]; then
        BOOT="${PREFIX}${BOOT_NUM}"
    fi
    STATE="${PREFIX}${STATE_NUM}"
    
    # Format the state partition, and if a dedicated boot partition was created, format that as
    # well.
    echo "[*] Formatting state/boot partitions..."
    mkfs.ext4 -F -L K3OS_STATE "${STATE}" >/dev/null
    if [ -n "${BOOT}" ]; then
        mkfs.vfat -F 32 "${BOOT}" >/dev/null
        fatlabel "${BOOT}" K3OS_GRUB
    fi
}

do_mount()
{
    # Mount our target state partition, as well as the target boot partition, which we'll copy over
    # the relevant OS files into.
    echo "[*] Mounting state and boot partitions..."
    TARGET="/run/k3os/target"
    mkdir -p "${TARGET}/boot"
    mount "${STATE}" "${TARGET}"
    if [ -n "${BOOT}" ]; then
        mkdir -p "${TARGET}/boot/efi"
        mount "${BOOT}" "${TARGET}/boot/efi"
    fi

    # Mount our installation media at a known location.
    echo "[*] Mounting installation media (${ISO_DEVICE}) at ${DISTRO}..."
    mkdir -p "${DISTRO}"
    mount -o ro "${ISO_DEVICE}" "${DISTRO}" || mount -o ro "${ISO_DEVICE%?}" "${DISTRO}"
}

do_copy()
{
    # Copy the files from the installation media into the state partition.
    echo "[*] Copying distribution from installation media to state partition..."
    tar cf - -C "${DISTRO}" k3os | tar xf - -C "${TARGET}"
    if [ -n "${STATE_NUM}" ]; then
        # Store a record of what device the state partition lives on, so that we can do a
        # post-install partition expansion to utilize the remaining space on the overall device.
        echo "${DEVICE} ${STATE_NUM}" > "${TARGET}/k3os/system/growpart"
    fi

    # If a specific k3OS configuration path has been specified, download it and move it into place.
    if [ -n "${K3OS_INSTALL_CONFIG_URL}" ]; then
        echo "[*] Using custom K3OS configuration from ${K3OS_INSTALL_CONFIG_URL}."

        get_url "${K3OS_INSTALL_CONFIG_URL}" ${TARGET}/k3os/system/config.yaml
        chmod 600 ${TARGET}/k3os/system/config.yaml
    fi

    # If we're doing a "takeover" install, touch our takeover marker file.
    #
    # Additionally, see if we've been instructed to power off when done installing.
    if [ "${K3OS_INSTALL_TAKE_OVER}" = "true" ]; then
        touch "${TARGET}/k3os/system/takeover"

        if [ "${K3OS_INSTALL_POWER_OFF}" = true ] || grep -q 'k3os.install.power_off=true' /proc/cmdline; then
            echo "[*] System marked for power off after installation completes."
            touch "${TARGET}/k3os/system/poweroff"
        fi
    fi
}

install_grub()
{
    echo "[*] Installing Grub configuration..."

    # If we were instructed to be in debug mode during the install, propagate this to the Grub
    # configuration for all of the relevant menu entries.
    if [ "${K3OS_INSTALL_DEBUG}" ]; then
        GRUB_DEBUG="k3os.debug"
    fi

    # Push the Grub configuration into place.
    mkdir -p "${TARGET}/boot/grub"
    cat > "${TARGET}/boot/grub/grub.cfg" << EOF
set default=0
set timeout=10

set gfxmode=auto
set gfxpayload=keep
insmod all_video
insmod gfxterm

menuentry "k3OS Current" {
  search.fs_label K3OS_STATE root
  set sqfile=/k3os/system/kernel/current/kernel.squashfs
  loopback loop0 /\$sqfile
  set root=(\$root)
  linux (loop0)/vmlinuz printk.devkmsg=on console=tty1 $GRUB_DEBUG
  initrd /k3os/system/kernel/current/initrd
}

menuentry "k3OS Previous" {
  search.fs_label K3OS_STATE root
  set sqfile=/k3os/system/kernel/previous/kernel.squashfs
  loopback loop0 /\$sqfile
  set root=(\$root)
  linux (loop0)/vmlinuz printk.devkmsg=on console=tty1 $GRUB_DEBUG
  initrd /k3os/system/kernel/previous/initrd
}

menuentry "k3OS Rescue (current)" {
  search.fs_label K3OS_STATE root
  set sqfile=/k3os/system/kernel/current/kernel.squashfs
  loopback loop0 /\$sqfile
  set root=(\$root)
  linux (loop0)/vmlinuz printk.devkmsg=on rescue console=tty1
  initrd /k3os/system/kernel/current/initrd
}

menuentry "k3OS Rescue (previous)" {
  search.fs_label K3OS_STATE root
  set sqfile=/k3os/system/kernel/previous/kernel.squashfs
  loopback loop0 /\$sqfile
  set root=(\$root)
  linux (loop0)/vmlinuz printk.devkmsg=on rescue console=tty1
  initrd /k3os/system/kernel/previous/initrd
}
EOF
    if [ -z "${K3OS_INSTALL_TTY}" ]; then
        TTY=$(tty | sed 's!/dev/!!')
    else
        TTY="${K3OS_INSTALL_TTY}"
    fi
    if [ -e "/dev/${TTY%,*}" ] && [ "${TTY}" != tty1 ] && [ "${TTY}" != console ] && [ -n "${TTY}" ]; then
        sed -i "s!console=tty1!console=tty1 console=${TTY}!g" "${TARGET}/boot/grub/grub.cfg"
    fi

    if [ "${K3OS_INSTALL_NO_FORMAT}" = "true" ]; then
        return 0
    fi

    if [ "${K3OS_INSTALL_FORCE_EFI}" = "true" ]; then
        if [ $(uname -m) = "aarch64" ]; then
            GRUB_TARGET="--target=arm64-efi"
        else
            GRUB_TARGET="--target=x86_64-efi"
        fi
    fi

    echo "[*] Rebuilding boot files with new Grub configuration..."

    # Install the Grub bootloader to finalize all of the relevant files.
    grub-install ${GRUB_TARGET} --boot-directory=${TARGET}/boot --removable ${DEVICE}
}

get_iso()
{
    # Query `lsblk` to see if we can find any installation media attached with the volume ID that we
    # specifically use when building the ISO image.
    if [ -z "${ISO_DEVICE}" ]; then
        ISO_DEVICE=$(lsblk -J -o NAME,LABEL | jq -r '.blockdevices[].children?[]? | select(.label == "K3OS") | "/dev/\(.name)"' | head -1 || true)
    fi

    # If we couldn't find a partition matching our typical installation media layout, find all
    # top-level block devices (disks, not partitions) and see if we can mount them in read-only
    # mode. The first one we find that can be mounted read-only will be assumed to be the
    # installation media.
    if [ -z "${ISO_DEVICE}" ]; then
        for dev in $(lsblk -o NAME,TYPE -n | grep -w disk | awk '{print $1}'); do
            mkdir -p "${DISTRO}"
            if mount -o ro "/dev/${dev}" "${DISTRO}"; then
                ISO_DEVICE="/dev/${dev}"
                umount "${DISTRO}"
                break
            fi
        done
    fi

    # If we still don't know what block device we should be using as our installation media, and
    # we've been given an explicit URL to an ISO image, download that ISO and mount it as a loopback
    # device, and point ourselves at the generated name for that loopback device.
    if [ -z "${ISO_DEVICE}" ] && [ -n "${K3OS_INSTALL_ISO_URL}" ]; then
        TEMP_FILE=$(mktemp k3os.XXXXXXXX.iso)
        get_url "${K3OS_INSTALL_ISO_URL}" "${TEMP_FILE}"
        ISO_DEVICE=$(losetup --show -f ${TEMP_FILE})
        rm -f "${TEMP_FILE}"
    fi

    # If we still have nothing, bail out.
    if [ -z "${ISO_DEVICE}" ]; then
        echo "[!] No installation media was detected."
        return 1
    fi

    echo "[*] Installation media detected as ${ISO_DEVICE}."
}

setup_style()
{
    # Figure out if we're booting in legacy MS-DOS mode, or EFI mode.
    if [ "${K3OS_INSTALL_FORCE_EFI}" = "true" ] || [ -e /sys/firmware/efi ]; then
        echo "[*] Using EFI mode for boot disk configuration."

        PARTTABLE="gpt"
        BOOTFLAG="esp"
        if [ ! -e /sys/firmware/efi ]; then
            echo "WARNING: Installing EFI on to a system that does not support EFI!"
        fi
    else
        echo "[*] Using MBR for boot disk configuration."

        PARTTABLE="msdos"
        BOOTFLAG="boot"
    fi
}

validate_progs()
{
    # For each required program that's specified, make sure it exists.
    #
    # If it does not exist, add it to the missing list.
    for prog in ${PROGS}; do
        if [ ! -x "$(which $prog)" ]; then
            MISSING="${MISSING} $prog"
        fi
    done

    if [ -n "${MISSING}" ]; then
        echo "[!] Some required installation programs are missing: ${MISSING}"
        exit 1
    fi

    echo "[*] All required programs for installation are present."
}

validate_device()
{
    DEVICE="${K3OS_INSTALL_DEVICE}"
    if [ ! -b "${DEVICE}" ]; then
        echo "[!] Target install device \`${DEVICE}\` does not exist."
        exit 1
    fi

    echo "[*] Target install device detected as ${DEVICE}."
}

create_opt()
{
    mkdir -p "${TARGET}/k3os/data/opt"
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --no-format)
            K3OS_INSTALL_NO_FORMAT=true
            ;;
        --force-efi)
            K3OS_INSTALL_FORCE_EFI=true
            ;;
        --poweroff)
            K3OS_INSTALL_POWER_OFF=true
            ;;
        --takeover)
            K3OS_INSTALL_TAKE_OVER=true
            ;;
        --debug)
            set -x
            K3OS_INSTALL_DEBUG=true
            ;;
        --config)
            shift 1
            K3OS_INSTALL_CONFIG_URL=$1
            ;;
        --tty)
            shift 1
            K3OS_INSTALL_TTY=$1
            ;;
        -h)
            usage
            ;;
        --help)
            usage
            ;;
        *)
            if [ "$#" -gt 2 ]; then
                usage
            fi
            INTERACTIVE=true
            K3OS_INSTALL_DEVICE=$1
            K3OS_INSTALL_ISO_URL=$2
            break
            ;;
    esac
    shift 1
done

if [ -e /etc/environment ]; then
    source /etc/environment
fi

if [ -e /etc/os-release ]; then
    source /etc/os-release

    if [ -z "${K3OS_INSTALL_ISO_URL}" ]; then
        K3OS_INSTALL_ISO_URL=${ISO_URL}
    fi
fi

if [ -z "${K3OS_INSTALL_DEVICE}" ]; then
    usage
fi

validate_progs
validate_device

trap cleanup exit

get_iso
setup_style
do_format
do_mount
do_copy
install_grub
create_opt

if [ -n "${INTERACTIVE}" ]; then
    exit 0
fi

# Either power off or reboot the system, depending on the configuration.
if [ "${K3OS_INSTALL_POWER_OFF}" = true ] || grep -q 'k3os.install.power_off=true' /proc/cmdline; then
    poweroff -f
else
    echo "[*] Rebooting system in 5 seconds... (CTRL+C to cancel)"
    sleep 5
    reboot -f
fi
