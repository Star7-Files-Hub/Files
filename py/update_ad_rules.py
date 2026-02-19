#!/usr/bin/env python3
import os
import re
import time
from datetime import datetime, timedelta, timezone

# 配置参数 - 按需修改
RULES_FILE = os.environ.get('RULES_PATH', 'Files/Ad/AdGuardHomeBlack.txt')
GITHUB_REPO = f"{os.environ.get('REPO_OWNER', 'Star7-Files-Hub')}/{os.environ.get('REPO_NAME', 'Files')}"

def read_rules_file():
    """读取规则文件，返回内容和当前头部信息"""
    if not os.path.exists(RULES_FILE):
        print(f"⚠️ 规则文件不存在: {RULES_FILE}，将创建新文件")
        return [], {}
    
    with open(RULES_FILE, 'r', encoding='utf-8') as f:
        content = f.readlines()
    
    # 提取现有头部信息
    header_info = {}
    rules_start = 0
    for i, line in enumerate(content):
        if line.startswith(('||', '! ', '#', '@@')):
            rules_start = i
            break
        if line.startswith(('! Title:', '! Homepage:', '! Expires:', '! Version:', '! Description:', '! Total count:')):
            key, value = line[2:].split(':', 1)
            header_info[key.strip()] = value.strip()
    
    # 规则部分（从第一个规则行开始）
    rules_lines = [line.rstrip('\n') for line in content[rules_start:] if line.strip()]
    return rules_lines, header_info

def deduplicate_rules(rules_lines):
    """去重规则，保留顺序和注释"""
    seen = set()
    unique_rules = []
    comment_buffer = []
    
    for line in rules_lines:
        # 保留空行和纯注释行
        if not line.startswith(('||', '@@')):
            if line.strip():  # 非空行
                comment_buffer.append(line)
            continue
        
        # 处理规则行
        if line not in seen:
            seen.add(line)
            # 先添加关联的注释
            if comment_buffer:
                unique_rules.extend(comment_buffer)
                comment_buffer = []
            unique_rules.append(line)
    
    return unique_rules

def generate_header(total_count):
    """生成标准头部信息"""
    beijing_tz = timezone(timedelta(hours=8))
    now = datetime.now(beijing_tz)
    
    return [
        "! Title: 7Star's_Ad_Rules",
        "! Homepage: https://github.com/Star7-Files-Hub/Files/tree/main/Ad",
        "! Expires: 12 hours",  # 小写更规范
        f"! Version: {now.strftime('%Y-%m-%d %H:%M:%S')}（北京时间）",
        "! Description: 适用于AdGuard的去广告规则，合并优质上游规则并去重整理排列",
        f"! Total count: {total_count}",
        "! Last modified: " + now.strftime("%Y-%m-%d %H:%M:%S"),
        "! License: MIT",
        "! Source: https://raw.githubusercontent.com/" + GITHUB_REPO + "/main/" + RULES_FILE,
        ""
    ]

def main():
    # 读取现有规则
    rules_lines, header_info = read_rules_file()
    
    # 去重处理
    unique_rules = deduplicate_rules(rules_lines)
    total_count = len([r for r in unique_rules if r.startswith(('||', '@@'))])
    
    # 生成新头部
    new_header = generate_header(total_count)
    
    # 写入新文件
    directory = os.path.dirname(RULES_FILE)
    if directory and not os.path.exists(directory):
        os.makedirs(directory)
    
    with open(RULES_FILE, 'w', encoding='utf-8') as f:
        f.write('\n'.join(new_header))
        f.write('\n'.join(unique_rules))
    
    print(f"✅ 规则更新成功! 共 {total_count} 条有效规则")
    print(f"📄 文件已保存至: {RULES_FILE}")

if __name__ == "__main__":
    main()
