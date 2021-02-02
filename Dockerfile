# syntax = docker/dockerfile:1.0-experimental
FROM ubuntu:20.04 AS rootfs

ENV DEBIAN_FRONTEND=noninteractive

# Install some base packages for the system
RUN apt-get update && \
    apt-get install -yq --no-install-recommends \
        linux-image-generic systemd nano systemd-sysv dbus sudo overlayroot

COPY ./fs/* /

RUN useradd -m ubuntu -G sudo -s /bin/bash
RUN --mount=type=secret,id=secret chpasswd < /run/secrets/secret

RUN cp /usr/share/systemd/tmp.mount /lib/systemd/system

# Enable /tmp mount as tmpfs
RUN systemctl enable tmp.mount
# Enable systemd-networkd for bringing up network
RUN systemctl enable systemd-networkd


FROM ubuntu:20.04 AS build

WORKDIR /root

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -yq --no-install-recommends \
        squashfs-tools dosfstools parted udev grub2 grub-efi-amd64-signed shim-signed mtools

COPY ./utils/sectors.sh .

# Create empty file for containing the partitions
RUN fallocate -l 2GiB image.img

# Set up partition table
# 100MiB (EFI System Partition)
# ~900MiB (rootfs squash images)
# Remaining (overlay partition)
RUN parted image.img \
    mktable gpt \
    mkpart primary 0% 100MiB \
    mkpart primary 100MiB 1GiB \
    mkpart primary 1GiB 100% \
    set 1 esp on

RUN mkdir -p esp/EFI/BOOT esp/EFI/ubuntu esp/grub

COPY ./fs/boot/grub/grub.cfg esp/grub/
COPY ./fs/boot/EFI/ubuntu/grub.cfg ./esp/EFI/ubuntu/
RUN cp -r /usr/lib/grub/x86_64-efi esp/grub/x86_64-efi

# Make unsigned GRUB EFI image
RUN grub-mkimage -o esp/EFI/BOOT/BOOTX64.efi -O x86_64-efi -p "(,gpt1)/grub" fat part_gpt

RUN cp /usr/lib/shim/BOOTX64.CSV esp/EFI/ubuntu/BOOTX64.CSV
RUN cp /usr/lib/shim/shimx64.efi.signed esp/EFI/ubuntu/shimx64.efi
RUN cp /usr/lib/shim/mmx64.efi esp/EFI/ubuntu/mmx64.efi
RUN cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed esp/EFI/ubuntu/grubx64.efi

# Create new FAT image for the ESP
RUN mkfs.fat -C esp.img \
    $(./sectors.sh size image.img 1)

# Copy the contents of esp/ into the FAT esp.img
# Then dd it into the main image without truncating
RUN mcopy -s -i esp.img esp/* ::

# Make new EXT4 image
# Specify the LABEL should be OVERLAY which makes mounting it easier later on
# Create it with the calculated correct size, bearing in mind default block size of 1024
RUN mkfs.ext4 -L OVERLAY overlay.img \
    $(( $(./sectors.sh size image.img 3) / 2 ))

# Combine the individual partitions into the main image
# For each partition, seek to the sector it should start at
# conv=notrunc ensures that no truncation of the image occurs after each command
RUN dd if=esp.img of=image.img status=progress conv=notrunc \
    seek=$(./sectors.sh start image.img 1)
RUN dd if=overlay.img of=image.img status=progress conv=notrunc \
    seek=$(./sectors.sh start image.img 3)

# Pack the rootfs into a squash image
# GRUB is able to load the kernel and initramfs inside on boot
RUN mkdir -p squash
RUN --mount=type=bind,from=rootfs,target=rootfs/ \
    mksquashfs rootfs/ squash/rootfs.squash

# Make new EXT4 image initialised with contents of squash/
# Specify the UUID we want to create it with which matches up with our GRUB config
# Create it with the calculate correct size, bearing in mind default block size of 1024
RUN mkfs.ext4 -d squash/ squash.img -U a185a4b8-f920-4c5d-8b19-8d5a9e49024e \
    $(( $(./sectors.sh size image.img 2) / 2 ))

RUN dd if=squash.img of=image.img status=progress conv=notrunc \
    seek=$(./sectors.sh start image.img 2)

FROM scratch AS export
COPY --from=build /root/squash/rootfs.squash /root/image.img /
