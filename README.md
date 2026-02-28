# openssh-musl-rpms

使用 [Zig](https://ziglang.org/) 作为 C 交叉编译器、以 **musl libc** 为目标静态编译的 OpenSSH RPM 包。生成的二进制文件不依赖任何 glibc 版本符号，可在任意 x86_64 或 aarch64 Linux 系统上运行——包括 CentOS 7（glibc 2.17）、Rocky 9、Ubuntu、Alpine 等。

## 软件包

| 包名 | 内容 |
|------|------|
| `openssh` | ssh-keygen、ssh-keyscan、sftp-server、ssh-keysign、moduli |
| `openssh-clients` | ssh、scp、sftp、ssh-add、ssh-agent、ssh_config |
| `openssh-server` | sshd、sshd-session、sshd-auth、sshd.service、sshd_config |

## 默认版本

| 组件 | 版本 |
|------|------|
| OpenSSH | 10.2p1 |
| OpenSSL | 3.6.1 |
| zlib    | 1.3.2 |
| Zig     | 0.15.2 |

## 特性

- **无 glibc 依赖** — 静态 musl 构建，可在任意 Linux 发行版上运行
- **无 PAM / GSSAPI / SELinux / Kerberos** — 仅支持公钥 / 证书认证
- **交叉编译** — 在 x86_64 主机上通过 `zig cc` 同时构建 x86_64 和 aarch64（无需 QEMU）
- **内置** OpenSSL 和 zlib（no-shared，静态链接）
- **升级路径** — 覆盖发行版自带的 `openssh` 包（`Obsoletes: openssh < version`）
- **CI 验证** — 每次构建自动验证 RPM 完全静态链接，零 glibc 符号依赖

## 前置要求

需要一台 Linux x86_64 主机，并安装以下工具：

```bash
# RHEL / Rocky / CentOS
dnf install rpm-build rpmdevtools tar xz gzip coreutils binutils file findutils

# Ubuntu / Debian
apt-get install rpm rpm2cpio tar xz-utils gzip coreutils curl binutils file findutils cpio
```

同时需要将 [Zig 0.15.2](https://ziglang.org/download/) 添加到 `$PATH`（用于驱动构建并作为 C 交叉编译器）。

## 快速开始

```bash
# 1. 下载所有源码包（缓存至 SOURCES/）
zig build fetch

# 2. 为宿主架构（x86_64）构建 RPM
zig build rpm

# 构建完成的 RPM 收集到 output/ 目录
ls output/*.rpm
```

## 构建命令

| 命令 | 说明 |
|------|------|
| `zig build` | 下载源码 + 构建 x86_64 RPM + 收集输出 |
| `zig build fetch` | 下载并 SHA-256 校验所有源码包到 `SOURCES/` |
| `zig build fetch-force` | 强制重新下载所有源码包 |
| `zig build rpm` | 为 `-Darch=` 目标构建 RPM（默认 x86_64） |
| `zig build docker` | 在 Docker 容器内构建 RPM（不污染宿主环境） |
| `zig build check` | 验证构建的 RPM 完全静态链接 |
| `zig build check-deps` | 显示所有包的 RPM `Requires` |
| `zig build clean` | 删除构建输出（保留已下载的源码包） |
| `zig build distclean` | 删除构建输出**及**已下载的源码包 |

## 构建选项

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `-Dopenssh-ver` | `10.2p1` | OpenSSH 版本 |
| `-Dopenssl-ver` | `3.6.1` | OpenSSL 版本 |
| `-Dzlib-ver` | `1.3.2` | zlib 版本 |
| `-Dzig-ver` | `0.15.2` | Zig 工具链版本（写入 RPM spec） |
| `-Drpm-release` | `1` | RPM release 编号 |
| `-Darch` | `x86_64` | 目标架构：`x86_64` \| `aarch64` \| `all` |
| `-Ddocker-image` | `rockylinux:9` | Docker 构建镜像 |
| `-Doutput-dir` | `output` | RPM 输出目录 |

示例 — 同时构建两种架构：

```bash
zig build rpm -Darch=all
```

示例 — 指定自定义版本：

```bash
zig build rpm \
  -Dopenssh-ver=10.2p1 \
  -Dopenssl-ver=3.6.1 \
  -Dzlib-ver=1.3.2 \
  -Dzig-ver=0.15.2 \
  -Darch=all \
  -Drpm-release=2
```

## Docker 构建

完全在容器内构建，宿主机无需安装 rpm-build 工具：

```bash
zig build docker
# 指定不同的基础镜像：
zig build docker -Ddocker-image=rockylinux:9
```

## 手动 rpmbuild

也可以直接调用 `rpmbuild`：

```bash
rpmbuild -bb --target x86_64 SPECS/openssh.spec \
  --define "openssh_ver 10.2p1" \
  --define "openssl_ver 3.6.1" \
  --define "zlib_ver 1.3.2" \
  --define "zig_ver 0.15.2"
```

## 安装

```bash
# 服务端（x86_64 示例）
rpm -ivh openssh-10.2p1-1.x86_64.rpm \
         openssh-server-10.2p1-1.x86_64.rpm
systemctl enable --now sshd

# 仅客户端
rpm -ivh openssh-10.2p1-1.x86_64.rpm \
         openssh-clients-10.2p1-1.x86_64.rpm
```

## 验证静态链接

```bash
zig build check
```

或手动验证：

```bash
ldd /usr/sbin/sshd        # 应输出 "not a dynamic executable"
objdump -p /usr/sbin/sshd | grep GLIBC_   # 应无输出
```

## ⚠️ 不支持密码认证

**此包不支持系统密码（`/etc/shadow`）登录，只能使用公钥认证。**

原因：
- 编译时使用 `--without-pam`，无 PAM 支持
- OpenSSH 的密码认证有且仅有两条路：**PAM**（需动态链接 libpam）或直接读 `/etc/shadow`（需 root 权限）
- OpenSSH 10.x 引入进程拆分后，认证阶段（`sshd-auth`）以非特权用户运行，无法读取 `/etc/shadow`
- 因此密码认证**在设计上无法工作**，没有配置可以绕过

### 配置公钥认证

```bash
# 1. 在客户端生成密钥对（如已有可跳过）
ssh-keygen -t ed25519

# 2. 将公钥追加到服务端
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "ssh-ed25519 AAAA...公钥内容..." >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 3. 登录
ssh -i ~/.ssh/id_ed25519 user@host
```

> 如果需要密码登录，请使用发行版自带的动态链接版 openssh（如 `yum install openssh-server`）。

## CI / 发布

- **`build.yml`** — 每次 push / PR 触发，构建 x86_64 和 aarch64，自动验证静态链接，将 RPM 作为构建产物上传（保留 7 天）。
- **`release.yml`** — 推送符合 `v{openssh_ver}-{rpm_release}` 格式的标签（如 `v10.2p1-1`）时触发，验证静态链接后将 6 个 RPM 和 `SHA256SUMS.txt` 发布到 GitHub Releases。

```bash
# 创建发布
git tag v10.2p1-1
git push origin v10.2p1-1
```

## 仓库结构

```
SPECS/
  openssh.spec          # 基础包：ssh-keygen、ssh-keyscan、sftp-server 等
  openssh-clients.spec  # 客户端：ssh、scp、sftp、ssh-add、ssh-agent
  openssh-server.spec   # 服务端：sshd、sshd.service、sshd_config
SOURCES/
  sshd_config           # sshd 默认配置（仅公钥认证）
  ssh_config            # ssh 客户端默认配置
  sshd.service          # systemd 单元文件（Type=simple）
  checksums.sha256      # 所有源码包的 SHA-256 固定哈希
scripts/
  fetch-sources.sh      # 下载并校验源码包（自动加载 checksums.sha256）
  build-local.sh        # 调用 rpmbuild 构建所有 spec 和架构
build.zig               # Zig 构建脚本（编排 fetch + build + check）
.github/
  actions/
    setup-build-env/    # 共享 composite action（安装 rpm-build + Zig）
  workflows/
    build.yml           # PR / push 验证构建
    release.yml         # 标签触发发布
```

## 许可证

本仓库中的 RPM spec 文件和构建脚本以 **MIT 许可证** 发布。

打包的软件保留其各自的许可证：
- OpenSSH — BSD-2-Clause AND OpenSSL
- OpenSSL — Apache-2.0
- zlib — zlib
