# ──────────────────────────────────────────────────────────────────────────────
# openssh.spec — Base package: shared utilities (ssh-keygen, ssh-keyscan, etc.)
#
# Statically compiled with Zig %{zig_ver} + musl libc.
# No glibc, no PAM, no GSSAPI. Runs on any x86_64 or aarch64 Linux system.
#
# Build:
#   rpmbuild -bb --target x86_64 SPECS/openssh.spec \
#     --define "openssh_ver 9.9p2" --define "openssl_ver 3.5.0" \
#     --define "zlib_ver 1.3.2"    --define "zig_ver 0.15.2"
# ──────────────────────────────────────────────────────────────────────────────

# ── Version globals (overridable via --define) ─────────────────────────────────
%global openssh_ver  %{?_openssh_ver}%{!?_openssh_ver:9.9p2}
%global openssl_ver  %{?_openssl_ver}%{!?_openssl_ver:3.5.0}
%global zlib_ver     %{?_zlib_ver}%{!?_zlib_ver:1.3.2}
%global zig_ver      %{?_zig_ver}%{!?_zig_ver:0.15.2}

# Allow callers to pass version via plain --define "openssh_ver X.Yp2"
%{?openssh_ver: %global openssh_ver %{openssh_ver}}
%{?openssl_ver: %global openssl_ver %{openssl_ver}}
%{?zlib_ver:    %global zlib_ver    %{zlib_ver}}
%{?zig_ver:     %global zig_ver     %{zig_ver}}

# ── Architecture → Zig / OpenSSL target mapping ───────────────────────────────
%ifarch x86_64
%global zig_target     x86_64-linux-musl
%global openssl_target linux-x86_64
%else
%ifarch aarch64
%global zig_target     aarch64-linux-musl
%global openssl_target linux-aarch64
%else
%{error: Unsupported architecture '%{_arch}'. Supported: x86_64, aarch64}
%endif
%endif

# Use bash for all RPM script sections (%build, %install, %check, etc.)
# Ubuntu's /bin/sh is dash which lacks [[ ]] and pushd/popd.
%global _buildshell /bin/bash

# ── Package metadata ───────────────────────────────────────────────────────────
Name:           openssh
Version:        %{openssh_ver}
Release:        %{?rpm_release}%{!?rpm_release:1}%{?dist}
Summary:        OpenSSH shared utilities — static musl build, no glibc dependency
License:        BSD-2-Clause AND OpenSSL
URL:            https://www.openssh.com/

Source0:        https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-%{openssh_ver}.tar.gz
Source1:        https://github.com/openssl/openssl/releases/download/openssl-%{openssl_ver}/openssl-%{openssl_ver}.tar.gz
Source2:        https://zlib.net/zlib-%{zlib_ver}.tar.gz
Source3:        https://ziglang.org/download/%{zig_ver}/zig-x86_64-linux-%{zig_ver}.tar.xz

# Declare bundled libraries so RPM auditors know they are intentional
Provides:       bundled(openssl) = %{openssl_ver}
Provides:       bundled(zlib) = %{zlib_ver}

# Static binary: no shared-library runtime deps; disable auto-detection
AutoReqProv:    no

# Upgrade path from distro-provided openssh
Obsoletes:      openssh < %{version}-%{release}

BuildRequires:  tar xz gzip coreutils make

%description
OpenSSH shared utilities, statically compiled using Zig %{zig_ver} as a
C cross-compiler targeting musl libc (%{zig_target}).

The resulting ELF binaries carry zero glibc version-symbol requirements
and run identically on CentOS 7 (glibc 2.17), Rocky 9, Ubuntu, Alpine,
or any other x86_64 / aarch64 Linux system.

Bundled static dependencies:
  OpenSSL %{openssl_ver} (libcrypto, libssl) — no-shared, no-dso, no-engine
  zlib %{zlib_ver}

Contents of this base package:
  ssh-keygen, ssh-keyscan, sftp-server, ssh-keysign, moduli

PAM, GSSAPI, Kerberos and SELinux support are intentionally omitted.
Authentication is via public-key / certificate only.

# ══════════════════════════════════════════════════════════════════════════════
%prep
# Unpack OpenSSH (main source) — %setup creates %{_builddir}/openssh-%{openssh_ver}/
%setup -q -n openssh-%{openssh_ver}

# Unpack sibling tarballs into %{_builddir}
cd %{_builddir}
tar -xzf %{SOURCE1}   # openssl-%{openssl_ver}
tar -xzf %{SOURCE2}   # zlib-%{zlib_ver}
tar -xJf %{SOURCE3}   # zig-x86_64-linux-%{zig_ver}

# ══════════════════════════════════════════════════════════════════════════════
# ── SHARED BUILD LOGIC ────────────────────────────────────────────────────────
# Keep this section identical across openssh.spec, openssh-clients.spec,
# and openssh-server.spec. All three produce the same build artefacts;
# only the %install and %files sections differ.
# ══════════════════════════════════════════════════════════════════════════════
%build
# ── Toolchain ─────────────────────────────────────────────────────────────────
ZIG_DIR="%{_builddir}/zig-x86_64-linux-%{zig_ver}"
ZIG="${ZIG_DIR}/zig"
SYSROOT="%{_builddir}/sysroot-%{_arch}"

export CC="${ZIG} cc  -target %{zig_target}"
export CXX="${ZIG} c++ -target %{zig_target}"
export AR="${ZIG} ar"
export RANLIB="${ZIG} ranlib"
export STRIP=":"  # disable strip; RPM handles it

# ── Build zlib (skip if sysroot sentinel exists from a prior spec build) ───────
if [[ ! -f "${SYSROOT}/.deps-built" ]]; then
  mkdir -p "${SYSROOT}"

  # ── zlib ────────────────────────────────────────────────────────────────────
  pushd %{_builddir}/zlib-%{zlib_ver}
    CFLAGS="-O2 -fPIC" \
      ./configure --prefix="${SYSROOT}" --static
    make -j$(nproc)
    make install
  popd

  # ── OpenSSL ─────────────────────────────────────────────────────────────────
  pushd %{_builddir}/openssl-%{openssl_ver}
    ./Configure \
      %{openssl_target}   \
      no-shared           \
      no-dso              \
      no-engine           \
      no-fips             \
      no-tests            \
      no-legacy           \
      -static             \
      --prefix="${SYSROOT}"                   \
      --openssldir="${SYSROOT}/etc/ssl"       \
      -I"${SYSROOT}/include"                  \
      -L"${SYSROOT}/lib"
    make -j$(nproc) build_libs
    make install_dev   # installs headers + static libs only
  popd

  touch "${SYSROOT}/.deps-built"
fi

# ── OpenSSH ───────────────────────────────────────────────────────────────────
# Build in-tree; skip if already done (sentinel .openssh-built).
pushd %{_builddir}/openssh-%{openssh_ver}
if [[ ! -f .openssh-built ]]; then

  # Pre-seed configure cache so AC_TRY_RUN checks succeed for musl targets
  cat > config.cache << 'CACHE_EOF'
ac_cv_func_setresuid=yes
ac_cv_func_setresgid=yes
ac_cv_func_setreuid=yes
ac_cv_func_setregid=yes
ac_cv_have_decl_ai_numericserv=yes
ac_cv_func_snprintf_percent_m=yes
ac_cv_func_b64_ntop=no
ac_cv_func_b64_pton=no
ac_cv_have_control_in_msghdr=yes
ac_cv_have_accrights_in_msghdr=no
ac_cv_have_broken_snprintf=no
ac_cv_have_broken_strnvis=no
ac_cv_path_login_program=/bin/login
ac_cv_func_pam_getenvlist=no
ac_cv_func_pam_start=no
ac_cv_lib_pam_pam_start=no
ac_cv_func_getaddrinfo=yes
ac_cv_func_gai_strerror=yes
ac_cv_func_freeaddrinfo=yes
CACHE_EOF

  ./configure                                   \
    --cache-file=config.cache                   \
    --prefix=/usr                               \
    --sbindir=/usr/sbin                         \
    --libexecdir=/usr/libexec/openssh           \
    --sysconfdir=/etc/ssh                       \
    --datadir=/usr/share/openssh                \
    --with-pid-dir=/run                         \
    --with-ssl-dir="${SYSROOT}"                 \
    --with-zlib="${SYSROOT}"                    \
    --without-pam                               \
    --without-gssapi                            \
    --without-selinux                           \
    --without-systemd                           \
    --without-kerberos5                         \
    --disable-pkcs11                            \
    --disable-strip                             \
    LDFLAGS="-static -static-libgcc -L${SYSROOT}/lib"   \
    CPPFLAGS="-I${SYSROOT}/include"                      \
    LIBS="-ldl -lpthread"

  make -j$(nproc)
  touch .openssh-built
fi
popd

# ══════════════════════════════════════════════════════════════════════════════
%install
OPENSSH_SRC="%{_builddir}/openssh-%{openssh_ver}"

install -d %{buildroot}/usr/bin
install -d %{buildroot}/usr/libexec/openssh
install -d %{buildroot}/etc/ssh
install -d %{buildroot}/usr/share/man/man1
install -d %{buildroot}/usr/share/man/man8

# Base-package binaries
install -p -m 0755 "${OPENSSH_SRC}/ssh-keygen"    %{buildroot}/usr/bin/ssh-keygen
install -p -m 0755 "${OPENSSH_SRC}/ssh-keyscan"   %{buildroot}/usr/bin/ssh-keyscan

# SetUID helper for host-based auth (owned root, executable by all)
install -p -m 4711 "${OPENSSH_SRC}/ssh-keysign"   %{buildroot}/usr/libexec/openssh/ssh-keysign

# SFTP server subsystem (used by sshd; lives in base package so client only
# installs are still useful for scripted SFTP)
install -p -m 0755 "${OPENSSH_SRC}/sftp-server"   %{buildroot}/usr/libexec/openssh/sftp-server

# Diffie-Hellman moduli
install -p -m 0640 "${OPENSSH_SRC}/moduli"         %{buildroot}/etc/ssh/moduli

# Man pages
install -p -m 0644 "${OPENSSH_SRC}/ssh-keygen.1"   %{buildroot}/usr/share/man/man1/
install -p -m 0644 "${OPENSSH_SRC}/ssh-keyscan.1"  %{buildroot}/usr/share/man/man1/
install -p -m 0644 "${OPENSSH_SRC}/sftp-server.8"  %{buildroot}/usr/share/man/man8/
install -p -m 0644 "${OPENSSH_SRC}/ssh-keysign.8"  %{buildroot}/usr/share/man/man8/

find %{buildroot}/usr/share/man -type f | xargs gzip -9 --force

# ══════════════════════════════════════════════════════════════════════════════
%check
echo "=== Static linkage check ==="
FAIL=0
for bin in \
    %{buildroot}/usr/bin/ssh-keygen   \
    %{buildroot}/usr/bin/ssh-keyscan  \
    %{buildroot}/usr/libexec/openssh/ssh-keysign  \
    %{buildroot}/usr/libexec/openssh/sftp-server;
do
  name="$(basename "${bin}")"
  # ldd returns 1 and prints "not a dynamic executable" for static binaries
  if ldd "${bin}" 2>&1 | grep -qv "not a dynamic executable"; then
    echo "FAIL (dynamic deps found): ${name}"
    ldd "${bin}" || true
    FAIL=1
  else
    echo "OK (static):              ${name}"
  fi
  if objdump -p "${bin}" 2>/dev/null | grep -q 'GLIBC_'; then
    echo "FAIL (GLIBC symbols):    ${name}"
    objdump -p "${bin}" | grep 'GLIBC_'
    FAIL=1
  fi
done
[[ "${FAIL}" -eq 0 ]] || { echo "Static check FAILED"; exit 1; }
echo "=== All checks passed ==="

# ══════════════════════════════════════════════════════════════════════════════
%files
/usr/bin/ssh-keygen
/usr/bin/ssh-keyscan
%attr(4711, root, root) /usr/libexec/openssh/ssh-keysign
/usr/libexec/openssh/sftp-server
%config(noreplace) %attr(0640, root, root) /etc/ssh/moduli
/usr/share/man/man1/ssh-keygen.1.gz
/usr/share/man/man1/ssh-keyscan.1.gz
/usr/share/man/man8/sftp-server.8.gz
/usr/share/man/man8/ssh-keysign.8.gz

# ══════════════════════════════════════════════════════════════════════════════
%changelog
* Thu Feb 26 2026 Build System <openssh-rpms@github.com> - 9.9p2-1
- Initial static musl build using Zig 0.15.2
- Bundled: OpenSSL 3.5.0, zlib 1.3.1
- PAM, GSSAPI, SELinux, Kerberos support disabled
- No glibc version-symbol dependencies
- Supports x86_64 and aarch64 (cross-compiled on x86_64 host via zig cc)
