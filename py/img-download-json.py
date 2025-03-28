import requests
import os
import uuid
from PIL import Image

# 获取用户输入的API URL
api_url = input("请输入API的URL: ")
# 获取用户输入的包含图片链接的JSON键名
key_name = input("请输入包含图片链接的JSON键名: ")

# 检查并创建保存图片的文件夹
if not os.path.exists('images'):
    os.makedirs('images')

session = requests.Session()
count = 0  # 用于计数保存操作的次数

while True:
    try:
        response = session.get(api_url)
        response.raise_for_status()
        data = response.json()
        img_url_str = data.get(key_name)
        if img_url_str:
            try:
                img_data = session.get(img_url_str).content
                # 使用UUID生成唯一的文件名
                file_name = os.path.join('images', str(uuid.uuid4()) + '.jpg')
                with open(file_name, 'wb') as file:
                    file.write(img_data)
                count += 1
                if count % 10 == 0:  # 每10次保存操作检查一次图片有效性
                    try:
                        # 尝试打开图片以验证是否下载成功
                        Image.open(file_name)
                        print(f"已将图片保存到 {file_name}")
                    except Exception as e:
                        print(f"保存的文件可能不是有效的图片: {e}")
            except requests.RequestException as e:
                print(f"获取图片数据时出错: {e}")
        else:
            print(f"跳过，未找到{key_name}字段: {img_url_str}")
    except requests.RequestException as e:
        print(f"请求API时出错: {e}")
