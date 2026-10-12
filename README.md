# Grok

macOS 上的 Grok。界面按 grok.com：Chat、Imagine、Library、Automations、Bots、Connectors。右边的终端是本地 CLI，只改你选中的文件夹。

这是 Xcode 工程，不是编好的 App。在自己的 Mac 上打开。

## 运行

需要 macOS 14 和 Xcode 16。

```bash
git pull
```

用 Xcode 打开 `GrokMac.xcodeproj`，设备选 My Mac。先 Product → Clean Build Folder（⇧⌘K），再按 ⌘R。

图标是黑底白环加一条斜线。如果 Dock 里还是旧图标，退出应用后在终端执行 `killall Dock`，再 ⌘R。

## 登录

打开就到登录页。

- 登录：浏览器打开 `auth.x.ai` 的授权页，用 X、Google 或 Apple。授权完会回到这个应用。
- 暂时跳过：先不登录。

不再要 API Key。

## 本地 CLI

用 ⌘, 选工程文件夹。工具只改那个目录。项目里的修改和命令直接做，要联网或写出项目外才会问你。

对话记在 `~/Library/Application Support/GrokMac/sessions.json`。
