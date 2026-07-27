# 双层分卷压缩器 Android

Flutter UI + Kotlin/SAF 原生桥接 + 官方 7-Zip `7zz` Android 原生内核。

## 开发测试

```powershell
$env:PUB_CACHE = 'C:\DualVolumeBuildCache\pub'
$env:GRADLE_USER_HOME = 'C:\DualVolumeBuildCache\gradle'
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --target-platform android-x64
```

## 正式构建

把 `android/key.properties.example` 复制为 `android/key.properties`，创建对应 `release-keystore.jks`，然后从本目录运行：

```powershell
.\build-android.ps1
```

原生库重建方式见 `tool/build-7zip-android.ps1`。完整功能与发布说明见仓库根目录 `README.md`。
