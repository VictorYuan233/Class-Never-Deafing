# Class-Never-Deafing
一个被带口音的英语折磨到崩溃的童鞋写做出的课堂实时翻译神器，愿天堂没有英语聋子

运行 `./scripts/build.sh` 构建，将 `build/Class Never Deafing.app` 拖到 Finder 的「应用程序」。按 `⌘ Space` 搜索 `Class Never Deafing` 并打开。测试使用 `./scripts/test.sh`。

## 本地数据

API 密文和解密文件位于 `~/Library/Application Support/课堂字幕/API/`。设置由 macOS 保存在 `~/Library/Preferences/com.classneverdeafing.captions.plist`。录音和字幕默认保存在 `~/Library/Application Support/课堂字幕/课堂记录/`。这些目录和文件都应留在源代码仓库之外。

`build/` 是本机构建目录，包含可带有本机路径的编译缓存。发布源码时使用 Git 跟踪的文件，避免打包整个工作目录或 `.git/`。
