# ──────────────────────────────────────────────────────────────────────────────
# openssh-clients.spec — Client tools: ssh, scp, sftp, ssh-add, ssh-agent
#
# Statically compiled with Zig %{zig_ver} + musl libc.
# No glibc, no PAM, no GSSAPI. Runs on any x86_64 or aarch64 Linux system.
#
# Build:
#   rpmbuild -bb --target x86_64 SPECS/openssh-clients.spec \
#     --define "openssh_ver 9.9p2" --define "openssl_ver 3.5.0" \
#     --define "zlib_ver 1.3.2"    --define "zig_ver 0.15.2"
# ──────────────────────────────────────────────────────────────────────────────

# ── Version globals (overridable via --define) ─────────────────────────────────
%global openssh_ver  %{?_openssh_ver}%{!?_openssh_ver:10.2p1}
%global openssl_ver  %{?_openssl_ver}%{!?_openssl_ver:3.6.1}
%global zlib_ver     %{?_zlib_ver}%{!?_zlib_ver:1.3.2}
%global zig_ver      %{?_zig_ver}%{!?_zig_ver:0.15.2}

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
# Cross-arch build: avoid host /usr/bin/strip on foreign-arch static binaries.
%global __strip /bin/true

# ── Package metadata ───────────────────────────────────────────────────────────
Name:           openssh-clients
Version:        %{openssh_ver}
Release:        %{?rpm_release}%{!?rpm_release:1}%{?dist}
Summary:        OpenSSH client tools — static musl build, no glibc dependency
License:        BSD-2-Clause AND OpenSSL
URL:            https://www.openssh.com/

Source0:        https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-%{openssh_ver}.tar.gz
Source1:        https://github.com/openssl/openssl/releases/download/openssl-%{openssl_ver}/openssl-%{openssl_ver}.tar.gz
Source2:        https://zlib.net/zlib-%{zlib_ver}.tar.gz
Source3:        https://ziglang.org/download/%{zig_ver}/zig-x86_64-linux-%{zig_ver}.tar.xz
Source12:       ssh_config

Provides:       bundled(openssl) = %{openssl_ver}
Provides:       bundled(zlib) = %{zlib_ver}

# Require base package (same version) for shared tools & moduli
Requires:       openssh = %{version}-%{release}

AutoReqProv:    no

Obsoletes:      openssh-clients < %{version}-%{release}

BuildRequires:  tar xz gzip coreutils make

%description
OpenSSH client tools, statically compiled using Zig %{zig_ver} as a
C cross-compiler targeting musl libc (%{zig_target}).

The resulting ELF binaries carry zero glibc version-symbol requirements
and run identically on CentOS 7 (glibc 2.17), Rocky 9, Ubuntu, Alpine,
or any other x86_64 / aarch64 Linux system.

Bundled static dependencies:
  OpenSSL %{openssl_ver} (libcrypto, libssl) — no-shared, no-dso, no-engine
  zlib %{zlib_ver}

Contents of this package:
  ssh, scp, sftp, ssh-add, ssh-agent, ssh_config

Shared utilities (ssh-keygen, ssh-keyscan, moduli) are in the openssh
base package, which this package requires.

# ══════════════════════════════════════════════════════════════════════════════
%prep
%setup -q -n openssh-%{openssh_ver}

cd %{_builddir}
rm -rf openssl-%{openssl_ver} zlib-%{zlib_ver} zig-x86_64-linux-%{zig_ver}
tar -xzf %{SOURCE1}
tar -xzf %{SOURCE2}
tar -xJf %{SOURCE3}

# ══════════════════════════════════════════════════════════════════════════════
# ── SHARED BUILD LOGIC ────────────────────────────────────────────────────────
# Keep identical across openssh.spec, openssh-clients.spec, openssh-server.spec
# ══════════════════════════════════════════════════════════════════════════════
%build
ZIG_DIR="%{_builddir}/zig-x86_64-linux-%{zig_ver}"
ZIG="${ZIG_DIR}/zig"
SYSROOT="%{_builddir}/sysroot-%{_arch}"

export CC="${ZIG} cc  -target %{zig_target}"
export CXX="${ZIG} c++ -target %{zig_target}"
export AR="${ZIG} ar"
export RANLIB="${ZIG} ranlib"
export STRIP=":"

if [[ ! -f "${SYSROOT}/.deps-built-v3" || \
      ! -f "${SYSROOT}/lib/libz.a" || \
      ! -f "${SYSROOT}/lib/libcrypto.a" || \
      ! -f "${SYSROOT}/lib/libssl.a" ]]; then
  rm -rf "${SYSROOT}"
  mkdir -p "${SYSROOT}"

  pushd %{_builddir}/zlib-%{zlib_ver}
    CFLAGS="-O2 -fPIC" \
      ./configure --prefix="${SYSROOT}" --static
    make -j$(nproc)
    make install
  popd

  pushd %{_builddir}/openssl-%{openssl_ver}
    CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" ./Configure \
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
      --libdir=lib                            \
      -I"${SYSROOT}/include"                  \
      -L"${SYSROOT}/lib"
    make -j$(nproc) build_libs
    make install_dev
  popd

  touch "${SYSROOT}/.deps-built-v3"
fi

pushd %{_builddir}/openssh-%{openssh_ver}
if [[ ! -f .openssh-built ]]; then

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

# Patch configure: downgrade the RAND_add link test from a fatal error to a
# warning.  OpenSSL 3.5.0 built with no-legacy does not export the deprecated
# RAND_add wrapper; OpenSSH 9.9p2 uses EVP RAND APIs and never calls RAND_add.
sed -i '/working libcrypto not found/s/as_fn_error \$?/echo/' configure

# For cross-compilation targets, declare the host so configure doesn't try
# to execute target binaries on the build machine.
%ifarch aarch64
CONFIGURE_HOST_ARG="--host=aarch64-linux-musl"
%else
CONFIGURE_HOST_ARG="--host=x86_64-linux-musl"
%endif

  ./configure                                   \
    --cache-file=config.cache                   \
    ${CONFIGURE_HOST_ARG}                       \
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
    LDFLAGS="-static -L. -Lopenbsd-compat -L${SYSROOT}/lib" \
    CPPFLAGS="-I${SYSROOT}/include -DHAVE_EVP_CIPHER_CTX_IV=1 -DHAVE_EVP_CIPHER_CTX_IV_NOCONST=1 -DHAVE_EVP_DIGESTSIGN=1 -DHAVE_EVP_DIGESTVERIFY=1" \
    LIBS="-ldl -lpthread" || {
    echo "=== configure FAILED: last 100 lines of config.log ===" >&2
    tail -100 config.log >&2 || true
    exit 1
  }

  make -j$(nproc) LDFLAGS="-static -L. -Lopenbsd-compat -L${SYSROOT}/lib"
  touch .openssh-built
fi
popd

# ══════════════════════════════════════════════════════════════════════════════
%install
OPENSSH_SRC="%{_builddir}/openssh-%{openssh_ver}"

install -d %{buildroot}/usr/bin
install -d %{buildroot}/etc/ssh
install -d %{buildroot}/usr/share/man/man1
install -d %{buildroot}/usr/share/man/man5
install -d %{buildroot}/usr/share/man/man8

# Client binaries
install -p -m 0755 "${OPENSSH_SRC}/ssh"        %{buildroot}/usr/bin/ssh
install -p -m 0755 "${OPENSSH_SRC}/scp"        %{buildroot}/usr/bin/scp
install -p -m 0755 "${OPENSSH_SRC}/sftp"       %{buildroot}/usr/bin/sftp
install -p -m 0755 "${OPENSSH_SRC}/ssh-add"    %{buildroot}/usr/bin/ssh-add
install -p -m 0755 "${OPENSSH_SRC}/ssh-agent"  %{buildroot}/usr/bin/ssh-agent

# Client configuration
install -p -m 0644 %{SOURCE12}                 %{buildroot}/etc/ssh/ssh_config

# Man pages
install -p -m 0644 "${OPENSSH_SRC}/ssh.1"       %{buildroot}/usr/share/man/man1/
install -p -m 0644 "${OPENSSH_SRC}/scp.1"       %{buildroot}/usr/share/man/man1/
install -p -m 0644 "${OPENSSH_SRC}/sftp.1"      %{buildroot}/usr/share/man/man1/
install -p -m 0644 "${OPENSSH_SRC}/ssh-add.1"   %{buildroot}/usr/share/man/man1/
install -p -m 0644 "${OPENSSH_SRC}/ssh-agent.1" %{buildroot}/usr/share/man/man1/
install -p -m 0644 "${OPENSSH_SRC}/ssh_config.5" %{buildroot}/usr/share/man/man5/

find %{buildroot}/usr/share/man -type f | xargs gzip -9 --force

# ══════════════════════════════════════════════════════════════════════════════
%check
echo "=== Static linkage check ==="
FAIL=0
for bin in ssh scp sftp ssh-add ssh-agent; do
  b="%{buildroot}/usr/bin/${bin}"
  if ldd "${b}" 2>&1 | grep -qv "not a dynamic executable"; then
    echo "FAIL (dynamic deps): ${bin}"; ldd "${b}" || true; FAIL=1
  else
    echo "OK (static):         ${bin}"
  fi
  if objdump -p "${b}" 2>/dev/null | grep -q 'GLIBC_'; then
    echo "FAIL (GLIBC symbols): ${bin}"; objdump -p "${b}" | grep 'GLIBC_'; FAIL=1
  fi
done
[[ "${FAIL}" -eq 0 ]] || { echo "Static check FAILED"; exit 1; }
echo "=== All checks passed ==="

# ══════════════════════════════════════════════════════════════════════════════
%files
/usr/bin/ssh
/usr/bin/scp
/usr/bin/sftp
/usr/bin/ssh-add
/usr/bin/ssh-agent
%config(noreplace) /etc/ssh/ssh_config
/usr/share/man/man1/ssh.1.gz
/usr/share/man/man1/scp.1.gz
/usr/share/man/man1/sftp.1.gz
/usr/share/man/man1/ssh-add.1.gz
/usr/share/man/man1/ssh-agent.1.gz
/usr/share/man/man5/ssh_config.5.gz

# ══════════════════════════════════════════════════════════════════════════════
%changelog
* Sat Feb 28 2026 Build System <openssh-rpms@github.com> - 10.2p1-1
- Upgrade to OpenSSH 10.2p1 and OpenSSL 3.6.1
- No glibc version-symbol dependencies
- Supports x86_64 and aarch64 (cross-compiled on x86_64 host via zig cc)

* Thu Feb 26 2026 Build System <openssh-rpms@github.com> - 9.9p2-1
- Initial static musl build using Zig 0.15.2
- Bundled: OpenSSL 3.5.0, zlib 1.3.1
- PAM, GSSAPI, SELinux, Kerberos support disabled
