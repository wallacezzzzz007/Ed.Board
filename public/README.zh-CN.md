[English](../README.md) · [简体中文](README.zh-CN.md)

<div align="center">

<img src="../app/EdBoard/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="104" height="104" alt="Ed.Board 应用图标">

# Ed.Board

**小小 Micro，按你的方式工作。**

为 AI Micro 打造的原生 macOS 应用与配套固件。
按键、图层、灯光、八向摇杆，在一个地方完成配置。

`macOS 14+` · `Apple Silicon` · `USB + 蓝牙`

[开始使用](#开始使用) · [日常使用](#日常使用) · [固件更新](#固件更新) · [常见问题](#常见问题) · [未来探索](#未来探索)

</div>

---

## 小键盘，更多可能

| 控件 | 你可以做什么 |
| --- | --- |
| 按键与旋钮 | 设置快捷键和媒体控制，打开应用、网址或文件，输入文本；自定义名称与图标。 |
| 图层 | 最多 16 层；最多 6 个 Favorites 供触摸切换，其余放入可搜索的 Extended，两类之间均可继承动作。 |
| 摇杆 | 设置八个方向；拨动时桌面浮出简洁的提示盘，回中时执行选中的动作或取消。 |
| 灯光 | 调整按键与外围灯光，为不同层设置颜色和输入反馈效果。 |
| 菜单栏 | 查看连接与电量、打开编辑器，或让 Ed.Board 在后台运行。 |

Codex 层的旋钮和摇杆保留原生 Codex 控制，此时不显示桌面摇杆提示盘。

## 开始使用

**使用条件**：运行 macOS 14 或更新版本的 Apple Silicon Mac，以及搭载 **ESP32-S3 N16R8 的 AI Micro Board3** 和兼容固件。不涵盖其他硬件版本。App 界面目前为英文。

### 1. 安装

版本发布后，从本仓库的 **Releases** 页面下载 App **DMG**。打开后，将 **Ed.Board.app** 拖到 **Applications（应用程序）** 快捷方式上。推出磁盘映像，再从应用程序中打开 Ed.Board。替换旧版本前，请先选择 **Quit Ed.Board** 完全退出。

当前构建没有 Developer ID 签名，也未经过 Apple 公证。如果 macOS 阻止打开，请参考 [Apple 关于打开下载应用的说明](https://support.apple.com/en-au/102445)。只批准来源可信的副本；其他 Mac 上的安装体验仍需验证。

### 2. 连接

- **USB**：使用支持数据传输的线缆连接键盘，再打开 Ed.Board。必要时进入 **Settings → Connection**，选择 USB 端口并点击 **Connect USB**。
- **蓝牙**：使用 Ed.Board 固件时，长按触摸区域 **3 秒**，开启 **60 秒**配对窗口。在 macOS 蓝牙设置中配对键盘，允许 Ed.Board 使用蓝牙，再点击 App 内的 **Connect Bluetooth**。按下按键或旋钮会取消配对窗口。

Ed.Board 会读取当前键盘的配置。全新安装不会附带其他人的应用绑定、文本动作或自定义图片。

### 3. 设置你的布局

打开 **Keymap**，选择 Favorite 或在 **Extended** 侧栏搜索图层，再点击按键、旋钮或摇杆方向进行编辑。点击 **Save changes** 应用修改，或点击 **Discard changes** 返回已保存的配置。

在 Actions 中选择 **Media Control**，再选择音量增加、音量减少、静音、播放／暂停、上一首或下一首。旋钮每格触发一次，摇杆在回中时执行动作。

使用 Favorites 或 Extended 旁的 **+** 新建层；通过 **Editing → •••** 或层的右键菜单移动分类。Favorites 保留 1–6 层，触摸区域只循环这些层，Extended 的三个层指示灯全部熄灭。

将图层关联到某个应用后，切换到该应用时可自动切层。在编辑器里选择图层，只改变正在编辑的内容，不会直接切换键盘实际运行的图层。未关联应用的 Extended 层只能编辑。从正在运行的 Extended 层触摸切换时会回到第一个 Favorite；同一应用匹配暂时让位，直到匹配变化或会话失效。

## 日常使用

- **关闭窗口**：App 继续在菜单栏运行，Dock 图标消失。可从菜单栏或 Applications 再次打开。
- **安静启动**：在 **System → Launch at Login** 开启登录后后台启动。
- **保持主机功能可用**：打开应用、文件或网址、输入文本、应用自动切层和桌面摇杆提示盘，都需要 Ed.Board 保持运行。
- **完全退出 App**：已保存的快捷键和媒体控制仍由键盘执行；主机动作和桌面提示盘需要重新运行 Ed.Board 才能使用。
- **输入文本**：按提示授予辅助功能权限。文本输入的兼容性取决于目标应用；快捷键为同时按下的组合，不支持多步宏。

## 固件更新

当前源码对应 **App 0.6.0 (33) / 固件 0.6.0**，尚未发布。下载的 Release 可能版本不同，请使用一起提供的 App 和配套固件。扩展层需要配套的新固件。

项目灵感来自 [AI Micro](https://micro.diyshare.cn/)，部分固件代码改编自其代码，并保留原有的 [MIT 许可证与版权声明](../firmware/usb-probe/src/vendor/LICENSE)。

对于可识别且兼容的键盘，通过 **USB** 连接，打开 **System → Device & Firmware**，在提供更新时按 **Install required firmware** 的提示操作。关闭串口监视器，直到验证完成前保持 USB 连接。更新器会先备份设置，不会整片擦除芯片。

用 0.6.0 保存后，旧固件无法读取新快照；如需主动降级，应使用已验证的备份。现有层会保留原顺序并归入 Favorites。

这是兼容设备的更新工具，**不是通用出厂烧录工具**。运行无法识别固件的键盘，可能需要单独的首次安装流程；不要将此固件刷入其他板型，也不要绕过兼容性检查。

## 常见问题

**macOS 已连接，为什么 Ed.Board 没连接？** 键盘输入与 App 管理使用不同的连接。请在 **Settings → Connection** 中检查并重试 App 连接。蓝牙键盘能输入，不代表管理连接已经建立。

**升级媒体控制后蓝牙连不上？** 新增 HID 报告后，macOS 可能仍使用缓存的蓝牙服务。通过 USB 连接，在 macOS 蓝牙设置中忽略 **Codex Micro**，再在 App 的 **Bluetooth Pairing** 区域点击 **Clear Pairing…**。拔掉 USB，长按触摸区域 3 秒重新配对；图层配置会保留。如果已显示 **Paired / Ready**，但仍留着“Pairing cleared”提示，点击 **Refresh Status** 即可，不必再次清除配对。

**深睡唤醒后输入暂时无响应？** 此偶发问题仍在排查。请松开全部控件，等待恢复；App 已连接并不代表输入已经就绪。

**电量为什么显示 Unknown？** App 可能还没有取得有效读数，请先检查连接。电量百分比依据电压估算，不是精确的剩余续航预测。

**我的数据在哪里？** Mac 本机设置保存在 `~/Library/Application Support/Ed.Board/Settings/`；固件恢复资料保存在 `~/Library/Application Support/Ed.Board/Firmware/`。日志单独保存在 `~/Library/Logs/Ed.Board/`，自动轮转；详细诊断会在 30 分钟后自动停止。

**发现问题或有新想法？** 欢迎提交 issue，注明 App 与固件版本、macOS 版本、USB／蓝牙连接方式和复现步骤。分享日志或截图前，请移除个人路径、设备标识和动作内容。欢迎小修复，也欢迎围绕具体问题一起改进。

硬件资料和原版固件资源，也可以参考 [AI Micro 网站](https://micro.diyshare.cn/)。Ed.Board 本身的问题，请在本仓库提交 issue。

## 未来探索

- 中文 App 界面。
- 根据社区反馈，考虑多步宏等动作。
- 让固件能够记住多台电脑的蓝牙配对信息。

以上为探索方向，暂不承诺具体发布时间。

## 开发与许可

从源码构建请参阅英文版[开发说明](DEVELOPMENT.md)。Ed.Board 自有代码采用 **GNU GPL 第 3 版（GPL-3.0-only）**，完整条款见 [LICENSE](../LICENSE)。第三方代码和素材保留各自的许可，详见英文版[第三方声明](THIRD_PARTY_NOTICES.md)。
