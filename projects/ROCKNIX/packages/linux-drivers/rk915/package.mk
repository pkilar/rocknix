# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)
PKG_NAME="rk915"
PKG_VERSION="590fe1dd3fa9569117317b2e0dcbe02c42f8419e"
PKG_SHA256="2338c1583c0662e6e1c8f5992b416617ee39b382d3bf8e2a422ffe7b1ef9cfe5"
PKG_LICENSE="GPL"
PKG_SITE="https://github.com/stolen/rk915"
PKG_URL="${PKG_SITE}/archive/${PKG_VERSION}.tar.gz"
PKG_LONGDESC="rk915: Rockchip RK915 SDIO WiFi driver, mainline port"
PKG_TOOLCHAIN="manual"
PKG_IS_KERNEL_PKG="yes"

# Needs the MMC quirks from 035-rk915-sdio-quirks.patch: the chip has a short
# CIS, must not be re-powered on resume, and needs the dw_mmc clock ungated.

pre_make_target() {
  unset LDFLAGS
}

make_target() {
  kernel_make -C $(kernel_path) M=${PKG_BUILD} CONFIG_RK915=m
}

makeinstall_target() {
  mkdir -p ${INSTALL}/$(get_full_module_dir)/${PKG_NAME}
    cp *.ko ${INSTALL}/$(get_full_module_dir)/${PKG_NAME}

  # rk915_fw.bin / rk915_patch.bin - byte-identical to the blobs shipped by the
  # vendor EmuELEC build, so this is the right firmware for the chip revision.
  mkdir -p ${INSTALL}/$(get_kernel_overlay_dir)/lib/firmware
    cp -av firmware/rk915_fw.bin firmware/rk915_patch.bin \
       ${INSTALL}/$(get_kernel_overlay_dir)/lib/firmware
}
