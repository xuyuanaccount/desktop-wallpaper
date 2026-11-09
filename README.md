# Desktop Wallpaper · 动态壁纸

Desktop Wallpaper 是一款 macOS 菜单栏软件，可以把本地照片、循环视频、互动网页或 AI 生成的作品设为桌面壁纸。它适合用自己的素材布置桌面，也可以按显示器、时间或当前应用自动切换壁纸。

**系统要求**　搭载 Apple 芯片的 Mac，macOS 14 或更新版本。

## 主要功能

- **图片、视频和网页壁纸**。支持 JPG、JPEG、PNG、本地视频、HTML 文件、网页项目文件夹和网址。导入后可先预览，再应用到桌面。
- **多显示器和自动切换**。为每台显示器选不同壁纸，或用同一张壁纸跨屏铺满。支持播放列表、每日时段和前台应用规则。
- **AI 生成**。通过 OpenAI 或阿里云百炼生成图片，通过通义万相生成视频。生成结果可预览、保存到本地壁纸库或直接应用。
- **菜单栏与播放控制**。关闭设置窗口后壁纸继续运行。可设置登录自启、全屏或电池状态下暂停，也可以把本地壁纸导出为 macOS 屏保。

## 开始使用

1. 从 [GitHub Releases](https://github.com/xuyuanaccount/desktop-wallpaper/releases) 下载适用于 Apple 芯片的 DMG，打开镜像后把 DesktopWallpaper 拖到「应用程序」。也可以按下文从源码构建。启动后可从菜单栏的「动态壁纸」图标打开窗口。
2. 选择「添加内置演示」，再点击「应用到桌面」。隐藏设置窗口后，移动鼠标或单击露出的桌面可以操作演示。
3. 在「导入」中选择本地 JPG、JPEG、PNG 图片、视频、单个 HTML、包含 `index.html` 的文件夹或网页地址。带有图片、脚本等相对路径素材的 HTML 应按文件夹导入。视频由 AVFoundation 解码，导入时会检查是否有可播放的视频轨道。
4. 在「显示器」中选择独立分配或跨屏铺满。各显示器也可以设为「系统壁纸」。跨屏网页共享桌面坐标，每个屏幕运行各自的网页实例，任意脚本内部状态可能因页面实现而不同。
5. 在「自动切换」中配置播放列表、每日时间和前台应用规则，再把目标屏幕设为「使用自动切换」。应用规则优先于时间规则。时间规则持续到下一时段，也可以用「恢复播放列表」结束该时段的固定壁纸。
6. 在「设置」中可启用全屏暂停、电池暂停和登录自启。网页暂停时会卸载，恢复时重新加载。跨屏模式下，任一屏幕被全屏应用覆盖就会暂停整张壁纸。
7. 在本地壁纸详情点击「导出为屏保」。双击生成的 `.saver` 安装，再在 macOS 系统设置中选择。导出会复制本地素材，网页文件夹中的链接素材需要放在文件夹内。

设置存放于 `~/Library/Application Support/DesktopWallpaper/settings.json`。普通导入会记录素材路径，移动素材后可以重新导入。

## AI 生成壁纸

在「壁纸 → AI 生成 → 生成图片」中选择 OpenAI GPT Image 2.6 Flare 或 Qwen Image 3.0 Pro，输入所选服务的 API 密钥并保存到 macOS 钥匙串。千问支持北京和新加坡地域，请使用与所选地域对应的阿里云百炼密钥。OpenAI 和两个百炼地域的密钥分别保存。

填写描述、选择比例，再点击「生成」。OpenAI 还可选画质。预览后可选「保存到壁纸库」或「保存并应用」。每次生成会使用所选服务的 API 额度。

生成结果是静态 PNG，保存于 `~/Library/Application Support/DesktopWallpaper/Generated/`。保存后可以像其他壁纸一样分配给显示器、加入播放列表或导出为屏保。在「AI 生成」窗口可以更换或删除密钥。

## AI 生成视频壁纸

在「壁纸 → AI 生成 → 生成视频」中选择北京或新加坡地域。万相 2.7 复用同地域的百炼密钥。输入描述，选择比例、720p 或 1080p，以及 2–15 秒时长。提交后可关闭窗口，重新打开时会继续查询已保存的任务。

生成完成后可循环预览，再保存为本地 MP4 或直接应用到桌面。视频按时长和清晰度计费。清除本地任务记录会移除这条查询记录。 [百炼文生视频 API](https://help.aliyun.com/zh/model-studio/text-to-video-api-reference)

## 从源码构建

构建需要 Swift 6 工具链和 macOS SDK，可通过 Xcode 或 Xcode Command Line Tools 安装。

```sh
git clone https://github.com/xuyuanaccount/desktop-wallpaper.git
cd desktop-wallpaper
./Packaging/build-app.sh
open ./dist/DesktopWallpaper.app
```

运行测试：

```sh
./Packaging/swift-local.sh test --disable-xctest
```

如需在支持 WindowServer 的桌面会话中运行渲染和屏保模块测试，先构建应用，然后执行：

```sh
WALLPAPER_GUI_TESTS=1 \
WALLPAPER_SAVER_TEMPLATE="$PWD/dist/DesktopWallpaper.app/Contents/Resources/WallpaperSaver.saver" \
./Packaging/swift-local.sh test --disable-xctest
```
