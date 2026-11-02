#!/bin/bash
# build-local-arch.sh
# Builds the starlink-dish binary for the machine this runs on (static musl, suits OpenWrt).
# Upstream only ships aarch64; use this for x86_64 and other hosts.
# Uses the plain `docker` CLI; podman works via a `docker` symlink (ln -s "$(command -v podman)" /usr/bin/docker).
#
# Bumble Confidential. For Internal Use Only.
#
# Environment overrides:
#   DISH_REPO     upstream source repo  (default: https://github.com/bigmalloy/starlink-panel)
#   DISH_REF      branch or tag to build (default: repo default branch)
#   OUTPUT_DIR    where the binary lands (default: ./output)
#   SRC_DIR       checkout location      (default: ${OUTPUT_DIR}/starlink-panel-src)
#
# Example:
#   ./build-local-arch.sh
#   install -m 755 output/starlink-dish /usr/bin/starlink-dish

set -e

DISH_REPO="${DISH_REPO:-https://github.com/bigmalloy/starlink-panel}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
SRC_DIR="${SRC_DIR:-${OUTPUT_DIR}/starlink-panel-src}"

# protoc 21.12: oldest release with native proto3 optional support (distro protoc is too old)
PROTOC_VER="21.12"

HOST_ARCH="$(uname -m)"
case "${HOST_ARCH}" in
  x86_64)
    TARGET="x86_64-unknown-linux-musl"
    IMAGE="messense/rust-musl-cross:x86_64-musl"
    PROTOC_ARCH="x86_64"
    ;;
  aarch64|arm64)
    TARGET="aarch64-unknown-linux-musl"
    IMAGE="messense/rust-musl-cross:aarch64-musl"
    PROTOC_ARCH="aarch_64"
    ;;
  *)
    echo "ERROR: unsupported host architecture: ${HOST_ARCH}"
    exit 1
    ;;
esac

echo "================================================"
echo " Building starlink-dish for ${HOST_ARCH}"
echo " Target: ${TARGET}"
echo " Image:  ${IMAGE}"
echo "================================================"
echo ""

mkdir -p "${OUTPUT_DIR}"

if [ ! -d "${SRC_DIR}/.git" ]; then
  git clone ${DISH_REF:+--branch "${DISH_REF}"} "${DISH_REPO}" "${SRC_DIR}"
fi

docker run --rm \
  -v "${SRC_DIR}/rust-src":/app \
  -w /app \
  -e TARGET="${TARGET}" \
  -e PROTOC_VER="${PROTOC_VER}" \
  -e PROTOC_ARCH="${PROTOC_ARCH}" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  "${IMAGE}" \
  bash -c '
    set -e
    apt-get update -qq && apt-get install -y unzip wget
    wget -q "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VER}/protoc-${PROTOC_VER}-linux-${PROTOC_ARCH}.zip" \
        -O /tmp/protoc.zip
    unzip -q /tmp/protoc.zip -d /usr/local bin/protoc
    rm /tmp/protoc.zip
    export PROTOC=/usr/local/bin/protoc
    cargo build --release --target "${TARGET}"
    chown -R "${HOST_UID}:${HOST_GID}" target || true
  '

BIN="${SRC_DIR}/rust-src/target/${TARGET}/release/starlink-dish"
if [ ! -f "${BIN}" ]; then
  echo "ERROR: Binary not found at ${BIN}"
  exit 1
fi

cp "${BIN}" "${OUTPUT_DIR}/starlink-dish"

echo ""
echo "================================================"
ls -lh "${OUTPUT_DIR}/starlink-dish"
echo "================================================"
echo ""
echo "Install:"
echo "  install -m 755 ${OUTPUT_DIR}/starlink-dish /usr/bin/starlink-dish"
