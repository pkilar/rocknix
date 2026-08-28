# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)
PKG_NAME="h7-audio"
PKG_VERSION="1"
PKG_LICENSE="GPL"
PKG_SITE="https://github.com/ROCKNIX/distribution"
PKG_URL=""
PKG_DEPENDS_TARGET="toolchain"
PKG_LONGDESC="Gusgu H7: re-apply the saved volume once the audio sink exists"
PKG_TOOLCHAIN="manual"

makeinstall_target() {
  # /usr/lib/autostart/${HW_DEVICE} runs after the common scripts, which is
  # required here: common/050-audio would overwrite anything set earlier.
  mkdir -p ${INSTALL}/usr/lib/autostart/RK3326
  cp ${PKG_DIR}/autostart/055-h7-volume ${INSTALL}/usr/lib/autostart/RK3326/
  chmod 0755 ${INSTALL}/usr/lib/autostart/RK3326/055-h7-volume
}
