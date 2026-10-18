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

| 功能 | 你可以做什么 |
| --- | --- |
| 动作 | 设置快捷键、鼠标滚轮和媒体控制，打开应用、文件或网址，以及输入文本。 |
| 图层 | 最多 16 层，其中最多 6 个 Favorites 供触摸切换，其余放入可搜索的 Extended 列表；支持动作继承与应用自动匹配。 |
| 摇杆 | 八个方向选择动作，可显示桌面提示盘；保持滚轮动作方向连续滚动，回中停止。 |
| 应用切换 | 按住旋钮并旋转，选择已打开的 Mac 应用，松开切换。 |
| 外观 | 自定义名称、图标和图层／按键灯光；支持导入 PNG、JPEG、TIFF、SVG 图标。 |
| 菜单栏 | 查看连接和电量、打开编辑器，或让 Ed.Board 在后台运行。 |

Codex 层保留旋钮和摇杆的原生行为。

## 开始使用

**使用条件**：运行 macOS 14 或更新版本的 Apple Silicon Mac，以及搭载 **ESP32-S3 N16R8 的 AI Micro Board3** 和兼容固件。不涵盖其他硬件版本。App 界面目前为英文。

### 1. 安装

从本仓库的 **Releases** 页面下载 App **DMG**。打开后将 **Ed.Board.app** 拖到 **Applications（应用程序）**，推出磁盘映像，再打开 App。替换旧版本前，请先完全退出旧 App。

公开构建没有 Developer ID 签名，也未经过 Apple 公证。如 macOS 阻止打开，请对可信来源的下载参考 [Apple 的说明](https://support.apple.com/en-au/102445)。其他 Mac 上的安装体验仍需验证。

### 2. 连接

- **USB**：使用支持数据传输的线缆；必要时在 **Settings → Connection** 选择端口并点击 **Connect USB**。
- **蓝牙**：长按触摸区域 **3 秒**，在 macOS 蓝牙设置中配对 **Codex Micro**，允许 Ed.Board 使用蓝牙，再点击 App 内的 **Connect Bluetooth**。

### 3. 设置你的布局

打开 **Keymap**，选择图层，再点击按键、旋钮动作或摇杆方向编辑。使用 **Save changes** 保存，或用 **Discard changes** 撤销。

- **图层**：通过 **+** 新增，通过 **Editing → •••** 或右键菜单在 Favorites 和 Extended 之间移动，并关联应用以自动切层。触摸只循环 Favorites。编辑器选层仅用于编辑；未关联应用的 Extended 层只能编辑。
- **摇杆**：普通动作回中时执行，**Cancel** 取消选择。**Quick Selection** 旁的提示盘图标可独立开关该层的桌面提示盘，不改变动作。
- **应用切换**：在普通层旋钮的 **Press and hold** 中选择 **App Switcher**。按住 **0.6 秒**，继续按住并顺时针／逆时针旋转，选择下一个／上一个应用，松开切换；短按 Click 和正常旋转仍执行原动作。
- **图标**：选择不超过 **8 MB** 的图片。SVG 显示为单色图标，其他格式保留原色；选择窗口记住上次导入目录，保存后不依赖原文件。

## 日常使用

关闭窗口后，Ed.Board 继续在菜单栏运行。可在 **System → Launch at Login** 开启登录后后台启动。

退出 App 后，已保存的快捷键、鼠标／媒体控制和 App Switcher 仍可使用。打开应用、文件或网址、输入文本、应用自动匹配和桌面提示盘需要 App 保持运行。输入文本时按提示授予辅助功能权限。快捷键是同时按下的组合，不是多步宏。

电量百分比为估算值；**15%** 时提示低电，**5%** 时提示紧急充电。请在输入变得不可靠前充电。

## 固件更新

当前源码：**App 0.6.6 (46) / 固件 0.6.6**。下载的 Release 可能不同，请使用一起提供的 App 和配套固件。

对于可识别且兼容的键盘，通过 **USB** 连接，进入 **System → Device & Firmware** 并按更新提示操作。关闭串口监视器，验证结束前保持 USB 连接。更新器会备份设置并保留设备身份；降级可能需要恢复兼容备份。

这是兼容设备的更新工具，不是通用出厂烧录工具。不要刷入其他板型，也不要绕过兼容性检查。

项目灵感来自 [AI Micro](https://micro.diyshare.cn/)，部分固件代码改编自其代码，并保留原有的 [MIT 许可证与版权声明](../firmware/usb-probe/src/vendor/LICENSE)。该网站也提供硬件资料和原版固件资源。

## 常见问题

- **macOS 已连接，App 未连接**：键盘输入与 App 管理使用不同连接，请在 **Settings → Connection** 检查并重试。
- **更新固件后蓝牙无法连接**：macOS 可能保留旧服务。重连无效时，通过 USB 连接，在 macOS 中忽略 **Codex Micro**，再在 App 中选择 **Clear Pairing…**，拔掉 USB 后重新配对；图层保留。
- **深睡唤醒后输入恢复较慢**：此偶发问题仍在排查，请松开全部控件并等待恢复。
- **电量不可用**：先检查 App 连接，可能尚未收到有效读数。

设置和恢复文件位于 `~/Library/Application Support/Ed.Board/`，自动轮转的日志位于 `~/Library/Logs/Ed.Board/`。详细诊断会在 30 分钟后停止。

发现问题或有新想法，欢迎提交 issue，注明版本、连接方式和复现步骤。分享日志或截图前，请移除个人路径、设备标识和动作内容。

## 未来探索

根据社区反馈，继续探索：

- 多步宏等动作。
- 记住多台电脑的蓝牙配对信息。

以上为探索方向，暂不承诺具体发布时间。

## 开发与许可

从源码构建请参阅英文版[开发说明](DEVELOPMENT.md)。Ed.Board 自有代码采用 **GPL-3.0-only**，条款见 [LICENSE](../LICENSE)。第三方代码和素材保留各自许可，详见英文版[第三方声明](THIRD_PARTY_NOTICES.md)。
