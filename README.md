# Class Never Deafing

Class Never Deafing 是一款用于课堂、讲座和会议的 macOS 实时双语字幕 App。它可以从麦克风或 Mac 系统声音转写，边听边显示原文和译文，课后保存录音和带时间戳的双语文本。

## 主要功能

- **实时双语字幕**：置顶或隐藏字幕窗，录制中可切换源语言和目标语言。源语言默认自动检测，目标语言默认普通话（简体中文）。
- **整句翻译**：原文持续显示，App 尝试把跨音频片段的同一句话合起来，再把译文填到原文下方。可选每批 1–5 句，默认 1 句。
- **独立配置转写与翻译**：两者可使用不同的 API 地址、Key 和模型。设置内可测试连接，翻译支持 Responses 和 Chat Completions。
- **录音、时间戳和回听标记**：录制时点小旗记下位置，停止后可得到 MP3 和同名 TXT。TXT 的索引和正文都标有编号及录音播放时间。
- **长课历史**：实时字幕窗显示最近 20 分钟，较早字幕可在菜单栏分页浏览。导出保留整节课。
- **自定义**：分别调整原文和译文的字体、字号和颜色，设置窗口透明度、全局快捷键、无声自动暂停、保存目录和保留天数。

## 安装与运行

需要 **Apple Silicon Mac**。麦克风输入支持 macOS 14.0 及以上，系统声音输入需要 macOS 14.2 或以上。

如果 [GitHub Releases](https://github.com/VictorYuan233/Class-Never-Deafing/releases) 中有可用的 App 压缩包，解压后将 `Class Never Deafing.app` 拖入 Finder 的「应用程序」。也可以用 Xcode Command Line Tools 从源码构建：

```sh
xcode-select --install
git clone https://github.com/VictorYuan233/Class-Never-Deafing.git
cd Class-Never-Deafing
./scripts/build.sh
```

已安装 Command Line Tools 时可跳过第一条命令。构建完成后，将 `build/Class Never Deafing.app` 拖入「应用程序」。按 `⌘ Space` 搜索 **Class Never Deafing**，回车打开。

## 第一次使用

1. **配置 API。** 右键点击 macOS 菜单栏的字幕气泡图标，选择「设置」。在「转写」和「翻译」分别选择模型，填写并保存各自的 API Key。使用 OpenAI 时，API 地址留空即可。使用兼容服务时，填入服务商给出的基础地址（例如带 `/v1` 的 HTTPS 地址），并为翻译选择服务商支持的接口。
2. **测试。** 分别点击「测试转写」和「测试翻译」。成功会显示「测试通过」，失败会显示返回错误。模型可用性和费用取决于服务商与账户配置。
3. **选择输入。** 从菜单栏的「输入源」选择麦克风、耳机麦克风或「系统声音」。Mac 上播放的课程可选「系统声音」。用 iPad 等设备外放时，选择能听到外放的麦克风。首次使用时按 macOS 提示授权。
4. **开始并保存。** 在字幕窗点播放按钮开始，录制中同一按钮可以暂停或继续。点小旗添加回听标记。点停止后，默认自动保存录音和双语文本。要给录音和文本选共同的名称和位置，点「停止并另存为」。

## 录制中的常用操作

| 操作 | 入口 |
| --- | --- |
| 切换源语言、目标语言或置顶 | 字幕窗顶部 |
| 调整翻译速度与分段 | 「设置 → 分句」可立即调整每批句数。沿用本节课的翻译地址和接口时，模型与 Fast 用于新入队的译文。自定义模型输入完整 ID 后，点「应用模型」。 |
| 查看更早的字幕 | 菜单栏右键 → 查看本节课历史 |
| 隐藏或唤出字幕窗 | 菜单栏右键 → 隐藏字幕窗 / 显示字幕窗。隐藏时继续录制。 |
| 找到录音与文本 | 菜单栏右键 → 打开保存文件夹。用 TXT 中的回听时间定位同名录音。 |

API 地址、接口、Key、转写模型和输入源的更改在下次开始录制时生效。更多操作可在 App 的「设置 → 使用指南」查看，也可打开[使用指南源码](Sources/Resources/使用指南.html)。

## 数据与隐私

转写所需的音频片段和待译文本会分别发给你配置的服务。App 会在开始录制前显示新配置的服务地址。完整录音、字幕归档和 API 资料位于 Mac 本地，由应用按设置管理。

| 数据 | 本地位置 |
| --- | --- |
| 加密保存的 API Key 及加密所需文件 | `~/Library/Application Support/课堂字幕/API/` |
| 录音和双语 TXT（可在设置中修改） | `~/Library/Application Support/课堂字幕/课堂记录/` |
| 诊断日志 | `~/Library/Logs/Class Never Deafing/diagnostics.log` |

关闭「自动保存录音和字幕」后，可用「停止并另存为」主动保存。诊断日志可即时关闭。分享源码时，请把 API 资料、个人录音、字幕和本机构建目录 `build/` 留在仓库之外。

## 开发与反馈

运行 `./scripts/test.sh` 执行本地检查。App 版本、使用指南和「关于」的更新内容会在构建时校验。开发细节见 [macOS 开发文档](macOS-Live-Classroom-Captions-Dev-Spec.md)。

向他人分发构建时，可以单独压缩 `Class Never Deafing.app`。公开分发可使用 Developer ID Application 签名并提交 Apple 公证。本地临时签名的副本在其他电脑上可能被 macOS 拦截。

反馈问题时可提供 App 版本、输入源、复现步骤和已经脱敏的日志。项目采用 [Apache License 2.0](LICENSE)。
