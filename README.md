# 高性能反代系统一键部署

本项目基于 5G NPN + N6 互通架构，在服务器端部署高性能透明反代基础设施，为终端提供智能 DNS 解析与 SNI 透明代理服务。

## 系统要求

### 支持的操作系统

| 发行版 | 版本 |
|--------|------|
| Ubuntu | 20.04 / 22.04 / 24.04 LTS |
| Debian | 11 / 12 / 13 |
| CentOS / Stream | 7 / 8 / 9 |
| AlmaLinux | 8 / 9 |
| Rocky Linux | 8 / 9 |
| RHEL | 8 / 9 |
| Fedora | 39+ |

### 硬件与架构

- **CPU 架构**: x86_64 (`amd64`) 或 ARM64 (`aarch64`)
- **内存**: 建议 ≥ 512 MB
- **网络**: 需要公网 IPv4 地址（用于 Let's Encrypt 证书申请和代理转发）
- **权限**: 必须以 `root` 身份运行安装脚本

## 核心组件

| 组件 | 协议/端口 | 作用 |
|------|-----------|------|
| sniproxy (dlundquist) | TCP 80/443 | SNI 透明代理（HTTP/HTTPS） |
| quic-proxy (自研 Go) | UDP 443 | QUIC SNI 透明代理（HTTP/3） |
| china-dns-race-proxy (自研 Go) | TCP/UDP 127.0.0.1:5301 | ChinaList 上游 DNS 并发竞速与 fallback |
| dnsdist (PowerDNS) | TCP/UDP 53, TCP 853 | 智能 DNS + DoT 服务 |
| Certbot | - | Let's Encrypt 证书自动申请与续期 |

## 访问策略

### DNS / DoT

- **普通 DNS 53 端口**：仅允许 `172.22.0.0/16` 来源访问。
- **DoT 853 端口**：允许所有来源访问，但按来源 IP 区分解析策略。
- **单 IP QPS 限制**：`10000 qps`，超过后由 dnsdist 丢弃。

| 来源 IP | 被墙域名（GFWList） | 国内域名（ChinaList） | 其他海外域名 |
|---------|----------------------|------------------------|--------------|
| `172.22.0.0/16` | 返回服务器本机 IP，进入 TCP/QUIC 代理 | 转发至本机 China DNS 竞速代理 | 转发至海外 DNS 池 |
| 其他来源 | 不做代理劫持，正常海外解析 | 转发至本机 China DNS 竞速代理 | 转发至海外 DNS 池 |

国内 DNS：dnsdist 将 ChinaList 查询转发到本机 `china-dns-race-proxy` (`127.0.0.1:5301`)；该代理同时接受 UDP 和 TCP DNS 请求，兼容 dnsdist 的普通 DNS、TCP DNS 和 DoT 转发。代理会先并发查询 `101.226.4.6`、`218.30.118.6`、`180.76.76.76`、`119.29.29.29` 的 UDP 53。如果国内 UDP 无响应，会在 `150ms` 后改用国内 TCP 53；国内 TCP 也无响应时，才启用海外 fallback（默认 `1.1.1.1`、`8.8.8.8`、`22.22.22.22`），避免单个国内 DNS 不通导致页面长时间卡住。

海外 DNS 池：`1.1.1.1`、`8.8.8.8`、`9.9.9.9`。

ChinaList 查询会强制携带 EDNS Client Subnet：`139.226.48.0/24`，用于让上游按中国大陆客户端位置返回更合适的 IPv4 解析结果。DNS 服务不返回 AAAA 记录，客户端只使用 IPv4。

## 快速开始

### 一键安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN/main/install.sh)"
```

如果服务器没有 `curl`，可用 `wget`：

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/Xiuyixx/5GPN/main/install.sh)"
```

### 手动安装

```bash
# 1. 克隆或上传所有文件到服务器
# 2. 运行安装脚本
chmod +x install.sh
./install.sh
```

安装过程会自动完成：
- 系统检测与依赖安装
- 短混淆域名生成（基于 IP 哈希，4 位纯字母前缀）
- ClouDNS 域名注册提示
- Let's Encrypt 证书申请
- sniproxy (TCP) 编译安装
- quic-proxy (UDP) 编译安装
- china-dns-race-proxy 编译安装
- dnsdist 配置与启动
- GFWList / ChinaList 规则初始化
- 系统网络优化（BBR、fq、TCP buffer、conntrack、THP、journald 限制等）
- 自动续期与规则更新定时任务

### 域名选择

安装脚本会列出可用的 ClouDNS 免费域名后缀，供你手动选择：

```
==================================================
  请选择 ClouDNS 免费域名后缀
==================================================
  1) xxxxxxxx.abrdns.com
  2) xxxxxxxx.cloud-ip.cc
==================================================
```

输入对应序号即可。

### 环境变量（非交互式 / 自动化部署）

如果你希望跳过交互提示，可通过环境变量预设：

```bash
# 方式一：直接指定完整域名（跳过所有域名相关步骤）
export DOMAIN="mydomain.abrdns.com"
./install.sh

# 方式二：指定后缀，前缀仍自动混淆生成
export CLOUDNS_TLD="abrdns.com"
./install.sh

# 方式三：全自动（含 ClouDNS API 自动注册）
export DOMAIN="mydomain.abrdns.com"
export CLOUDNS_ID="your-auth-id"
export CLOUDNS_PASS="your-api-password"
export EMAIL="admin@example.com"
./install.sh
```

### 自定义海外上游 DNS 与反代 resolver

海外上游按来源网络分为两组，均支持逗号或空格分隔：

```bash
export PRIVATE_OVERSEAS_DNS="22.22.22.22"
export PUBLIC_OVERSEAS_DNS="1.1.1.1,8.8.8.8"
export SNIPROXY_DNS="22.22.22.22"
./install.sh
```

`PRIVATE_OVERSEAS_DNS` 用于 `172.22.0.0/16` 专网客户端的 DoT 海外解析；`PUBLIC_OVERSEAS_DNS` 用于非专网客户端的 DoT 海外解析，默认是 `1.1.1.1`、`8.8.8.8`；`SNIPROXY_DNS` 用于 TCP 反代解析后端，默认跟随 `PRIVATE_OVERSEAS_DNS`。旧参数 `OVERSEAS_DNS` 仍可使用，等同于 `PRIVATE_OVERSEAS_DNS`。

安装脚本会保存配置到 `/etc/dnsdist/.overseas_private_dns`、`/etc/dnsdist/.overseas_public_dns`、`/etc/dnsdist/.sniproxy_dns`，后续执行 `./install.sh --update-rules` 或定时更新规则时会继续使用这些上游配置。

TCP 反代会使用单独的 `SNIPROXY_DNS`：安装脚本会把它写入 `/etc/sniproxy.conf` 的 `resolver`，并强制 `mode ipv4_only`，避免 sniproxy 绕过自定义解析或优先连接 AAAA 地址。

### 本地补充 GFWList

如果官方 GFWList 缺少需要 DoT 劫持的域名，可以把域名写入 `/etc/dnsdist/gfwlist-extra-local.txt`，每行一个域名，支持 `#` 注释。执行 `./install.sh --update-rules` 或等待定时任务更新后，这些域名会去重追加到 dnsdist 的 GFWList 规则中。

## 客户端配置

### Android (DoT)
设置 → 网络和互联网 → 私人 DNS → 输入脚本生成的域名

### iOS / iPadOS
安装脚本会自动生成 iOS DNS over TLS 描述文件，并在终端输出二维码。iPhone 扫码后可安装描述文件：

```text
http://your-domain.com:8111/ios-dot.mobileconfig
```

该描述文件只在蜂窝网络下启用本系统 DoT DNS；连接 Wi-Fi 时会自动停用，避免影响局域网或家庭 Wi-Fi 的 DNS 策略。

### Windows / macOS / Linux
在系统网络设置中配置 DNS over TLS，或使用 Stubby、cloudflared 等本地 DoT 转发器指向服务器。

## 命令行接口

```bash
./install.sh --status          # 查看运行状态
./install.sh --update-rules    # 立即更新 GFWList/ChinaList
./install.sh --renew-cert      # 立即续期证书并重载服务
./install.sh -ios              # 重新生成 iOS 描述文件并显示二维码
./install.sh --uninstall       # 卸载所有组件
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 主安装脚本 |
| `quic-proxy.go` | QUIC SNI UDP 代理源码 |
| `china-dns-race-proxy.go` | ChinaList DNS 上游并发竞速代理源码 |
| `sniproxy.conf` | sniproxy 配置文件 |
| `dnsdist.conf.template` | dnsdist 配置模板 |
| `update-rules.sh` | GFWList/ChinaList 更新脚本 |
| `renew-hook.sh` | 证书续期 Hook |

## iOS 描述文件

安装完成后会生成：

| 文件 | 说明 |
|------|------|
| `/opt/proxy-gateway/www/ios-dot.mobileconfig` | iOS DoT 描述文件 |
| `/opt/proxy-gateway/www/ios-dot.qr.txt` | 终端二维码文本 |
| `/opt/proxy-gateway/www/ios-profile-url.txt` | 描述文件下载地址 |

系统会创建 `proxy-gateway-ios-profile.service`，使用 Python 静态文件服务监听 TCP `8111` 端口。二维码和下载地址指向：

```text
http://<安装生成的域名>:8111/ios-dot.mobileconfig
```

描述文件使用 `com.apple.dnsSettings.managed`，协议为 DoT (`TLS`)。`OnDemandRules` 会让 iPhone 仅在蜂窝网络 (`Cellular`) 下连接该 DoT DNS，在 Wi-Fi (`WiFi`) 下断开。

如需重新调出二维码，随时运行：

```bash
./install.sh -ios
```

## 技术说明

### TCP 代理
使用 [dlundquist/sniproxy](https://github.com/dlundquist/sniproxy)（C 语言），基于 SNI/Host 头做 Layer-4/7 透明转发，不解密 TLS，性能极高。

### UDP/QUIC 代理
原版 sniproxy 已于 2023 年弃用，且不支持 UDP/QUIC。本项目附带一个**极简的 Go QUIC SNI 代理**（`quic-proxy.go`），它：
- 监听 UDP 443
- 使用标准 RFC 9000 算法解密 QUIC Initial 包
- 提取 TLS ClientHello 中的 SNI
- 建立到真实后端的 UDP 会话并双向转发

> 注：quic-proxy 仅支持 QUIC v1 (RFC 9000) 的 Initial 包解密。若浏览器使用其他 QUIC 版本，可能会自动回退到 TCP/HTTP2。

### DNS 分流策略

dnsdist 会先检查来源 IP 和查询端口：

- 非 `172.22.0.0/16` 来源访问普通 DNS 53 端口会被丢弃。
- `172.22.0.0/16` 来源访问 DNS/DoT 时，GFWList 域名返回服务器本机 IP，使后续流量进入 sniproxy / quic-proxy。
- 其他来源访问 DoT 时，不做 GFWList 代理劫持，只按 ChinaList / 默认海外 DNS 池正常解析。
- ChinaList 查询会覆盖 ECS 为 `139.226.48.0/24`，再转发到本机 `china-dns-race-proxy`。
- `china-dns-race-proxy` 对国内上游做并发查询，默认 `150ms` 后启动国内 TCP 53 重试，默认 `750ms` 后才启动海外 fallback；如果所有上游都失败，会返回 SERVFAIL，避免客户端一直等待无响应 UDP 包。

### 系统网络优化

安装脚本会写入 `/etc/sysctl.d/99-proxy-gateway.conf` 并立即应用，主要包括：

- 启用 `fq` 队列和 `bbr` 拥塞控制。
- 提高 `somaxconn`、文件句柄、TCP 收发 buffer 和临时端口范围。
- 提高 `nf_conntrack_max` 并缩短部分连接跟踪超时。
- 启用 TCP Fast Open、窗口扩展、SACK、MTU probing。
- 创建 `disable-transparent-huge-pages.service`，开机自动关闭 THP。
- 创建 journald drop-in，限制日志占用空间。

## 安全与合规

- 本系统仅用于企业合法的跨境业务互通。
- 服务器开放端口：22(SSH)、53(DNS)、853(DoT)、8111(iOS 描述文件)。80/443 反代端口仅允许 `172.22.0.0/16` 访问；证书申请或续期时会临时放行公网 80，完成后自动恢复白名单。
- DNS 53 仅允许 `172.22.0.0/16`，DoT 853 面向所有来源但按来源 IP 分流解析。
- 海外 DNS 池会显式发送中性 ECS `0.0.0.0/0` / `::/0`，避免上游递归按服务器公网 IP 生成 `161.129.34.0/24` 这类 ECS。
- 混淆域名可降低被主动探测概率，但无法完全消除服务器 IP 被封禁的风险。

## 故障排查

```bash
# 查看各服务状态
systemctl status sniproxy
systemctl status quic-proxy
systemctl status china-dns-race-proxy
systemctl status dnsdist

# 查看实时日志
journalctl -u sniproxy -f
journalctl -u quic-proxy -f
journalctl -u china-dns-race-proxy -f
journalctl -u dnsdist -f

# 测试 DoT 解析
dig +tls @your-domain.com -p 853 youtube.com

# 测试 sniproxy TCP
curl -I --resolve youtube.com:443:127.0.0.1 https://youtube.com
```
