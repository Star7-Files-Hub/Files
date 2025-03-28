import os
from PIL import Image
import numpy as np


def delete_duplicate_images_by_histogram(folder_path):
    image_files = [os.path.join(folder_path, f) for f in os.listdir(folder_path) if f.endswith(('.jpg', '.jpeg', '.png'))]
    hist_dict = {}
    for image_file in image_files:
        try:
            img = Image.open(image_file).convert('RGB')
            hist = np.array(img.histogram())
            found_duplicate = False
            for stored_hist in hist_dict.values():
                if np.sum((hist - stored_hist) ** 2) < 10000:  # 阈值可调整
                    print(f"删除重复图片 {image_file} 成功!")
                    os.remove(image_file)
                    found_duplicate = True
                    break
            if not found_duplicate:
                hist_dict[image_file] = hist
        except Exception as e:
            print(f"处理文件 {image_file} 时出错: {e}")
            if os.path.exists(image_file):
                print(f"删除有问题的图片 {image_file} 成功!")
                os.remove(image_file)


folder_path = input("请输入文件夹路径: ")
delete_duplicate_images_by_histogram(folder_path)
