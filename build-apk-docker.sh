#!/bin/bash
# build-apk-docker.sh
# Builds luci-app-starlink as a proper OpenWrt 25+ APK using the OpenWrt SDK in a container.
# Uses the plain `docker` CLI; podman works via a `docker` symlink (ln -s "$(command -v podman)" /usr/bin/docker).
#
# Bumble Confidential. For Internal Use Only.
#
# The package is PKGARCH=all, so ARCH only picks which SDK image to build in. Pick the one
# matching the build host (e.g. x86-64 on an x86_64 router) to avoid emulation.
#
# Environment overrides:
#   ARCH          SDK architecture      (default: aarch64_cortex-a53; e.g. x86-64)
#   OPENWRT_VER   SDK release           (default: 25.12.0-rc5)
#   SDK_IMAGE     full image reference  (default: openwrt/sdk:${ARCH}-${OPENWRT_VER})
#   JOBS          parallel make jobs    (default: nproc)
#   SIGN_KEY      PKCS#8 PEM private key; unset to leave the APK unsigned
#   PUBLIC_KEY    public key used to verify the signed APK (default: keys/luci-fancontrol-signing.pub)
#   OUTPUT_DIR    where the APK lands   (default: ./output)
#
# Example (x86_64 router):
#   ARCH=x86-64 ./build-apk-docker.sh

set -e

PKG="luci-app-starlink"
OPENWRT_VER="${OPENWRT_VER:-25.12.0-rc5}"
ARCH="${ARCH:-aarch64_cortex-a53}"
SDK_IMAGE="${SDK_IMAGE:-openwrt/sdk:${ARCH}-${OPENWRT_VER}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
PUBLIC_KEY="${PUBLIC_KEY:-${SCRIPT_DIR}/keys/luci-fancontrol-signing.pub}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

echo "================================================"
echo " Building ${PKG} APK"
echo " SDK image: ${SDK_IMAGE}"
echo "================================================"
echo ""

mkdir -p "${OUTPUT_DIR}"

SIGN_ARGS=()
if [ -n "${SIGN_KEY}" ]; then
  [ -f "${SIGN_KEY}" ] || { echo "ERROR: SIGN_KEY not found at ${SIGN_KEY}"; exit 1; }
  [ -f "${PUBLIC_KEY}" ] || { echo "ERROR: PUBLIC_KEY not found at ${PUBLIC_KEY}"; exit 1; }
  SIGN_ARGS=(
    -v "${SIGN_KEY}:/signing-key/key-build-p8:ro"
    -v "${PUBLIC_KEY}:/signing-key/signing.pub:ro"
    -e SIGN=1
  )
fi

docker run --rm \
  -v "${SCRIPT_DIR}/openwrt-feed:/pkg-src:ro" \
  -v "${OUTPUT_DIR}:/output" \
  "${SIGN_ARGS[@]}" \
  --user root \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -e JOBS="${JOBS}" \
  "${SDK_IMAGE}" \
  /bin/bash -c '
    set -e

    SDK_DIR="/builder"
    cd "$SDK_DIR"

    echo "--- Setting up package feed ---"
    mkdir -p package/luci-app-starlink/files
    cp /pkg-src/Makefile package/luci-app-starlink/Makefile
    cp /pkg-src/files/*  package/luci-app-starlink/files/

    echo "--- Updating feeds ---"
    ./scripts/feeds update -a 2>&1 | tail -5
    ./scripts/feeds install -a 2>&1 | tail -5

    echo "--- Configuring ---"
    make defconfig 2>&1 | tail -3
    echo "CONFIG_PACKAGE_luci-app-starlink=m" >> .config
    echo "CONFIG_PACKAGE_lua=y" >> .config
    make defconfig 2>&1 | tail -3

    echo "--- Building Lua (required by lucihttp) ---"
    make package/lua/compile -j"$JOBS" >/dev/null 2>&1 && echo "lua OK" || echo "WARNING: lua build failed"

    echo "--- Compiling ---"
    make package/luci-app-starlink/compile V=s 2>&1 | tail -30

    echo "--- Copying output ---"
    APK=$(find bin/ -name "luci-app-starlink*.apk" -type f | head -1)
    cp "$APK" /output/
    echo "Copied: $APK"
    OUT=/output/$(basename "$APK")

    if [ -n "$SIGN" ]; then
      echo "--- Signing APK ---"
      /builder/staging_dir/host/bin/apk --allow-untrusted adbsign \
        --sign-key /signing-key/key-build-p8 "$OUT"

      echo "--- Verifying ---"
      /builder/staging_dir/host/bin/apk verify --keys-dir /signing-key "$OUT"
    fi

    chown "${HOST_UID}:${HOST_GID}" "$OUT" || true
    ls -lh "$OUT"
  '

echo ""
echo "================================================"
ls -lh "${OUTPUT_DIR}/"luci-app-starlink* 2>/dev/null && \
  echo "Success!" || echo "No output — check errors above"
echo "================================================"
echo ""
if [ -n "${SIGN_KEY}" ]; then
  echo "Install on router (signed — needs the public key in /etc/apk/keys/):"
  echo "  apk add ${OUTPUT_DIR}/luci-app-starlink-*.apk"
  echo ""
fi
echo "Install without key verification:"
echo "  apk add --allow-untrusted ${OUTPUT_DIR}/luci-app-starlink-*.apk"
echo "(or scp -O it to root@192.168.1.1:/tmp/ first when building off-router)"
