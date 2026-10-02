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
- 部署完成后**默认自动启用 BBR**（`fq` + `bbr`），内核不支持或容器只读时自动跳过，可用 `--no-bbr` 关闭。

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

# 先下载再运行（wget 版本）
wget -qO /tmp/node-deploy.sh https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh
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
6. 同时部署 VLESS-Reality + AnyTLS
7. 全部部署 VLESS + Snell + AnyTLS + Nowhere
8. 查看节点信息
9. 启用 BBR（部署后默认已开启）
10. 卸载所有组件
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

### 4.2 同时部署 VLESS + AnyTLS，复用同一个地址，端口独立

```bash
sudo bash deploy.sh \
  --mode vless-anytls \
  --address node.example.com \
  --core sing-box \
  --vless-port 443 \
  --vless-sni www.microsoft.com \
  --anytls-port 9443 \
  --anytls-sni www.microsoft.com \
  --anytls-security tls
```

- `--mode vless-anytls` 一次装好 VLESS-Reality 和 AnyTLS，两者共用 `--address`，端口各自独立。
- `--anytls-security tls` 使用自签证书，Surge 可直接用（`skip-cert-verify=true`）；改成 `reality` 则只有 sing-box 等客户端可用。
- 只想装单个协议时分别用 `--mode vless` / `--mode anytls`。

### 4.3 只部署 VLESS-Reality

```bash
sudo bash deploy.sh \
  --mode vless \
  --address 1.2.3.4 \
  --core sing-box \
  --vless-port 443 \
  --vless-sni www.cloudflare.com
```

### 4.4 只部署 Snell

```bash
# glibc：官方 Snell v5
sudo bash deploy.sh --mode snell --address 1.2.3.4 \
  --snell-port 8443 --snell-domain www.bing.com --snell-obfs tls --snell-version 5.0.1

# Alpine：sing-box Snell 引擎
sudo bash deploy.sh --mode snell --address 1.2.3.4 \
  --snell-engine singbox --snell-port 8443 --snell-obfs http
```

### 4.5 只部署 AnyTLS

```bash
# Surge 兼容的 TLS 模式
sudo bash deploy.sh --mode anytls --address 1.2.3.4 \
  --anytls-port 9443 --anytls-sni www.microsoft.com --anytls-security tls

# sing-box 客户端的 Reality 模式
sudo bash deploy.sh --mode anytls --address 1.2.3.4 \
  --anytls-port 9443 --anytls-sni www.microsoft.com --anytls-security reality
```

### 4.6 只部署 Nowhere

```bash
sudo bash deploy.sh --mode nowhere --address 1.2.3.4 \
  --nowhere-port 2077 --nowhere-client both
```

### 4.7 全部部署，使用默认值

```bash
sudo bash deploy.sh --mode all --address 1.2.3.4 -y --force
```

未指定的端口 / 域名 / 密钥会使用脚本默认值或自动生成。

### 4.8 查看信息 / 卸载 / 启用 BBR

```bash
sudo bash deploy.sh --info
sudo bash deploy.sh --uninstall

# 部署后已自动启用 BBR；这里可以单独再执行一次（幂等）
sudo bash deploy.sh --bbr

# 不想要 BBR，部署时跳过
sudo bash deploy.sh --mode all --address 1.2.3.4 -y --no-bbr
```

---

## 5. 完整参数

```text
-m, --mode <vless|snell|anytls|nowhere|vless-anytls|both|all>
                                 部署模式；both=VLESS+Snell，vless-anytls=VLESS+AnyTLS，
                                 all=四种全部部署
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
    --bbr                        立即启用 BBR（默认部署后已自动启用）
    --no-bbr                     不自动启用 BBR
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
9. **端口占用检测**：部署前会检查端口，并显示占用进程与所属服务，例如 `sing-box(sing-box.service, pid 1234)`。如果占用者正是本次部署要重写并重启的同名服务（重装本脚本，或 incudal 等面板预装的 `sing-box`），脚本会自动接管该端口，不再提示；被其它进程占用时仍会提示，并给出 `systemctl stop <服务>` / `rc-service <服务> stop` 的释放建议，`--force` 可跳过询问。
10. **BBR 默认开启**：部署完成后会自动写入 `/etc/sysctl.d/99-bbr.conf`（`net.core.default_qdisc = fq`、`net.ipv4.tcp_congestion_control = bbr`）并立即生效；Alpine/OpenRC 不读取 `/etc/sysctl.d`，脚本会额外写入 `/etc/sysctl.conf`，否则重启后可能失效。内核不支持 BBR、或容器内 `/proc/sys` 只读时会自动跳过并提示，不会导致部署失败。不需要时加 `--no-bbr`；`--dry-run` 不修改内核参数。`--uninstall` 不会回滚 BBR 配置，需要手动清理上述文件里的相关行。

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

---

## 10. 附：Lite 探针（Alpine / OpenRC 脚本）

同目录下的 `lite-openrc.sh` 是 [Lite（komari-lite）](https://github.com/nuomiiiii/Lite) 探针在 **Alpine + OpenRC** 上的安装 / 升级脚本，和上面的节点部署脚本互不相关。

官方 `install-lite.sh` 只支持 systemd 和 OpenWrt/procd：在 Alpine 上服务管理器判定为 `none`，会打印「未检测到 systemd 或 OpenWrt procd，已跳过服务创建」——二进制装好了，但没有服务、没有开机自启。本脚本补上这一段：写 `/etc/init.d/lite` + `rc-update add lite default`，并带备份、二进制校验、启动后健康检查与失败自动回滚。

### 10.1 一键命令

```bash
# 升级（已安装时用；也是不带 action 时的默认动作）
wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-openrc.sh | sh -s -- upgrade

# 首次安装（默认端口 27777）
wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-openrc.sh | sh -s -- install

# 指定端口安装
wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-openrc.sh | sh -s -- install --port 8080

# 查看状态（不需要 root）/ 回滚到上一版本 / 只演练不替换
wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-openrc.sh | sh -s -- status
wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-openrc.sh | sh -s -- rollback
wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-openrc.sh | sh -s -- upgrade --dry-run
```

先下载再运行（需要 `--help`、或要准确判断退出码时用这种）：

```bash
wget -qO /tmp/lite-openrc.sh https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-openrc.sh
sh /tmp/lite-openrc.sh --help
sh /tmp/lite-openrc.sh install
```

GitHub Raw 慢或刚推送还在缓存时，可换 jsDelivr 镜像（路径相同）：`https://cdn.jsdelivr.net/gh/Star7-Files-Hub/Files@latest/sh/lite-openrc.sh`。

说明：`sh -s --` 里的 `--` 用于结束 `sh` 自身的参数解析，**action 要写在 `--` 后面**（`sh -s -- upgrade --port 8080`）。脚本只用 POSIX sh，不需要 bash / jq / curl（busybox 的 `sh` + `wget` 即可）；`install` / `upgrade` / `rollback` 需要 root，`status` 不需要。

### 10.2 动作、参数与路径

| 动作 | 说明 |
| --- | --- |
| `install` | 全新安装：探测架构 → 建目录 → 下载并校验 → 写 OpenRC 服务脚本 → 加入开机自启 → 启动 → 健康检查。**已存在 `/opt/lite/Lite` 时直接报错退出** |
| `upgrade` | 升级 / 降级 / 重装；默认动作。版本与当前相同时跳过（`--force` 可强制） |
| `rollback` | 用 `/root/lite-backups/.last_binary` 记录的备份还原二进制并重启 |
| `status` | 版本、服务状态、开机自启、监听端口、HTTP 探测、内存占用、磁盘、备份列表 |

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--port N` | `27777` | 端口；只在 `install` 时写入服务脚本，升级时的 HTTP 健康检查也用它探测 |
| `--version X.Y.Z` | 取最新 | 指定版本（当前上游 tag 形如 `2.3.6`，无 `v` 前缀） |
| `--channel NAME` | `stable` | `snapshot` 走快照通道，其它取值按 `stable` 处理 |
| `--force` | 关 | 目标版本与当前相同时仍执行（重装 / 降级） |
| `--dry-run` | 关 | 下载并校验后退出，不替换、不重启 |
| `--no-backup` | 关 | 升级时不备份（之后无法 `rollback`，不推荐） |

| 路径 | 内容 |
| --- | --- |
| `/opt/lite/Lite` | 二进制（安装目录 `/opt/lite`） |
| `/opt/lite/data` | 数据目录（脚本创建并纳入备份，实际数据位置请以探针自身为准） |
| `/etc/init.d/lite` | OpenRC 服务脚本（服务名 `lite`，日志 `/var/log/lite.log`） |
| `/root/lite-backups/` | 备份目录：二进制、`data.<时间戳>.tar.gz`、`initd.<时间戳>`、`.last_binary` |

安装时若检测到 cgroup 内存上限，会按上限的一半（下限 32MiB）写入 `GOMEMLIMIT`、`GOGC=50`，避免 Go 探针在小容器里被 OOM。

### 10.3 注意事项

1. **跑过官方脚本的 Alpine 机器，装之前要先删二进制**：官方脚本会把二进制放到同一个 `/opt/lite/Lite`，但不会建 OpenRC 服务。这种机器上 `install` 会因为「已安装」直接退出，而 `upgrade` 从不生成服务脚本——服务永远建不出来。先 `rm -f /opt/lite/Lite`，再执行 `install`。
2. **升级要带上和安装时相同的 `--port`**：端口只在 `install` 时写进服务脚本，`upgrade` 若用默认 27777 去探测一个装在 8080 的实例，健康检查会失败并触发自动回滚。
3. **升级不会刷新服务脚本**：`GOMEMLIMIT` / `GOGC` / 日志等只在 `install` 时写入，要改这些配置只能重装（重装前记得删二进制）。
4. **回滚只回滚二进制，且只能回退一个版本**：数据目录和服务脚本的备份只是留在磁盘上，需要人工处理。
5. **管道执行时 `--help` 无效**：`usage()` 用 `sed -n '2,40p' "$0"` 从脚本文件读注释，`sh -s` 时 `$0` 是 `sh`，会报 `sed: can't read sh` 且退出码仍为 0。要看帮助请先下载再运行。
6. **脚本没有卸载动作**，也没有 sha256 / 签名校验，只校验文件大小、ELF 魔数和能否执行 `version`（校验时会以 root 执行刚下载的二进制，安全性依赖 GitHub release 通道）。

### 10.4 卸载（手动）

```bash
rc-service lite stop
rc-update del lite default
rm -f /etc/init.d/lite
rm -rf /opt/lite /root/lite-backups /var/log/lite.log
```
