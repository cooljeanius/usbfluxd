#!/bin/sh

VER="1.0"
CONFIG_VERSION="$(grep AC_INIT configure.ac |cut -d "[" -f3 |cut -d "]" -f 1)"
if test -n "${CONFIG_VERSION}"; then
    VER="${CONFIG_VERSION}"
fi

make
codesign -s "Developer ID Application: Corellium LLC (XG264R6QP8)" usbfluxd/usbfluxd
codesign -s "Developer ID Application: Corellium LLC (XG264R6QP8)" tools/usbfluxctl

COMMIT="$(git rev-parse HEAD)"
if test -z "${COMMIT}"; then
  COMMIT="nogit"
fi
THISDIR="$(pwd)"
cd USBFlux || return
xcodebuild clean build
if test -d build/Release; then
  cd build/Release || return
elif test -d USBFlux/build/Release; then
  cd USBFlux/build/Release || return
elif test -d build/Debug; then
  cd build/Debug || return
elif test -d USBFlux/build/Debug; then
  cd USBFlux/build/Debug || return
else
  echo "Warning! Missing a known build directory!"
fi
zip -r "${THISDIR}/USBFlux-${VER}-${COMMIT}.zip" USBFlux.app
cd "${THISDIR}" || return

