import requests

url = "" # 此处输入API带json参数的URL
saved_urls = []

while True:
    try:
        response = requests.get(url)
        response.raise_for_status()
        data = response.json()
        img_url = data.get("imgurl") # 此处输入带图片链接的键值
        if img_url and img_url not in saved_urls:
            with open("img.txt", "a") as file:
                file.write(img_url + '\n')
            print(f"已将 {img_url} 保存到 img.txt")
            saved_urls.append(img_url)
        else:
            print(f"跳过重复链接或未找到imgurl字段: {img_url}")
    except requests.RequestException as e:
        print(f"请求出错: {e}")
