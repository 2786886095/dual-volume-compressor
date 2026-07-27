# 第三方组件声明

## 7-Zip 26.02

Android 版包含由官方 7-Zip 源码构建的 `7zz` 原生可执行库：

- 上游项目：<https://github.com/ip7z/7zip>
- 对应提交：`f9d78aff31a5f2521ae7ddbdc97c4a8855808959`
- 版本：7-Zip 26.02
- 上游许可说明：<https://www.7-zip.org/license.txt>

7-Zip 的大部分源码采用 GNU LGPL；部分文件采用 BSD 3-clause，RAR 解压相关代码受 unRAR 限制。发布页同时附带该提交的完整源代码归档，仓库中的 `android-app/tool/build-7zip-android.ps1` 可重建随 APK 分发的 Android 二进制。

项目自身源码采用仓库根目录中的 MIT License；这不会改变任何第三方组件的许可条款。
