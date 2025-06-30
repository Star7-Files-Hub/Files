import requests
from datetime import datetime

rule_sources = {
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/fq2.txt": "rule1.txt",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/fqnovel-fxxk_ads": "rule2.txt",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/qimao-ads": "rule3.txt",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/b_ads": "rule4.txt",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/aiqiyi": "rule5.txt",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/genery_rules": "rule6.txt",
    "https://gcore.jsdelivr.net/gh/changzhaoCZ/fqnovel-adrules@refs/heads/main/xmlyjsb": "rule7.txt",
    "https://ghfast.top/raw.githubusercontent.com/8680/GOODBYEADS/master/data/rules/dns.txt": "rule8.txt"
}

combined_rules = []
total_lines = 0

for url, label in rule_sources.items():
    try:
        print(f"正在下载规则：{label}...")
        resp = requests.get(url)
        resp.raise_for_status()
        lines = resp.text.strip().splitlines()
        
        combined_rules.append(f"! Source: {url}")
        combined_rules.extend(lines)
        combined_rules.append("") 
        total_lines += sum(1 for line in lines if line.strip() and not line.strip().startswith("!"))
    except Exception as e:
        print(f"❌ 无法获取 {url}：{e}")

timestamp = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
header = [
    f"! Auto-generated AdGuard rules",
    f"! Generated at: {timestamp}",
    f"! Total rules: {total_lines}",
    ""
]

with open("AdBlock.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(header + combined_rules))

print("✅ 规则合并完成，文件已保存为 AdBlock.txt")
