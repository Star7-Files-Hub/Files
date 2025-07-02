import requests
from datetime import datetime, timedelta, timezone
import os

# 规则源地址映射（地址：标签）
rule_sources = {
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/fq2.txt": "fq2.txt",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/fqnovel-fxxk_ads": "fqnovel-fxxk_ads",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/qimao-ads": "qimao-ads",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/b_ads": "b_ads",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/aiqiyi": "aiqiyi",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/genery_rules": "genery_rules",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/xmlyjsb": "xmlyjsb",
    "https://ghfast.top/raw.githubusercontent.com/Star7-Files-Hub/Files/refs/heads/main/Ad/Manual_input.txt": "Manual_input.txt",
    "https://ghfast.top/raw.githubusercontent.com/8680/GOODBYEADS/master/data/rules/dns.txt": "dns.txt",
    "https://raw.githubusercontent.com/banbendalao/ADgk/master/ADgk.txt": "ADgk.txt",
    "https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-hosts.txt": "AWAvenue-Ads-Rule-hosts.txt",
    "http://rssv.cn/adguard/api.php?type=black": "QY.txt",
    "https://github.com/miaoermua/AdguardFilter/blob/main/rule.txt": "rules.txt",
    "https://raw.githubusercontent.com/miaoermua/AdguardFilter/main/bad_apple.txt": "bad_apple.txt"
}

# 创建输出目录
os.makedirs("Ad", exist_ok=True)

unique_rules = set()
duplicate_rules = set()
combined_rules = []
log_lines = []

# 当前北京时间
beijing_time = datetime.utcnow() + timedelta(hours=8)
version_str = beijing_time.strftime("%Y-%m-%d %H:%M:%S（北京时间）")

total_unique = 0

# 合并规则并去重
for url, label in rule_sources.items():
    try:
        print(f"📥 正在下载规则：{label}")
        resp = requests.get(url)
        resp.raise_for_status()
        lines = resp.text.strip().splitlines()

        rules_added = 0
        duplicates = 0
        combined_rules.append(f"! Source: {url} ({label})")

        for line in lines:
            stripped = line.strip()
            if not stripped or stripped.startswith("!"):
                continue
            if stripped in unique_rules:
                duplicate_rules.add(stripped)
                duplicates += 1
                continue
            unique_rules.add(stripped)
            combined_rules.append(stripped)
            rules_added += 1

        combined_rules.append("")  # 空行分隔
        total_unique += rules_added
        log_lines.append(f"[{label}] 添加规则：{rules_added} 条，重复规则：{duplicates} 条")

    except Exception as e:
        print(f"❌ 获取失败 {url}：{e}")
        log_lines.append(f"[{label}] 下载失败：{e}")

# 构建规则文件头部（元信息）
header = [
    "! Title: 7Star's_Ad_Rules",
    "! Homepage: https://github.com/Star7-Files-Hub/Files/Ad",
    "! Expires: 12 Hours",
    f"! Version: {version_str}",
    "! Description: 适用于AdGuard的去广告规则，合并优质上游规则并去重整理排列",
    f"! Total count: {total_unique}",
    ""
]

# 写入合并规则文件
with open("Ad/AdBlock.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(header + combined_rules))

# 写入日志文件
log_lines.append("")
log_lines.append(f"⚠️ 去重规则总数：{len(duplicate_rules)} 条")
log_lines.append("")
log_lines.append("🧾 被去重的规则（展示前 50 条）：")
for i, rule in enumerate(sorted(duplicate_rules)):
    if i >= 50:
        log_lines.append(f"...（共 {len(duplicate_rules)} 条，已省略）")
        break
    log_lines.append(rule)

with open("log/merge_log.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(log_lines))

print("✅ 合并完成，生成文件：Ad/AdBlock.txt 和 log/merge_log.txt")
