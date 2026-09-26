# node-deploy

一个面向 VPS 的一键部署脚本，支持四种协议：

- **VLESS-Reality**（sing-box 或 Xray 核心）
- **Snell**（官方 `snell-server` 或 sing-box Snell 入站）
- **AnyTLS**（sing-box，TLS 或 Reality）
- **Nowhere**（官方 Rust Portal，TCP+UDP 同端口）

可单独部署，也可同时部署。同时部署时复用同一个出口 IP / 域名，**端口分别设置**。

- 支持交互式菜单和完整 CLI 参数，适合手动部署和自动化脚本。
- 支持 systemd（Debian / Ubuntu / Rocky / Alma 等）和 OpenRC（Alpine）。
- 默认核心为 **sing-box**；VLESS-Reality 可切换 **Xray**。
- 官方 Snell 仅支持 glibc；Alpine/musl 上自动改用 sing-box Snell 引擎。

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
```

如果 GitHub Raw 访问慢或刚推送后有缓存，可以用 jsDelivr 镜像：

```bash
sudo bash <(curl -fsSL https://cdn.jsdelivr.net/gh/Star7-Files-Hub/Files@latest/sh/deploy.sh)
```

Alpine（OpenRC）默认没有 bash，请先安装：

```sh
apk add --no-cache bash curl
bash <(curl -fsSL https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh)
```

> 不建议用 `curl ... | sudo bash`：管道会把 stdin 占用，交互菜单的 `read` 会读不到键盘输入。用 `bash <(curl ...)` 或先下载再运行即可正常交互。

### Alpine 上的兼容性

| 协议 | Alpine musl | 说明 |
| --- | --- | --- |
| VLESS-Reality | ✅ | sing-box / Xray 都有 musl 或静态构建 |
| Snell | ✅（sing-box 引擎） | 官方 `snell-server` 依赖 glibc，Alpine 上会自动改用 `--snell-engine singbox`，仅支持 v5/v6 + HTTP 混淆 |
| AnyTLS | ✅ | sing-box musl 构建 |
| Nowhere | ✅ | 官方提供 `nowhere-<arch>-unknown-linux-musl.tar.gz` |

在 Alpine 交互菜单里选择官方 Snell 时会提示错误，**按任意键返回菜单**，不会直接退出；只有命令行 `--mode snell --snell-engine official` 才会报错退出。

---

## 1. 选型结论

### VLESS-Reality：默认 sing-box，Xray 作为可选核心

| 核心 | 说明 |
| --- | --- |
| **sing-box** | 默认核心。统一配置、协议覆盖广、官方支持 Alpine musl；和参考脚本 `install-singbox.sh` 一致，适合只维护一个核心。 |
| **Xray** | REALITY 的原创实现，二进制更小（约 36MB vs sing-box 约 81MB），单协议场景更轻量，客户端兼容性最好。用 `--core xray` 切换。 |

### Snell：两种引擎

| 引擎 | 适用 | 特点 |
| --- | --- | --- |
| **official** | glibc 系统 | 官方 `snell-server`，支持 v4.1.1 / v5.0.1，v4/v5 支持 `obfs=tls`、`obfs=http`，客户端兼容性最好；Alpine musl 无法运行 |
| **singbox** | 所有系统（含 Alpine） | sing-box 内置 Snell 入站，仅支持 v5/v6，v5 只支持 `obfs=http` / `none`，v6 使用 `mode=default`；官方 Snell 的 `obfs=tls` 不可用 |

默认策略：glibc 系统用 `official`，Alpine/musl 用 `singbox`；也可以用 `--snell-engine` 显式指定。

### AnyTLS：sing-box 原生支持

- `--anytls-security tls`（默认）：自签证书，Surge 可直接使用（`skip-cert-verify=true`）。
- `--anytls-security reality`：使用 Reality 伪装，只有 sing-box 等支持的客户端可用；Surge 不支持 AnyTLS Reality。

### Nowhere：官方 Rust Portal

- 项目：`https://github.com/NodePassProject/Nowhere`，安装脚本参考 `chikacya/nowhere-sh` / `NodePassProject/nowhere-sh`。
- Portal 同时监听 **TCP + UDP**（默认同一个端口，2077）。
- 生成 `nowhere://`（Anywhere）和 `vector://`（原生 Vector 客户端）链接。
- 官方提供 glibc / musl、x86_64 / aarch64 四种构建。
- Surge 目前不支持 Nowhere / Vector，请使用官方 Anywhere / Vector 客户端。

---

## 2. 文件

- `deploy.sh`：主脚本
- `README.md`：本说明

脚本运行后会生成 / 管理：

| 路径 | 内容 |
| --- | --- |
| `/etc/node-deploy/config.env` | 部署参数与密钥，权限 600 |
| `/usr/local/bin/xray` | Xray 可执行文件（`--core xray`） |
| `/usr/local/etc/xray/config.json` | Xray 配置 |
| `/etc/systemd/system/xray.service` 或 `/etc/init.d/xray` | Xray 服务 |
| `/usr/local/bin/sing-box` | sing-box 可执行文件 |
| `/etc/sing-box/config.json` | sing-box VLESS 配置 |
| `/etc/sing-box/snell.json` | sing-box Snell 配置（singbox 引擎） |
| `/etc/sing-box/anytls.json` | AnyTLS 配置 |
| `/etc/sing-box/anytls.crt` / `anytls.key` | AnyTLS 自签证书（tls 模式） |
| `/etc/systemd/system/sing-box.service` 或 `/etc/init.d/sing-box` | sing-box VLESS 服务 |
| `/etc/systemd/system/sing-box-snell.service` 或 `/etc/init.d/sing-box-snell` | sing-box Snell 服务 |
| `/etc/systemd/system/sing-box-anytls.service` 或 `/etc/init.d/sing-box-anytls` | AnyTLS 服务 |
| `/usr/local/bin/snell-server` | Snell 官方服务端（official 引擎） |
| `/etc/snell/snell-server.conf` | Snell 官方配置 |
| `/etc/systemd/system/snell.service` 或 `/etc/init.d/snell` | Snell 官方服务 |
| `/usr/local/bin/nowhere` | Nowhere 官方 Portal |
| `/etc/nowhere/nowhere.env` | Nowhere 配置 |
| `/etc/nowhere/run.sh` | Nowhere 启动包装脚本 |
| `/etc/systemd/system/nowhere.service` 或 `/etc/init.d/nowhere` | Nowhere 服务 |

---

## 3. 交互菜单

无参数运行会进入菜单：

```text
1. 部署/重装 VLESS-Reality
2. 部署/重装 Snell
3. 部署/重装 AnyTLS
4. 部署/重装 Nowhere
5. 同时部署 VLESS-Reality + Snell
6. 全部部署 VLESS + Snell + AnyTLS + Nowhere
7. 查看节点信息
8. 启用 BBR
9. 卸载所有组件
0. 退出
```

交互模式下会依次询问节点地址、各协议端口、伪装域名/SNI、Snell 引擎与混淆、AnyTLS 安全类型、Nowhere 客户端类型等。

---

## 4. 非交互示例

### 4.1 同时部署 VLESS + Snell，复用同一个地址，端口独立

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

- `--address` 是客户端连接地址，所有协议共用。
- 各协议端口必须不同。
- VLESS 的 `--vless-sni` 是 Reality 伪装目标域名。
- Snell 的 `--snell-domain` 是 `obfs-host`。

### 4.2 只部署 VLESS-Reality

```bash
sudo bash deploy.sh \
  --mode vless \
  --address 1.2.3.4 \
  --core sing-box \
  --vless-port 443 \
  --vless-sni www.cloudflare.com
```

### 4.3 只部署 Snell

```bash
# glibc：官方 Snell v5
sudo bash deploy.sh --mode snell --address 1.2.3.4 \
  --snell-port 8443 --snell-domain www.bing.com --snell-obfs tls --snell-version 5.0.1

# Alpine：sing-box Snell 引擎
sudo bash deploy.sh --mode snell --address 1.2.3.4 \
  --snell-engine singbox --snell-port 8443 --snell-obfs http
```

### 4.4 只部署 AnyTLS

```bash
# Surge 兼容的 TLS 模式
sudo bash deploy.sh --mode anytls --address 1.2.3.4 \
  --anytls-port 9443 --anytls-sni www.microsoft.com --anytls-security tls

# sing-box 客户端的 Reality 模式
sudo bash deploy.sh --mode anytls --address 1.2.3.4 \
  --anytls-port 9443 --anytls-sni www.microsoft.com --anytls-security reality
```

### 4.5 只部署 Nowhere

```bash
sudo bash deploy.sh --mode nowhere --address 1.2.3.4 \
  --nowhere-port 2077 --nowhere-client both
```

### 4.6 全部部署，使用默认值

```bash
sudo bash deploy.sh --mode all --address 1.2.3.4 -y --force
```

未指定的端口 / 域名 / 密钥会使用脚本默认值或自动生成。

### 4.7 查看信息 / 卸载 / 启用 BBR

```bash
sudo bash deploy.sh --info
sudo bash deploy.sh --uninstall
sudo bash deploy.sh --bbr
```

---

## 5. 完整参数

```text
-m, --mode <vless|snell|anytls|nowhere|both|all>
                                 部署模式；both=VLESS+Snell，all=四种全部部署
-a, --address <域名|IP>          客户端连接地址；同时部署时复用
    --core <xray|sing-box>       VLESS-Reality 核心，默认 sing-box

VLESS-Reality：
    --vless-port <端口>          监听端口，默认 443
    --vless-sni <域名>           伪装域名/SNI，默认 www.microsoft.com
    --vless-dest-port <端口>     伪装目标端口，默认 443
    --vless-uuid <UUID>          自定义 UUID，默认随机生成
    --vless-flow <flow>          默认 xtls-rprx-vision
    --vless-short-id <hex>       自定义 shortId，默认随机生成
    --vless-private-key <key>    自定义 Reality 私钥
    --vless-public-key <key>     自定义 Reality 公钥

Snell：
    --snell-engine <official|singbox>
                                 服务端引擎；glibc 默认 official，Alpine/musl 默认 singbox
    --snell-port <端口>          监听端口，默认 8443
    --snell-domain <域名>        obfs-host/伪装域名，默认 www.bing.com
    --snell-psk <密钥>           PSK，默认随机生成
    --snell-obfs <tls|http|none> 官方默认 tls；sing-box 只支持 http/none
    --snell-version <版本>       官方默认 4.1.1（可选 5.0.1）；sing-box 支持 5/6
    --snell-ipv6 <true|false>    是否启用 IPv6，默认 false

AnyTLS：
    --anytls-port <端口>         监听端口，默认 9443
    --anytls-sni <域名>          伪装域名/SNI，默认 www.microsoft.com
    --anytls-security <tls|reality>
                                 tls=自签证书（Surge 可用，默认）；reality=仅 sing-box 客户端
    --anytls-dest-port <端口>    Reality 目标端口，默认 443
    --anytls-password <密码>     客户端密码，默认随机生成
    --anytls-user <用户名>       用户名，默认 node-deploy
    --anytls-private-key <key>   自定义 Reality 私钥
    --anytls-public-key <key>    自定义 Reality 公钥
    --anytls-short-id <hex>      自定义 shortId，默认随机生成

Nowhere：
    --nowhere-port <端口>        监听端口（同时占用 TCP+UDP），默认 2077
    --nowhere-key <密钥>         共享密钥，默认随机生成
    --nowhere-tls <1|2>          1=自签证书（默认），2=使用 PEM 证书
    --nowhere-crt <路径>         TLS=2 时的证书链路径
    --nowhere-tls-key <路径>     TLS=2 时的私钥路径
    --nowhere-morph <0|1>        Morph 变换，默认 0
    --nowhere-client <anywhere|vector|both>
                                 生成的客户端链接类型，默认 both
    --nowhere-version <版本>     Nowhere 版本，默认 v2.1.1
    --nowhere-listen-host <地址> 监听地址，留空=全部
    --nowhere-rate <Mbps>        限速，0=不限速
    --nowhere-etar <Mbps>        Etar 限速，0=不限速
    --nowhere-log <级别>         日志级别，默认 info

其他：
    --singbox-version <版本>     指定 sing-box 版本；默认自动获取最新
    --bbr                        启用 BBR
    --no-firewall                不自动放行防火墙端口
    --info                       查看当前节点信息
    --uninstall                  卸载所有组件
-f, --force                      端口占用/重装时不再询问
-y, --yes, --non-interactive     非交互模式
    --dry-run                    仅生成配置到 ./dry-run，不修改系统
-h, --help                       显示帮助
    --version                    显示版本
```

---

## 6. 客户端配置

### 6.1 VLESS-Reality

`--info` 会输出分享链接：

```text
vless://UUID@node.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp&headerType=none#VLESS-Reality
```

支持 v2rayN、v2rayNG、NekoBox、Shadowrocket、Stash、Clash.Meta 等。Surge 不支持 VLESS/Reality。

### 6.2 Snell（官方引擎，Surge / Stash）

```text
Snell = snell, node.example.com, 8443, psk=YOUR_PSK, obfs=tls, obfs-host=www.bing.com, version=5
```

- Surge 的 Snell `obfs` 只支持 `http`（v4/v5），不支持 `tls`；官方服务端的 `obfs=tls` 适合 Stash / Clash.Meta。
- sing-box 引擎只支持 `obfs=http` / `none`。

### 6.3 Snell（Clash.Meta）

```yaml
- name: Snell
  type: snell
  server: node.example.com
  port: 8443
  psk: YOUR_PSK
  version: 5
  obfs-opts:
    mode: http
    host: www.bing.com
```

### 6.4 AnyTLS

`--info` 会同时输出 Surge 配置、sing-box 客户端配置和分享链接：

```text
# Surge（tls 模式）
AnyTLS = anytls, node.example.com, 9443, password=YOUR_PASSWORD, sni=www.microsoft.com, skip-cert-verify=true
```

```json
// sing-box（reality 模式）
{
  "type": "anytls",
  "tag": "anytls-out",
  "server": "node.example.com",
  "server_port": 9443,
  "password": "YOUR_PASSWORD",
  "tls": {
    "enabled": true,
    "server_name": "www.microsoft.com",
    "reality": {
      "enabled": true,
      "public_key": "PUBLIC_KEY",
      "short_id": "SHORT_ID"
    }
  }
}
```

Surge 只支持 AnyTLS 标准 TLS，不支持 AnyTLS Reality。

### 6.5 Nowhere

`--info` 会输出 Portal URL、Anywhere 链接和 Vector 链接：

```text
Portal URL : portal://KEY@*:2077?tls=1&morph=0

Anywhere:
nowhere://KEY@node.example.com:2077?up=tcp&down=tcp&morph=0&mux=0#Nowhere

Native Vector:
vector://KEY@node.example.com:2077?up=tcp&down=tcp&mux=0&sni=none&pin=none&morph=0&socks=127.0.0.1:1080#Nowhere
```

- Anywhere：用 Anywhere 客户端导入 `nowhere://` 链接。
- Native Vector：本地运行 `nowhere` 二进制并传入 vector 链接：

```bash
nowhere 'vector://KEY@node.example.com:2077?up=tcp&down=tcp&mux=0&sni=none&pin=none&morph=0&socks=127.0.0.1:1080#Nowhere'
```

Surge 目前不支持 Nowhere / Vector。

---

## 7. 注意事项

1. **云厂商安全组**：脚本只会处理系统内的 ufw / firewalld / iptables。阿里云、腾讯云、AWS、Oracle 等还需要在控制台安全组放行对应端口。Snell v5 官方引擎和 **Nowhere 需要同时放行 TCP + UDP**。
2. **Reality 伪装域名**：建议选择支持 TLS 1.3、HTTP/2、非 Cloudflare CDN 的常见站点，例如 `www.microsoft.com`、`www.cloudflare.com`、`dl.google.com` 等。不要使用自己的主域名作为伪装目标，除非你清楚风险。
3. **端口选择**：同时部署时各协议端口必须不同。443 通常给 VLESS-Reality，Snell 用 8443，AnyTLS 用 9443，Nowhere 用 2077。
4. **密钥复用**：脚本第二次运行时会复用 `/etc/node-deploy/config.env` 里的 UUID、Reality 密钥、shortId、PSK、AnyTLS 密码、Nowhere KEY，不会无故更换。需要重置时删除 `/etc/node-deploy/config.env`，或通过对应 `--*-key` / `--*-password` / `--*-psk` 显式传入新值；`--force` 只影响端口占用和重装询问，不会主动更换密钥。
5. **Snell 版本**：官方引擎默认 `4.1.1` 兼容性最好；`5.0.1` 支持 QUIC，但部分旧客户端可能只支持 v4。sing-box 引擎只支持 v5/v6。
6. **防火墙规则持久化**：iptables 规则可能重启后丢失，建议使用 ufw / firewalld 或自行 `iptables-save`。
7. **init 系统**：支持 systemd 和 OpenRC（Alpine）。Alpine 上需要先安装 `bash`；sing-box / Nowhere 会自动选择 musl 构建。
8. **安全**：`/etc/node-deploy/config.env`、`/etc/sing-box/anytls.key`、`/etc/nowhere/nowhere.env` 包含私钥和密钥，权限为 600，请勿泄露。

---

## 8. 卸载

```bash
sudo bash deploy.sh --uninstall
```

会停止并删除 Xray / sing-box / Snell / AnyTLS / Nowhere 的服务、二进制、配置和 `/etc/node-deploy`。防火墙规则不会自动删除。

---

## 9. 本地调试

`--dry-run` 只会在当前目录生成 `dry-run/`，不修改系统：

```bash
# 全部四种协议
bash deploy.sh --dry-run --mode all --address node.example.com \
  --vless-port 443 --vless-sni www.microsoft.com \
  --snell-engine singbox --snell-port 8443 --snell-obfs http \
  --anytls-port 9443 --anytls-sni www.microsoft.com --anytls-security tls \
  --nowhere-port 2077 --nowhere-client both \
  --non-interactive
```

可以用它检查生成的 JSON / conf / systemd / OpenRC 文件是否符合预期。
