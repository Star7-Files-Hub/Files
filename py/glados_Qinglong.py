import requests
import json
import os

# glados账号cookie
cookies = os.environ.get("GLADOS_COOKIE", "").split("&")
if not cookies or cookies[0] == "":
    print('未获取到COOKIE变量')
    exit(0)

# 企业微信机器人配置
QYWX_KEY = os.environ.get("QYWX_KEY", "")
# 拼接完整的Webhook URL，需在配置文件设置QYWX_KEY
WECOM_ROBOT_URL = f"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key={QYWX_KEY}" if QYWX_KEY else ""
sendContent = ""  # 初始化通知内容


def send_wecom_notification(title, content):
    """发送企业微信机器人通知"""
    if not WECOM_ROBOT_URL:
        print("未配置企业微信机器人Key，无法发送通知")
        return
    
    headers = {"Content-Type": "application/json"}
    data = {
        "msgtype": "markdown",
        "markdown": {
            "content": f"# {title}\n\n{content}"
        }
    }
    
    try:
        print("正在发送企业微信通知...")  # 调试信息
        response = requests.post(WECOM_ROBOT_URL, headers=headers, data=json.dumps(data))
        response.raise_for_status()
        print("企业微信通知发送成功")
        print(f"响应内容: {response.text}")  # 打印响应内容
    except requests.RequestException as e:
        print(f"企业微信通知发送失败: {str(e)}")
        if 'response' in locals():
            print(f"响应状态码: {response.status_code}")
            print(f"响应内容: {response.text}")


def start():
    global sendContent
    url = "https://glados.rocks/api/user/checkin"
    url2 = "https://glados.rocks/api/user/status"
    referer = 'https://glados.rocks/console/checkin'
    origin = "https://glados.rocks"
    useragent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/102.0.0.0 Safari/537.36"
    payload = {
        'token': 'glados.one'
    }
    
    for cookie in cookies:
        try:
            # 签到请求
            checkin = requests.post(url, 
                headers={
                    'cookie': cookie,
                    'referer': referer,
                    'origin': origin,
                    'user-agent': useragent,
                    'content-type': 'application/json;charset=UTF-8'
                },
                data=json.dumps(payload)
            )
            checkin.raise_for_status()  # 检查请求是否成功
            
            # 获取状态请求
            state = requests.get(url2, 
                headers={
                    'cookie': cookie,
                    'referer': referer,
                    'origin': origin,
                    'user-agent': useragent
                }
            )
            state.raise_for_status()  # 检查请求是否成功
            
            # 解析响应数据
            time = state.json().get('data', {}).get('leftDays', '')
            if time:
                time = time.split('.')[0]
            email = state.json().get('data', {}).get('email', '未知邮箱')
            
            # 处理签到结果
            if 'message' in checkin.text:
                mess = checkin.json().get('message', '未知消息')
                log_msg = f'{email} \n{mess} \n剩余({time})天'
                print(log_msg)  # 日志输出
                sendContent += log_msg + '\n'
            else:
                # 单个cookie签到失败，发送通知
                send_wecom_notification("GLaDOS签到提醒", f"{email}需要更新cookie")
                    
        except requests.RequestException as e:
            print(f"请求异常: {str(e)}")
        except (KeyError, json.JSONDecodeError) as e:
            print(f"解析异常: {str(e)}")
    
    # 全部处理完成后发送汇总通知
    if sendContent:
        send_wecom_notification("GLaDOS签到结果", sendContent)


def main_handler(event, context):
    return start()

if __name__ == '__main__':
    start()
