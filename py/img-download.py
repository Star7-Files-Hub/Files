import requests
import mimetypes
import uuid
from tkinter import Tk, filedialog

# 请求头，根据自己的浏览器修改
headers = {"User - Agent": "Mozilla/5.0+(Windows+NT+10.0;+Win64;+x64)+AppleWebKit/537.36+(KHTML,+like+Gecko)+Chrome/130.0.0.0+Safari/537.36+Edg/130.0.0.0"}


def get(url, path):  # 下载图片
    r = requests.get(url, headers=headers)
    content_type = r.headers.get('content-type')
    if content_type.startswith('image'):
        extension = mimetypes.guess_extension(content_type)
        file_name = str(uuid.uuid4()) + extension if extension else str(uuid.uuid4()) + ".jpg"
        with open(path + file_name, "wb") as f:
            f.write(r.content)
        print("图片下载完成，文件名: {}".format(file_name))
    else:
        print(f"跳过非图片内容的下载，URL返回的content - type为: {content_type}")


root = Tk()
root.withdraw()

url = input("请输入图片API网址:")
x = int(input("请输入下载图片张数:"))
# 选择保存路径
path = filedialog.askdirectory(title="请选择保存图片的路径") + '\\'
for _ in range(x):
    get(url, path)
print("完成!")
