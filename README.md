# Grok

原生 SwiftUI 的 macOS 应用。左边是对话，右边是终端，两条共用同一条会话，模型是 grok-4.5。

这个压缩包是 Xcode 工程，不是已经编好的 `.app`。当前预览环境是 Linux，编译不了 Mac 应用，需要在你自己的 Mac 上打开。

## 环境

- macOS 14 或更新
- Xcode 16 或更新

## 运行

1. 解压后双击 `GrokMac.xcodeproj`
2. 顶部设备选 My Mac，按 Run（⌘R）
3. 第一次启动会要求 API Key，之后也可以用 ⌘, 打开设置
4. 到 [console.x.ai](https://console.x.ai) 创建你自己的 Key。Key 只进这台 Mac 的钥匙串，工程里没有写死任何密钥

签名目前是本机临时签名，不需要付费开发者账号就能 Run。要发给别人，在 Signing & Capabilities 里改成你的 Developer ID，再 Archive 并公证。

## 里面有什么

- 系统窗口、侧栏会话、检查器里的终端
- 斜杠命令（`/help`、`/model`、`/mode`、`/new` 等），终端里 Shift+Tab 切换模式
- 流式调用 `grok-4.5`。Fast / Auto / Expert 是回答长短，不是不同的模型
- 右边终端是工具代理，和 Codex / Claude Code 一样可以自己调用 bash、读写文件、grep、网页搜索、打开链接、记任务、生成图片
- 先用 ⌘, 选择工程文件夹。工具只会改那个目录
- 对话存在 `~/Library/Application Support/GrokMac/sessions.json`

左边的普通对话不会改文件。要它动手，用右边的终端。
