# node-deploy

一个面向 VPS 的一键部署脚本，支持 **VLESS-Reality** 和 **Snell**，可单独部署，也可同时部署。

- 同时部署时复用同一个出口 IP / 域名，**端口分别设置**。
- VLESS-Reality 默认使用 **sing-box**，也可切换 **Xray**。
- Snell 使用官方 `snell-server`，默认 `v4.1.1`，可选 `v5.0.1`，兼容 Surge / Stash / Clash.Meta。
- 支持交互式菜单和完整 CLI 参数，适合手动部署和自动化脚本。

> 说明：你需求里写的 “senll” 按 **Snell** 处理。如果你实际指的是 Hysteria2 或其他协议，请告诉我，我可以再改。

---

## 0. 一键命令（推荐，无需上传）

脚本是自包含的，可以直接从 GitHub Raw 拉取运行：

```bash
# curl + 进程替换，交互菜单可用
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh)

# wget 版本
sudo bash <(wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh)

# 先下载再运行
curl -fsSL https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh -o /tmp/node-deploy.sh
sudo bash /tmp/node-deploy.sh

# wget 先下载再运行
wget -qO /tmp/node-deploy.sh https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh
sudo bash /tmp/node-deploy.sh
```

如果 GitHub Raw 访问慢或刚推送后有缓存，可以用 jsDelivr 镜像：

```bash
sudo bash <(curl -fsSL https://cdn.jsdelivr.net/gh/Star7-Files-Hub/Files@latest/sh/deploy.sh)
sudo bash <(wget -qO- https://cdn.jsdelivr.net/gh/Star7-Files-Hub/Files@latest/sh/deploy.sh)
```

Alpine（OpenRC）默认没有 bash，请先安装：

```sh
apk add --no-cache bash curl
bash <(curl -fsSL https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh)
```

或使用 jsDelivr：

```sh
apk add --no-cache bash curl
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/Star7-Files-Hub/Files@latest/sh/deploy.sh)
```

> 不建议用 `curl ... | sudo bash`：管道会把 stdin 占用，交互菜单的 `read` 会读不到键盘输入。用 `bash <(curl ...)` 或先下载再运行即可正常交互。

> **Alpine 上的 Snell 限制**：官方 `snell-server` 依赖 glibc 的 `/lib64/ld-linux-x86-64.so.2`，在 Alpine musl 上会报 `Not a valid dynamic program`。脚本真实运行时会提前拦截并提示。Alpine 上请用 `--mode vless` 只部署 VLESS-Reality；如果必须在 Alpine 上用 Snell，可改用 sing-box 的 Snell 入站（仅 v5/v6 + HTTP 混淆），或换 Debian/Ubuntu 部署官方 Snell。交互菜单里选择 Snell 时会提示错误，按任意键返回菜单，不会直接退出；只有命令行 `--mode snell` / `--mode both` 才会报错退出。

带参数的一键部署示例：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh) \
  --mode both \
  --address node.example.com \
  --core sing-box \
  --vless-port 443 --vless-sni www.microsoft.com \
  --snell-port 8443 --snell-domain www.bing.com --snell-obfs tls
```

---

## 1. 选型结论

### VLESS-Reality：默认 sing-box，Xray 作为可选核心

| 核心 | 说明 |
| --- | --- |
| **sing-box** | 默认核心。统一配置、协议覆盖广、官方支持 Alpine musl 构建；和参考脚本 `install-singbox.sh` 一致，适合只维护一个核心。 |
| **Xray** | REALITY 的原创实现，二进制更小（约 36MB vs sing-box 约 81MB），单协议场景更轻量，客户端兼容性最好。脚本通过 `--core xray` 切换。 |

因此脚本**内置两种核心**，默认 sing-box，需要更轻量或更强 REALITY 兼容性时切换到 Xray。

> 参考脚本：`https://raw.githubusercontent.com/ceocok/incudal/main/scripts/install-singbox.sh`。它同样使用 sing-box，并适配 Alpine OpenRC / systemd；本脚本已参考它的思路，默认改为 sing-box，并补齐 OpenRC 支持。

### Snell：使用官方 snell-server

Xray 不支持 Snell。sing-box 从 1.14 开始有 Snell 入站，但：

- 只支持 Snell **v5 / v6**；
- v5 只支持 HTTP 混淆，**不支持 Snell v4 常见的 `obfs=tls`**；
- 对 Surge / Stash 等客户端的兼容性不如官方服务端。

所以本脚本使用 **官方 `snell-server`**：

- 默认 `v4.1.1`，支持 `obfs=tls` / `obfs=http` / 不混淆；
- 可选 `v5.0.1`，v5 会额外监听 QUIC（UDP），脚本会自动放行 UDP 端口；
- 客户端使用 Surge / Stash / Clash.Meta 的 Snell 配置；
- **系统限制**：官方 Snell 二进制依赖 glibc 的 `/lib64/ld-linux-x86-64.so.2`，只能运行在 glibc 系统（Debian / Ubuntu / CentOS 等）。Alpine musl 无法运行，脚本会在部署前提前报错，避免出现 `Not a valid dynamic program`。

---

## 2. 文件

- `deploy.sh`：主脚本
- `README.md`：本说明

脚本运行后会生成 / 管理：

| 路径 | 内容 |
| --- | --- |
| `/etc/node-deploy/config.env` | 部署参数与密钥，权限 600 |
| `/usr/local/bin/xray` | Xray 可执行文件 |
| `/usr/local/etc/xray/config.json` | Xray 配置 |
| `/etc/systemd/system/xray.service` 或 `/etc/init.d/xray` | Xray 服务（systemd / OpenRC） |
| `/usr/local/bin/sing-box` | sing-box 可执行文件（使用 sing-box 核心时） |
| `/etc/sing-box/config.json` | sing-box 配置 |
| `/etc/systemd/system/sing-box.service` 或 `/etc/init.d/sing-box` | sing-box 服务（systemd / OpenRC） |
| `/usr/local/bin/snell-server` | Snell 官方服务端 |
| `/etc/snell/snell-server.conf` | Snell 配置 |
| `/etc/systemd/system/snell.service` 或 `/etc/init.d/snell` | Snell 服务（systemd / OpenRC） |

---

## 3. 本地运行（可选）

如果已经上传、clone 或下载了脚本：

```bash
chmod +x deploy.sh
sudo bash deploy.sh
```

无参数运行会进入交互菜单：

```
1. 部署/重装 VLESS-Reality
2. 部署/重装 Snell
3. 同时部署 VLESS-Reality + Snell
4. 查看节点信息
5. 启用 BBR
6. 卸载所有组件
0. 退出
```

交互模式下会依次询问：

- 节点地址（客户端连接用，域名或 IP）
- VLESS-Reality 核心（xray / sing-box）
- VLESS-Reality 端口
- VLESS-Reality 伪装域名 / SNI
- Snell 端口
- Snell 混淆方式（tls / http / none）
- Snell 伪装域名 / obfs-host

---

## 4. 非交互示例

### 4.1 同时部署，复用同一个地址，端口独立

```bash
sudo bash deploy.sh \
  --mode both \
  --address node.example.com \
  --core sing-box \
  --vless-port 443 \
  --vless-sni www.microsoft.com \
  --snell-port 8443 \
  --snell-domain www.bing.com \
  --snell-obfs tls
```

- `--address` 是客户端连接地址，VLESS 和 Snell 共用。
- `--vless-port` 和 `--snell-port` 必须不同。
- VLESS 的 `--vless-sni` 是 Reality 伪装目标域名。
- Snell 的 `--snell-domain` 是 `obfs-host`。

### 4.2 只部署 VLESS-Reality，使用 sing-box 核心

```bash
sudo bash deploy.sh \
  --mode vless \
  --address 1.2.3.4 \
  --core sing-box \
  --vless-port 443 \
  --vless-sni www.cloudflare.com
```

### 4.3 只部署 Snell v5

```bash
sudo bash deploy.sh \
  --mode snell \
  --address 1.2.3.4 \
  --snell-port 8443 \
  --snell-domain www.bing.com \
  --snell-obfs tls \
  --snell-version 5.0.1
```

### 4.4 非交互 + 使用默认值

```bash
sudo bash deploy.sh --mode both --address 1.2.3.4 -y --force
```

未指定的端口 / 域名 / 密钥会使用脚本默认值或自动生成。

### 4.5 查看信息 / 卸载 / 启用 BBR

```bash
sudo bash deploy.sh --info
sudo bash deploy.sh --uninstall
sudo bash deploy.sh --bbr
```

---

## 5. 完整参数

```text
-m, --mode <vless|snell|both>   部署模式；不指定则进入交互菜单
-a, --address <域名|IP>         客户端连接地址；同时部署时两者复用
    --core <xray|sing-box>      VLESS-Reality 核心，默认 sing-box

VLESS-Reality：
    --vless-port <端口>         监听端口，默认 443
    --vless-sni <域名>          伪装域名/SNI，默认 www.microsoft.com
    --vless-dest-port <端口>    伪装目标端口，默认 443
    --vless-uuid <UUID>         自定义 UUID，默认随机生成
    --vless-flow <flow>         默认 xtls-rprx-vision
    --vless-short-id <hex>      自定义 shortId，默认随机生成
    --vless-private-key <key>   自定义 Reality 私钥
    --vless-public-key <key>    自定义 Reality 公钥

Snell：
    --snell-port <端口>         监听端口，默认 8443
    --snell-domain <域名>       obfs-host/伪装域名，默认 www.bing.com
    --snell-psk <密钥>          PSK，默认随机生成
    --snell-obfs <tls|http|none> 混淆方式，默认 tls
    --snell-version <版本>      服务端版本，默认 4.1.1（可选 5.0.1）
    --snell-ipv6 <true|false>   是否启用 IPv6，默认 false

其他：
    --singbox-version <版本>    指定 sing-box 版本；默认自动获取最新
    --bbr                       启用 BBR
    --no-firewall               不自动放行防火墙端口
    --info                      查看当前节点信息
    --uninstall                 卸载所有组件
-f, --force                     端口占用/重装时不再询问
-y, --yes                       非交互模式
    --dry-run                   仅生成配置到 ./dry-run，不修改系统
-h, --help                      显示帮助
    --version                   显示版本
```

---

## 6. 客户端配置

### 6.1 VLESS-Reality

脚本 `--info` 会直接输出分享链接，例如：

```text
vless://UUID@node.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp&headerType=none#VLESS-Reality
```

支持的客户端：v2rayN、v2rayNG、NekoBox、Shadowrocket、Stash、Surge、Clash.Meta 等。

### 6.2 Snell（Surge / Stash）

脚本会输出类似：

```text
Snell = snell, node.example.com, 8443, psk=YOUR_PSK, obfs=tls, obfs-host=www.bing.com, version=4
```

### 6.3 Snell（Clash.Meta）

脚本会输出类似：

```yaml
- name: Snell
  type: snell
  server: node.example.com
  port: 8443
  psk: YOUR_PSK
  version: 4
  obfs-opts:
    mode: tls
    host: www.bing.com
```

---

## 7. 注意事项

1. **云厂商安全组**：脚本只会处理系统内的 ufw / firewalld / iptables。阿里云、腾讯云、AWS、Oracle 等还需要在控制台安全组放行对应 TCP 端口；Snell v5 还要放行 UDP。
2. **Reality 伪装域名**：建议选择支持 TLS 1.3、HTTP/2、非 Cloudflare CDN 的常见站点，例如 `www.microsoft.com`、`www.cloudflare.com`、`dl.google.com` 等。不要使用自己的主域名作为伪装目标，除非你清楚风险。
3. **端口选择**：同时部署时两个端口必须不同。443 通常给 VLESS-Reality，Snell 可以用 8443 或其他高位端口。
4. **密钥复用**：脚本第二次运行时会复用 `/etc/node-deploy/config.env` 里的 UUID、Reality 密钥、shortId、PSK，不会无故更换。需要重置时删除 `/etc/node-deploy/config.env`，或通过 `--vless-uuid`、`--vless-private-key`/`--vless-public-key`、`--snell-psk` 显式传入新值；`--force` 只影响端口占用和重装询问，不会主动更换密钥。
5. **Snell 版本**：默认 `4.1.1` 兼容性最好；`5.0.1` 支持 QUIC，但部分旧客户端可能只支持 v4。
6. **防火墙规则持久化**：iptables 规则可能重启后丢失，建议使用 ufw / firewalld 或自行 `iptables-save`。
7. **init 系统**：支持 systemd（Debian 12 / Ubuntu 22.04+ / Rocky 9 / Alma 9 等）和 OpenRC（Alpine）。Alpine 上需要先安装 `bash`，脚本会自动使用 sing-box 的 musl 版本；Xray 是静态链接可直接运行。**官方 Snell 依赖 glibc，Alpine musl 无法运行**，Alpine 上请用 `--mode vless`，Snell 请换 Debian/Ubuntu 或使用 sing-box 的 Snell 入站。
8. **安全**：`/etc/node-deploy/config.env` 包含私钥和 PSK，权限为 600，请勿泄露。

---

## 8. 卸载

```bash
sudo bash deploy.sh --uninstall
```

会停止并删除 Xray / sing-box / Snell 的服务、二进制、配置和 `/etc/node-deploy`。防火墙规则不会自动删除。

---

## 9. 本地调试

`--dry-run` 只会在当前目录生成 `dry-run/`，不修改系统：

```bash
bash deploy.sh --dry-run --mode both --address node.example.com \
  --vless-port 443 --vless-sni www.microsoft.com \
  --snell-port 8443 --snell-domain www.bing.com --non-interactive
```

可以用它检查生成的 JSON / conf / systemd / OpenRC 文件是否符合预期。
