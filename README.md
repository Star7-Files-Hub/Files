# 简介
个人文件外链仓库以及临时代码库

## sh/

- [`sh/deploy.sh`](sh/deploy.sh) — 节点一键部署脚本（VLESS-Reality / Snell / AnyTLS / Nowhere，支持 systemd 与 OpenRC），用法见 [sh/README.md](sh/README.md)
- [`sh/lite-openrc.sh`](sh/lite-openrc.sh) — Lite（komari-lite）探针在 Alpine / OpenRC 上的安装升级脚本

```bash
# Lite 探针（Alpine / OpenRC）升级
wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/lite-openrc.sh | sh -s -- upgrade

# 节点部署
wget -qO- https://raw.githubusercontent.com/Star7-Files-Hub/Files/main/sh/deploy.sh -O deploy.sh && sudo bash deploy.sh
```
