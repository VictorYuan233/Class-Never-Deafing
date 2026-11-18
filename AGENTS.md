# Class Never Deafing 项目说明

每次修改 App 的用户可见功能、操作流程或默认行为时，同步更新以下内容。

- 更新 `Sources/Resources/使用指南.html` 的对应操作说明，并维护其中的版本标识和可见版本。
- 更新 `Sources/Resources/ReleaseNotes.plist` 的版本及「关于」面板中的本版更新。
- 在 `Sources/Info.plist` 更新 App 版本号和构建号。应用构建时检查版本与指南及更新说明一致。
- 用 `./scripts/build.sh` 构建，用 `./scripts/test.sh` 验证。功能涉及界面时，检查实际 App 中的入口和对应界面。

每次 Codex 为本项目新增或修改代码，最终回复都附上可直接用于 GitHub 的 **Summary** 和 **Description**。Summary 用一句话写标题，Description 列出本次实际改动。
