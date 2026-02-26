// build.zig — OpenSSH static RPM build orchestrator
//
// Replaces Makefile. Requires Zig 0.15.2+ (same toolchain used for compilation).
//
// Steps:
//   zig build              — fetch + build RPMs for host arch (x86_64) + collect output
//   zig build fetch        — download & SHA-256 verify all source tarballs
//   zig build fetch-force  — force re-download all tarballs
//   zig build rpm          — build RPMs for -Darch= target (default: x86_64)
//   zig build docker       — build RPMs inside a Docker container
//   zig build check        — verify all built RPMs are fully statically linked
//   zig build check-deps   — show RPM Requires for all built packages
//   zig build clean        — remove build output (keeps downloaded tarballs)
//   zig build distclean    — remove build output AND downloaded tarballs
//
// Options (pass as -Dname=value):
//   -Dopenssh-ver=9.9p2      OpenSSH version
//   -Dopenssl-ver=3.5.0      OpenSSL version
//   -Dzlib-ver=1.3.1         zlib version
//   -Dzig-ver=0.15.2         Zig toolchain version (used inside RPM spec)
//   -Drpm-release=1          RPM release number
//   -Darch=x86_64            Target arch: x86_64 | aarch64 | all
//   -Ddocker-image=rockylinux:9  Docker image for the 'docker' step
//   -Doutput-dir=output      Directory to collect built RPMs into

const std = @import("std");

pub fn build(b: *std.Build) void {
    // ── Version options ────────────────────────────────────────────────────────
    const openssh_ver  = b.option([]const u8, "openssh-ver",   "OpenSSH version")                            orelse "9.9p2";
    const openssl_ver  = b.option([]const u8, "openssl-ver",   "OpenSSL version")                            orelse "3.5.0";
    const zlib_ver     = b.option([]const u8, "zlib-ver",      "zlib version")                               orelse "1.3.1";
    const zig_ver      = b.option([]const u8, "zig-ver",       "Zig toolchain version (used in RPM spec)")   orelse "0.15.2";
    const rpm_release  = b.option([]const u8, "rpm-release",   "RPM release number")                         orelse "1";
    const arch         = b.option([]const u8, "arch",          "Target arch: x86_64 | aarch64 | all")        orelse "x86_64";
    const docker_img   = b.option([]const u8, "docker-image",  "Docker image for the 'docker' step")         orelse "rockylinux:9";
    const output_dir   = b.option([]const u8, "output-dir",    "Directory to collect built RPMs into")       orelse "output";

    // ── fetch ──────────────────────────────────────────────────────────────────
    // zig build fetch
    const fetch_cmd = b.addSystemCommand(&.{ "bash", "scripts/fetch-sources.sh" });
    fetch_cmd.setEnvironmentVariable("OPENSSH_VER", openssh_ver);
    fetch_cmd.setEnvironmentVariable("OPENSSL_VER", openssl_ver);
    fetch_cmd.setEnvironmentVariable("ZLIB_VER",    zlib_ver);
    fetch_cmd.setEnvironmentVariable("ZIG_VER",     zig_ver);

    const fetch_step = b.step("fetch", "Download and SHA-256 verify all source tarballs into SOURCES/");
    fetch_step.dependOn(&fetch_cmd.step);

    // ── fetch-force ────────────────────────────────────────────────────────────
    // zig build fetch-force
    const fetch_force_cmd = b.addSystemCommand(&.{ "bash", "scripts/fetch-sources.sh", "--force" });
    fetch_force_cmd.setEnvironmentVariable("OPENSSH_VER", openssh_ver);
    fetch_force_cmd.setEnvironmentVariable("OPENSSL_VER", openssl_ver);
    fetch_force_cmd.setEnvironmentVariable("ZLIB_VER",    zlib_ver);
    fetch_force_cmd.setEnvironmentVariable("ZIG_VER",     zig_ver);

    const fetch_force_step = b.step("fetch-force", "Force re-download all source tarballs (even if already present)");
    fetch_force_step.dependOn(&fetch_force_cmd.step);

    // ── rpm ────────────────────────────────────────────────────────────────────
    // zig build rpm  (or zig build for default)
    // Depends on fetch so sources are always present before building.
    const rpm_cmd = b.addSystemCommand(&.{ "bash", "scripts/build-local.sh", arch });
    rpm_cmd.setEnvironmentVariable("OPENSSH_VER", openssh_ver);
    rpm_cmd.setEnvironmentVariable("OPENSSL_VER", openssl_ver);
    rpm_cmd.setEnvironmentVariable("ZLIB_VER",    zlib_ver);
    rpm_cmd.setEnvironmentVariable("ZIG_VER",     zig_ver);
    rpm_cmd.setEnvironmentVariable("RPM_RELEASE", rpm_release);
    rpm_cmd.step.dependOn(&fetch_cmd.step); // always fetch first

    // Collect RPMs into output/ after the build completes.
    const collect_script = b.fmt(
        \\mkdir -p {s}
        \\find "$HOME/rpmbuild/RPMS" -name '*.rpm' -exec cp -v {{}} {s}/ \; 2>/dev/null || true
        \\echo ""
        \\echo "=== Built RPMs in {s}/ ==="
        \\ls -lh {s}/*.rpm 2>/dev/null || echo "(none found)"
    , .{ output_dir, output_dir, output_dir, output_dir });
    const collect_cmd = b.addSystemCommand(&.{ "bash", "-c", collect_script });
    collect_cmd.step.dependOn(&rpm_cmd.step); // collect after build

    const rpm_step = b.step("rpm", "Build RPMs (-Darch=x86_64|aarch64|all). Implies fetch.");
    rpm_step.dependOn(&collect_cmd.step);

    // ── default step: zig build == fetch + rpm + collect ──────────────────────
    b.default_step.dependOn(rpm_step);

    // ── check ──────────────────────────────────────────────────────────────────
    // zig build check
    const check_script = b.fmt(
        \\set -euo pipefail
        \\RED='\033[0;31m' GREEN='\033[0;32m' NC='\033[0m'
        \\FAIL=0
        \\for rpm in $(find {s} "$HOME/rpmbuild/RPMS" -name '*.rpm' 2>/dev/null | sort); do
        \\  echo ""
        \\  echo "Checking: $rpm"
        \\  tmpdir=$(mktemp -d)
        \\  rpm2cpio "$rpm" | cpio -idm -D "$tmpdir" --quiet 2>/dev/null
        \\  while IFS= read -r -d '' bin; do
        \\    file "$bin" | grep -q ELF || continue
        \\    needed=$(readelf -d "$bin" 2>/dev/null | grep '(NEEDED)' || true)
        \\    if [[ -n "$needed" ]]; then
        \\      echo -e "  ${{RED}}FAIL(dynamic)${{NC}}: $(basename "$bin")"
        \\      echo "    $needed"
        \\      FAIL=1
        \\    else
        \\      echo -e "  ${{GREEN}}OK(static)${{NC}}:    $(basename "$bin")"
        \\    fi
        \\    glibc=$(objdump -p "$bin" 2>/dev/null | grep 'GLIBC_' || true)
        \\    if [[ -n "$glibc" ]]; then
        \\      echo -e "  ${{RED}}FAIL(GLIBC syms)${{NC}}: $(basename "$bin") — $glibc"
        \\      FAIL=1
        \\    fi
        \\  done < <(find "$tmpdir" -type f -print0)
        \\  rm -rf "$tmpdir"
        \\done
        \\echo ""
        \\if [[ "$FAIL" -eq 0 ]]; then
        \\  echo -e "${{GREEN}}All static checks PASSED — zero glibc dependency${{NC}}"
        \\else
        \\  echo -e "${{RED}}Static check FAILED${{NC}}"
        \\  exit 1
        \\fi
    , .{ output_dir });
    const check_cmd = b.addSystemCommand(&.{ "bash", "-c", check_script });

    const check_step = b.step("check", "Verify built RPMs are fully statically linked (no glibc, no NEEDED)");
    check_step.dependOn(&check_cmd.step);

    // ── check-deps ─────────────────────────────────────────────────────────────
    // zig build check-deps
    const check_deps_script = b.fmt(
        \\for rpm in $(find {s} "$HOME/rpmbuild/RPMS" -name '*.rpm' 2>/dev/null | sort); do
        \\  echo ""
        \\  echo "=== $(basename $rpm) ==="
        \\  rpm -qp --requires "$rpm" 2>/dev/null
        \\done
    , .{ output_dir });
    const check_deps_cmd = b.addSystemCommand(&.{ "bash", "-c", check_deps_script });

    const check_deps_step = b.step("check-deps", "Show RPM Requires for all built packages");
    check_deps_step.dependOn(&check_deps_cmd.step);

    // ── docker ─────────────────────────────────────────────────────────────────
    // zig build docker
    // Uses $PWD (resolved at zig-build runtime) for volume mounts.
    const docker_script = b.fmt(
        \\set -euo pipefail
        \\echo "=== Building in Docker ({s}) ==="
        \\mkdir -p {s}
        \\docker run --rm \
        \\  -v "$(pwd):/workspace:ro" \
        \\  -v "$(pwd)/{s}:/output" \
        \\  -e OPENSSH_VER={s} \
        \\  -e OPENSSL_VER={s} \
        \\  -e ZLIB_VER={s} \
        \\  -e ZIG_VER={s} \
        \\  -e RPM_RELEASE={s} \
        \\  {s} \
        \\  bash -c "set -e
        \\    dnf install -y --nodocs rpm-build rpmdevtools tar xz gzip coreutils binutils file findutils 2>&1 | tail -5
        \\    cp -r /workspace /build && cd /build
        \\    bash scripts/fetch-sources.sh
        \\    bash scripts/build-local.sh all
        \\    mkdir -p /output
        \\    find \$HOME/rpmbuild/RPMS -name '*.rpm' -exec cp -v {{}} /output/ \;
        \\    echo 'Docker build complete'"
        \\echo "=== RPMs in {s}/ ==="
        \\ls -lh {s}/*.rpm 2>/dev/null || echo "(none found)"
    , .{
        docker_img,
        output_dir,
        output_dir,
        openssh_ver,
        openssl_ver,
        zlib_ver,
        zig_ver,
        rpm_release,
        docker_img,
        output_dir,
        output_dir,
    });
    const docker_cmd = b.addSystemCommand(&.{ "bash", "-c", docker_script });

    const docker_step = b.step("docker", "Build RPMs inside Docker (-Ddocker-image=rockylinux:9). No host env pollution.");
    docker_step.dependOn(&docker_cmd.step);

    // ── clean ──────────────────────────────────────────────────────────────────
    // zig build clean
    const clean_script = b.fmt(
        \\rm -rf {s}
        \\rm -rf "$HOME/rpmbuild/BUILD/openssh-{s}"
        \\rm -rf "$HOME/rpmbuild/BUILD/openssl-{s}"
        \\rm -rf "$HOME/rpmbuild/BUILD/zlib-{s}"
        \\rm -rf "$HOME/rpmbuild/BUILD/sysroot-"*
        \\rm -rf "$HOME/rpmbuild/RPMS" "$HOME/rpmbuild/SRPMS" "$HOME/rpmbuild/BUILDROOT"
        \\echo "Clean complete. SOURCES/ (downloaded tarballs) preserved."
    , .{ output_dir, openssh_ver, openssl_ver, zlib_ver });
    const clean_cmd = b.addSystemCommand(&.{ "bash", "-c", clean_script });

    const clean_step = b.step("clean", "Remove build output (keeps downloaded tarballs in SOURCES/)");
    clean_step.dependOn(&clean_cmd.step);

    // ── distclean ──────────────────────────────────────────────────────────────
    // zig build distclean
    const distclean_script = b.fmt(
        \\rm -rf {s}
        \\rm -rf "$HOME/rpmbuild/BUILD" "$HOME/rpmbuild/RPMS" "$HOME/rpmbuild/SRPMS" "$HOME/rpmbuild/BUILDROOT"
        \\rm -f  SOURCES/openssh-{s}.tar.gz
        \\rm -f  SOURCES/openssl-{s}.tar.gz
        \\rm -f  SOURCES/zlib-{s}.tar.gz
        \\rm -f  SOURCES/zig-x86_64-linux-{s}.tar.xz
        \\rm -f  SOURCES/checksums.sha256
        \\echo "Distclean complete."
    , .{ output_dir, openssh_ver, openssl_ver, zlib_ver, zig_ver });
    const distclean_cmd = b.addSystemCommand(&.{ "bash", "-c", distclean_script });

    const distclean_step = b.step("distclean", "Remove build output AND downloaded source tarballs");
    distclean_step.dependOn(&distclean_cmd.step);

}
