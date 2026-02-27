#!/usr/bin/env bash
# build-local.sh — Build all three OpenSSH RPMs for x86_64 and aarch64.
# Requires: rpm-build rpmdevtools (on the host Linux machine)
# Usage:    scripts/build-local.sh [x86_64|aarch64|all]
#
# The host must be a Linux x86_64 machine.
# aarch64 packages are cross-compiled via zig cc — no QEMU needed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# ─── Version Pins ─────────────────────────────────────────────────────────────
OPENSSH_VER="${OPENSSH_VER:-9.9p2}"
OPENSSL_VER="${OPENSSL_VER:-3.5.0}"
ZLIB_VER="${ZLIB_VER:-1.3.2}"
ZIG_VER="${ZIG_VER:-0.15.2}"
RPM_RELEASE="${RPM_RELEASE:-1}"

ARCHS_ARG="${1:-all}"
case "${ARCHS_ARG}" in
  x86_64)  ARCHS=(x86_64) ;;
  aarch64) ARCHS=(aarch64) ;;
  all)     ARCHS=(x86_64 aarch64) ;;
  *) echo "Usage: $0 [x86_64|aarch64|all]" >&2; exit 1 ;;
esac

SPECS=(openssh openssh-clients openssh-server)

# ─── Helpers ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header(){ echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

check_deps() {
  local missing=()
  for cmd in rpmbuild rpm; do
    command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing tools: ${missing[*]}\nInstall with: dnf install rpm-build"
  fi
}

# ─── Setup rpm tree ───────────────────────────────────────────────────────────
setup_rpm_tree() {
  # rpmdev-setuptree is not available on all distros (e.g. Ubuntu); create dirs manually
  mkdir -p "${HOME}/rpmbuild"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  local rpm_sources="${HOME}/rpmbuild/SOURCES"
  local rpm_specs="${HOME}/rpmbuild/SPECS"

  info "Copying sources to ~/rpmbuild/SOURCES/"
  cp -u SOURCES/openssh-${OPENSSH_VER}.tar.gz       "${rpm_sources}/"
  cp -u SOURCES/openssl-${OPENSSL_VER}.tar.gz        "${rpm_sources}/"
  cp -u SOURCES/zlib-${ZLIB_VER}.tar.gz              "${rpm_sources}/"
  cp -u SOURCES/zig-x86_64-linux-${ZIG_VER}.tar.xz  "${rpm_sources}/"
  cp -u SOURCES/sshd.service                         "${rpm_sources}/"
  cp -u SOURCES/sshd_config                          "${rpm_sources}/"
  cp -u SOURCES/ssh_config                           "${rpm_sources}/"
}

# ─── Build one package / one arch ─────────────────────────────────────────────
build_rpm() {
  local spec="$1"
  local arch="$2"
  header "Building ${spec} (${arch})"

  rpmbuild -bb \
    --nodeps \
    --target "${arch}" \
    --define "openssh_ver   ${OPENSSH_VER}" \
    --define "openssl_ver   ${OPENSSL_VER}" \
    --define "zlib_ver      ${ZLIB_VER}" \
    --define "zig_ver       ${ZIG_VER}" \
    --define "_rpmfilename  %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
    "SPECS/${spec}.spec" \
    2>&1 | tee "/tmp/rpmbuild-${spec}-${arch}.log"

  if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
    error "rpmbuild failed for ${spec}/${arch}. See /tmp/rpmbuild-${spec}-${arch}.log"
  fi
  info "Done: ${spec} (${arch})"
}

# ─── Locate latest RPM regardless of RPMS layout ─────────────────────────────
find_latest_rpm() {
  local rpm_dir="$1"
  local spec="$2"
  local arch="$3"

  find "${rpm_dir}" -maxdepth 2 -type f \
    -name "${spec}-${OPENSSH_VER}-*.${arch}.rpm" 2>/dev/null \
    | sort -V | tail -1
}

# ─── Verify static linkage of all binaries in an RPM ─────────────────────────
verify_static() {
  local rpm_file="$1"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap "rm -rf '${tmpdir}'" RETURN

  rpm2cpio "${rpm_file}" | cpio -idm -D "${tmpdir}" --quiet 2>/dev/null

  local fail=0
  while IFS= read -r -d '' bin; do
    # Skip non-ELF files
    file "${bin}" | grep -q ELF || continue
    local needed
    needed="$(readelf -d "${bin}" 2>/dev/null | grep '(NEEDED)' || true)"
    if [[ -n "${needed}" ]]; then
      echo -e "  ${RED}DYNAMIC${NC}: $(basename "${rpm_file}") → $(basename "${bin}")"
      echo "    ${needed}"
      fail=1
    else
      echo -e "  ${GREEN}STATIC OK${NC}: $(basename "${bin}")"
    fi
  done < <(find "${tmpdir}" -type f -print0)

  # Check for GLIBC versioned symbols
  while IFS= read -r -d '' bin; do
    file "${bin}" | grep -q ELF || continue
    local glibc_syms
    glibc_syms="$(objdump -p "${bin}" 2>/dev/null | grep 'GLIBC_' || true)"
    if [[ -n "${glibc_syms}" ]]; then
      echo -e "  ${RED}GLIBC SYMBOLS found${NC}: $(basename "${bin}")"
      echo "${glibc_syms}"
      fail=1
    fi
  done < <(find "${tmpdir}" -type f -print0)

  return "${fail}"
}

# ─── Collect and verify all output RPMs ───────────────────────────────────────
verify_all() {
  header "Verification: Static Linkage Checks"
  local overall_fail=0
  local rpm_dir="${HOME}/rpmbuild/RPMS"

  for arch in "${ARCHS[@]}"; do
    for spec in "${SPECS[@]}"; do
      local rpm_file
      rpm_file="$(find_latest_rpm "${rpm_dir}" "${spec}" "${arch}")"
      if [[ -z "${rpm_file}" ]]; then
        warn "RPM not found for ${spec}/${arch} under ${rpm_dir}"
        continue
      fi
      echo -e "\n${BOLD}Checking:${NC} ${rpm_file}"
      verify_static "${rpm_file}" || overall_fail=1
    done
  done

  if [[ "${overall_fail}" -eq 0 ]]; then
    echo -e "\n${GREEN}${BOLD}All binaries are fully statically linked. No glibc dependency.${NC}"
  else
    echo -e "\n${RED}${BOLD}Static check FAILED. See output above.${NC}"
    return 1
  fi
}

# ─── Print summary of built RPMs ──────────────────────────────────────────────
print_summary() {
  header "Build Summary"
  local rpm_dir="${HOME}/rpmbuild/RPMS"
  printf "%-45s  %-8s  %s\n" "Package" "Arch" "Size"
  printf "%-45s  %-8s  %s\n" "-------" "----" "----"
  for arch in "${ARCHS[@]}"; do
    for spec in "${SPECS[@]}"; do
      local rpm_file
      rpm_file="$(find_latest_rpm "${rpm_dir}" "${spec}" "${arch}")"
      if [[ -n "${rpm_file}" ]]; then
        local size
        size="$(du -h "${rpm_file}" | cut -f1)"
        printf "%-45s  %-8s  %s\n" "$(basename "${rpm_file}")" "${arch}" "${size}"
      fi
    done
  done

  echo ""
  info "RPMs are in: ${rpm_dir}/"
  info "Copy them out with:"
  echo "  mkdir -p output && cp ${rpm_dir}/**/*.rpm output/"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
header "OpenSSH Static RPM Builder"
info "Versions: OpenSSH=${OPENSSH_VER} OpenSSL=${OPENSSL_VER} zlib=${ZLIB_VER} Zig=${ZIG_VER}"
info "Targets:  ${ARCHS[*]}"
info "Packages: ${SPECS[*]}"

check_deps
setup_rpm_tree

for arch in "${ARCHS[@]}"; do
  for spec in "${SPECS[@]}"; do
    build_rpm "${spec}" "${arch}"
  done
done

verify_all
print_summary
