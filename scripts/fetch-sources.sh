#!/usr/bin/env bash
# fetch-sources.sh — Download and SHA-256 verify all source tarballs.
# Run from any directory; outputs to SOURCES/ relative to repo root.
# Usage: scripts/fetch-sources.sh [--force]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="${REPO_ROOT}/SOURCES"
mkdir -p "${SOURCES}"

# ─── Version Pins ────────────────────────────────────────────────────────────
OPENSSH_VER="${OPENSSH_VER:-10.2p1}"
OPENSSL_VER="${OPENSSL_VER:-3.6.1}"
ZLIB_VER="${ZLIB_VER:-1.3.2}"
ZIG_VER="${ZIG_VER:-0.15.2}"

# ─── Download URLs ───────────────────────────────────────────────────────────
declare -A URLS=(
  ["openssh-${OPENSSH_VER}.tar.gz"]="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VER}.tar.gz"
  ["openssl-${OPENSSL_VER}.tar.gz"]="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"
  ["zlib-${ZLIB_VER}.tar.gz"]="https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz"
  ["zig-x86_64-linux-${ZIG_VER}.tar.xz"]="https://ziglang.org/download/${ZIG_VER}/zig-x86_64-linux-${ZIG_VER}.tar.xz"
)

# ─── SHA-256 Checksums ───────────────────────────────────────────────────────
# Load pinned hashes from the committed checksums file if available.
# Otherwise fall back to VERIFY_AND_UPDATE placeholders.
declare -A SHA256=(
  ["openssh-${OPENSSH_VER}.tar.gz"]="VERIFY_AND_UPDATE_SHA256_openssh"
  ["openssl-${OPENSSL_VER}.tar.gz"]="VERIFY_AND_UPDATE_SHA256_openssl"
  ["zlib-${ZLIB_VER}.tar.gz"]="VERIFY_AND_UPDATE_SHA256_zlib"
  ["zig-x86_64-linux-${ZIG_VER}.tar.xz"]="VERIFY_AND_UPDATE_SHA256_zig_x86_64"
)

# ─── Checksums file (committed to repo after first verified download) ────────
CHECKSUM_FILE="${REPO_ROOT}/SOURCES/checksums.sha256"

# Load committed checksums — overrides placeholders above
if [[ -f "${CHECKSUM_FILE}" ]]; then
  while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    # Format: "hash  filename" (two spaces, sha256sum output)
    hash="${line%%  *}"
    filename="${line#*  }"
    # Only override if this filename is one we expect
    [[ -z "${filename}" || -z "${hash}" ]] && continue
    if [[ -n "${SHA256["${filename}"]+x}" ]]; then
      SHA256["${filename}"]="${hash}"
    fi
  done < "${CHECKSUM_FILE}"
fi

FORCE="${1:-}"

# ─── Helpers ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

download_file() {
  local filename="$1"
  local url="$2"
  local dest="${SOURCES}/${filename}"

  if [[ -f "${dest}" && "${FORCE}" != "--force" ]]; then
    info "Already exists: ${filename} (skip; use --force to re-download)"
    return 0
  fi

  info "Downloading: ${filename}"
  if command -v curl &>/dev/null; then
    curl -fsSL --retry 3 --retry-delay 2 -o "${dest}.tmp" "${url}"
  elif command -v wget &>/dev/null; then
    wget -q --tries=3 -O "${dest}.tmp" "${url}"
  else
    error "Neither curl nor wget found. Please install one."
  fi
  mv "${dest}.tmp" "${dest}"
  info "Downloaded:  ${filename}"
}

verify_checksum() {
  local filename="$1"
  local expected_hash="${SHA256[${filename}]}"
  local filepath="${SOURCES}/${filename}"

  # Skip verification for placeholder hashes
  if [[ "${expected_hash}" == VERIFY_AND_UPDATE_* ]]; then
    local actual_hash
    actual_hash="$(sha256_file "${filepath}")"
    warn "No SHA-256 pinned for ${filename}."
    warn "Actual SHA-256: ${actual_hash}"
    warn "Set SHA256[\"${filename}\"]=\"${actual_hash}\" in this script after verifying with upstream."
    return 0
  fi

  info "Verifying:   ${filename}"
  local actual_hash
  actual_hash="$(sha256_file "${filepath}")"
  if [[ "${actual_hash}" != "${expected_hash}" ]]; then
    error "SHA-256 MISMATCH for ${filename}!
  Expected: ${expected_hash}
  Actual:   ${actual_hash}
  Delete the file and re-run, or update the pinned hash after verifying upstream."
  fi
  info "Verified OK: ${filename}"
}

write_checksum_file() {
  info "Writing: ${CHECKSUM_FILE}"
  > "${CHECKSUM_FILE}"
  for filename in "${!URLS[@]}"; do
    local hash
    hash="$(sha256_file "${SOURCES}/${filename}")"
    echo "${hash}  ${filename}" >> "${CHECKSUM_FILE}"
  done
  sort -k2 "${CHECKSUM_FILE}" -o "${CHECKSUM_FILE}"
  info "Checksums written to SOURCES/checksums.sha256"
  info "Review, then commit this file to lock source hashes."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
info "=== Fetching sources (OpenSSH ${OPENSSH_VER}, OpenSSL ${OPENSSL_VER}, zlib ${ZLIB_VER}, Zig ${ZIG_VER}) ==="

for filename in "${!URLS[@]}"; do
  download_file "${filename}" "${URLS[${filename}]}"
  verify_checksum "${filename}"
done

write_checksum_file

info "=== All sources ready in SOURCES/ ==="
