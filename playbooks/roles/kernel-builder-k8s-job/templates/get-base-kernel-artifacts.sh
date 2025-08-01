#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2025 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

set -e
set -x

IMAGE="/base-fedora-cloud-img.qcow2"

export LIBGUESTFS_BACKEND=direct

FILES=$(guestfish --ro -a "$IMAGE" <<EOF
run
mount /dev/sda3 /
ls /
EOF
)

CONFIG_FILE=$(echo "$FILES" | grep 'config-' | xargs)
INITRAMFS_FILE=$(echo "$FILES" | grep 'initramfs-' | xargs)

guestfish --ro -a "$IMAGE" <<EOF
run
mount /dev/sda3 /
copy-out /${CONFIG_FILE} /
copy-out /${INITRAMFS_FILE} /
EOF

mv /config-* /base-kernel-config
mv /initramfs-* /base-initramfs.cpio.gz
