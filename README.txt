Live Material Phone · iPhone 原生实况取片客户端

经用户授权公开：仅同一 Wi-Fi 连接、成品下载、原生 Live Photo 配对与相册保存代码、合成测试、通用 LIVE 图标。
不包含：业务视频、原素材、账号资料、设备信息、对话、用户原头像、Windows 去重处理代码。

使用公开仓库的标准 macos-26-intel runner，不使用付费大型 runner、不启用 Actions 缓存或 Artifact。安装包发布到 GitHub Releases。工作流只允许手动触发，且私有仓库自动跳过构建。
已通过 Xcode 26.6 原生编译和模拟器测试：Live Photo 配对可识别、封面与动态视频配对标识一致、输出无音轨、本地连接规则通过。测试仅用程序生成的图像与视频。
已生成 ARM64 未签名 IPA。需用本人 Apple 账号免费签名安装，通常每7天刷新；签名安装和真实 iPhone 相册保存尚未验收。
测试记录：https://github.com/xluyu8952-ops/live-material-phone/actions/runs/42098556590
安装包：https://github.com/xluyu8952-ops/live-material-phone/releases/tag/test-3
安装后，在 App 点“保存为实况”，自动执行下载、封装、配对校验和相册写入，无需手动切换其他转换 App。

原生编译后仍要在真机验收 Live 标记、长按播放、原封面与静音。
工程由 XcodeGen project.yml 生成。测试仅使用程序生成的图像和视频，不上传业务媒体。
