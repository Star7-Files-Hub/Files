# -*- coding: utf-8 -*-
import os
import time
import requests
from telethon import TelegramClient, events, sync

api_id = [********]  # 输入api_id，一个账号一项，以英文逗号隔开
api_hash = ['********************************']  # 输入api_hash，一个账号一项，以英文逗号隔开
bot_name = "@*********"  # 需要签到的机器人id，如@DataSGKBot
message = "/qd" # 需要发送的命令或消息
session_name = api_id[:]

# 企业微信 Webhook 地址，用于接收任务执行情况，请注意，仅接收任务执行情况，执行成功与否请先自行查看！
webhook_url = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=********-****-****-****-************"

for num in range(len(api_id)):
    session_name[num] = "id_" + str(session_name[num])
    client = TelegramClient(session_name[num], api_id[num], api_hash[num])
    client.start()
    client.send_message(bot_name, message)  # 第一项是机器人ID，第二项是发送的文字
    time.sleep(5)  # 延时5秒，等待机器人回应（一般是秒回应，但也有发生阻塞的可能）
    client.send_read_acknowledge(bot_name)  # 将机器人回应设为已读
    print("成功! 机器人ID:", bot_name)

# 发送企业微信通知
try:
    data = {
        "msgtype": "text",
        "text": {
            "content": f"签到任务执行成功！机器人ID: {''.join(bot_name)}"
        }
    }
    response = requests.post(webhook_url, json=data)
    response.raise_for_status()
    print("企业微信通知发送成功")
except requests.RequestException as e:
    print(f"企业微信通知发送失败: {e}")

os._exit(0)
