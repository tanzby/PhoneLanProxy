# PhoneLanProxy

PhoneLanProxy 是一个 iOS TCP 代理：Mac 连接 iPhone 的代理端口，iPhone 再用当前网络连接目标服务。支持无认证的 SOCKS5 `CONNECT`、HTTP/1.1 absolute-form 请求和 HTTPS `CONNECT` TCP 隧道；不支持 UDP、HTTP CONNECT 以外的 TLS 解密或 VPN/TUN。

## 打开和运行

1. 用 Xcode 打开 `PhoneLanProxy.xcodeproj`，选择 `PhoneLanProxy` scheme。
2. 在 Signing & Capabilities 中为 `PhoneLanProxy` 和 `PhoneLanProxyWidgets` 两个 target 选择同一个 Team，部署目标为 iOS 17 或更高版本。App 的 bundle id 为 `com.zubingtan.PhoneLanProxy`，灵动岛扩展为 `com.zubingtan.PhoneLanProxy.Widgets`；改 App 的 id 时必须同步改扩展的 id（扩展 id 必须以 App id 为前缀）。免费 Personal Team 的描述文件 7 天过期，过期后需要重新从 Xcode 安装；如果不想每周连电脑重装，见下面的“用 AltStore 安装”。
3. 在模拟器或 iPhone 启动 App，点击“启动代理”。监听端口固定为 TCP `10808`，同一端口按首字节分别识别 SOCKS5 和 HTTP，界面显示当前可用的局域网地址。
4. 代理启动后可以切换其他 App、刷视频听音乐或锁屏，灵动岛会显示一个路由器图标。详见下面的“后台运行”和“灵动岛”。

该代理没有认证和加密，只适合可信的局域网。不要把 TCP 10808 暴露到互联网。HTTPS 只转发 CONNECT 建立的 TCP 字节流，手机不会解密 TLS。iOS 的局域网访问提示和实际行为需要在目标真机上确认；模拟器结果不作为权限验收。

Mac 上的客户端示例：

```sh
curl --socks5-hostname <iphone-lan-ip>:10808 https://example.com
```

使用 `--socks5-hostname` 会把域名交给 SOCKS5 代理侧解析。不要设置或修改系统代理；命令行参数只影响本次 `curl` 请求。

HTTP 和 HTTPS 示例：

```sh
curl --proxy http://<iphone-lan-ip>:10808 http://example.com/
curl --proxy http://<iphone-lan-ip>:10808 https://example.com/
```

普通 HTTP 请求必须使用 absolute-form；HTTPS 客户端会使用标准 `CONNECT host:443`，代理建立 TCP 隧道后不读取 TLS 内容。

### 设备信息清洗

转发**明文 HTTP** 请求时，代理会剥离一批暴露设备/OS 的请求头：`User-Agent`、全套 Client Hints（`Sec-CH-*`，含 UA 类的 `Sec-CH-UA-Platform` 等）、以及非 `Sec-CH-` 前缀的设备/网络特征头（`DPR`、`Device-Memory`、`Viewport-Width`、`Downlink`、`X-Requested-With` 等）。这些 Client Hints 都是站点通过 `Accept-CH` 显式索要的可选头，删掉只会回退默认值，几乎无副作用。这样源站或手机出口侧的 VPN 就无法从请求头看出流量来自 Mac 而非手机。TCP/IP 层本就是手机重新发起的出站连接，天然是 iOS 指纹。

注意局限：**这只对明文 HTTP 有效。** HTTPS（`CONNECT` 隧道）是不透明字节管道，手机不解密 TLS——隧道内加密的 User-Agent 无法修改，且 TLS 握手的 ClientHello 指纹（JA3/JA4）由 Mac 上的应用生成、代理也无法改写，仍可能暴露“客户端是 macOS”。要覆盖 HTTPS 必须做 TLS 拦截（MITM），本项目不做。

## 用 AltStore 安装（免费 Apple 账号，续签不用电脑）

免费 Apple 账号签名的 App 只有 7 天有效期，这个限制去不掉。用 AltStore Classic 的 Remote AltServer，可以在手机上直接续签，不用每周连电脑重装。电脑只在首次设置时需要用一次。SideStore 的流程类似，见 [SideStore 安装文档](https://docs.sidestore.io/docs/installation/prerequisites)。

**一、首次设置（需要 Mac，只做一次）**，详见 [How to Install (macOS)](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)

1. 下载 [AltServer](https://cdn.altstore.io/file/altstore/altserver.zip)（需要 macOS 11 或更高），放进「应用程序」后打开。它只在菜单栏显示一个图标。
2. 用数据线连接 iPhone，保持解锁，并点「信任此电脑」。点菜单栏的 AltServer 图标，选 **Install AltStore**，选择你的 iPhone，再登录 Apple ID。
3. 在 iPhone 上操作：「设置 → 通用 → VPN 与设备管理」，信任你的 Apple ID；再到「设置 → 隐私与安全性」，打开「开发者模式」（手机会重启）。
4. 从 App Store 安装 [LocalDevVPN](https://apps.apple.com/app/id6755608044)。在 AltStore 里进入 Settings → **Set up Remote AltServer...**，按 App 内提示完成配对，详见 [Remote AltServers](https://faq.altstore.io/altstore-classic/remote-altservers)。如果 My Apps 里有 AltStore 的 **UPDATE**，先更新到最新版（2.3.2 修复了侧载和续签时的 HTTP 503 错误）。

**二、获取 IPA**

- 推送 `v*` tag 后，GitHub Actions（`.github/workflows/build-ipa.yml`）会自动构建并发布到 Releases。在 iPhone 的 Safari 里打开 `https://github.com/tanzby/PhoneLanProxy/releases/latest/download/PhoneLanProxy.ipa` 即可下载。推送到 main 或提交 PR 时也会构建，产物在对应 workflow run 的 Artifacts 里，需要登录 GitHub 才能下载，下载后是 zip。
- 也可以在 Mac 上本地构建：`scripts/build_ipa.sh`，输出 `build/PhoneLanProxy.ipa`。IPA 不带签名，安装时由 AltStore 用你的 Apple 账号签名。

**三、安装**（如果之前用 Xcode 装过，先删掉那份：重签后 bundle id 会带上 Team ID 后缀，变成另一个 App）

- 用手机安装：先把 IPA 存进「文件」（下载或隔空投送都可以），连上 Wi-Fi 并打开 LocalDevVPN，然后在 AltStore 的 **My Apps** 页点左上角的 **+**，选中这个 IPA。
- 用 Mac 安装：iPhone 用数据线连接并保持解锁，按住 **Option** 点菜单栏的 AltServer 图标，选 **Sideload .ipa…**，再选中 IPA。

装好后，App 会出现在 My Apps 里，旁边显示剩余天数。保留 App 扩展才有灵动岛；不保留也不影响代理功能。

**四、续签（只用手机，7 天内做一次）**：先在 App 里停止代理，连上 Wi-Fi，打开 LocalDevVPN，在 AltStore 的 My Apps 页点 **Refresh All**，完成后切回原来的 VPN。iOS 同一时间只能连一个 VPN，手机上的其他 VPN 会被临时断开。

**常见问题**

- 同一个 Wi-Fi 下 AltServer 也找不到手机：公司、学校或公共 Wi-Fi 常会阻止设备之间互相发现，改用数据线连接即可，见 [Troubleshooting Guide](https://faq.altstore.io/altstore-classic/troubleshooting-guide)。
- 提示 `Remote AltServer sent invalid response`，或者连不上服务器：确认 Wi-Fi 和 LocalDevVPN 都已连接，过几分钟再试，或者在 Settings 里点 **Choose Server** 换一个服务器。
- 提示 HTTP 503：先更新 AltStore。如果更新也失败，用数据线连 Mac，在 AltServer 菜单里重新选 **Install AltStore**（不用先删除，覆盖安装即可）。
- 免费账号的限制：同时最多 3 个侧载 App（AltStore 本身也算一个），每 7 天最多注册 10 个 App ID。本 App 带灵动岛扩展，要占 2 个 App ID。

## 后台运行

iOS 没有给普通 App 提供“常驻监听端口”的后台模式。本项目用静音音频保活：代理运行期间循环播放一段 0 音量的静音音频（`AVAudioSession` `.playback` + `.mixWithOthers`），让进程在后台继续运行。

为什么不用 NetworkExtension：实际使用场景是 iPhone 连着企业 VPN，Mac 经手机代理走该 VPN 出口。企业 VPN 本身就是一个 Packet Tunnel，iOS 同一时间只能连接一个 VPN，用 Packet Tunnel 保活会把它断开。另外 NetworkExtension 需要付费开发者账号。

保活与代理按“用户意图 + 自愈”管理（`App/AppModel.swift`）：

- 只有点“停止代理”才会停止代理。保活出问题只会让后台运行降级，不会停掉代理；前台始终可用。
- 可混音会话不会被其他 App 的音乐、视频打断，也不会影响它们的声音和锁屏播放控件。
- 来电响铃按横幅提醒处理（`setPrefersNoInterruptionsFromSystemAlerts`）。接通的电话、Siri、闹钟会打断保活；中断结束后不论系统是否给出 `.shouldResume` 都会尝试恢复（静音、可混音的音频恢复不会打扰用户），失败再按 1s/3s/10s 重试，仍失败则在 App 中显示后台保活警告，回到 App 时自动重试。系统音频服务重置后会重建会话和播放器。
- 监听 socket 被系统回收（挂起后恢复时常见）会按 1s、2s、4s…最长 30s 退避自动重启；回到前台时立即重启。
- 中断期间 App 可能被系统挂起，这段时间代理暂停。

## 灵动岛（实时活动）

代理进入运行状态后，App 启动一个实时活动（`Widgets/` 中的 `PhoneLanProxyWidgets` 扩展）：

- 紧凑态和最小态只显示路由器图标：绿色 = 代理已启动且后台保活正常，灰色 = 正在恢复（监听重启中或保活中断）。
- 长按灵动岛或在锁屏上只显示代理状态：绿色 = 代理运行中，灰色 = 代理正在恢复；不显示连接数、LAN 地址或端口。
- **只按事件更新**（启动、健康或连接状态变化、停止），没有心跳，也不设过期时间。原因：真机日志证实 iOS 的 `liveactivitiesd` 会拒绝"只在播放后台音频"的进程更新实时活动（`Process is only playing background media so is forbidden to update activity`），而静音音频保活正是这种状态；在更新外面套 `beginBackgroundTask` 也没用。锁屏期间的更新都会被丢弃，回到 App 时补发；如果设过期时间，锁屏几分钟后正常运行的代理也会被误显示为灰色。
- 停止代理时实时活动立即消失；App 重新启动时会清理上一个进程残留的实时活动。如果系统在锁屏时直接杀掉了 App，图标会保持绿色，直到下次打开 App。
- 系统对实时活动有 8 小时上限；到期或被手动划掉后，回到 App 时会自动重建。实时活动只能在前台创建。
- 如果在“设置 > PhoneLanProxy > 实时活动”中关闭，灵动岛不会显示，代理本身不受影响。

## App 图标

图标由 `scripts/generate_app_icon.swift` 用 CoreGraphics 绘制（路由器外形，没有使用 SF Symbols，其授权不允许用于 App 图标），输出浅色、深色、着色三种外观到 `App/Assets.xcassets/AppIcon.appiconset`：

```sh
swift scripts/generate_app_icon.swift App/Assets.xcassets/AppIcon.appiconset
```

## 黑盒协议验收

在代理已经运行的 Mac 上执行：

```sh
python3 scripts/socks5_acceptance.py
```

脚本会临时启动 IPv4/IPv6 TCP 测试 server 和 HTTP 测试 server，然后连接已运行的代理，检查 SOCKS5 无认证协商、IPv4/IPv6/域名 `CONNECT`、分片和粘包、目标失败 `REP`、双向大数据和 half-close，并检查 HTTPS `CONNECT` 隧道、HTTP absolute-form 到 origin-form 的转换、分片请求头、`Proxy-Connection` 删除和畸形请求的 HTTP 错误。测试 server 在收到 EOF 后才发送固定响应；日志只输出测试状态和字节数，不输出 payload。

默认代理和测试目标都是本机回环地址，适合模拟器。对真实 iPhone，Mac 测试 server 必须在 iPhone 可达的局域网地址监听，并把该地址写入 SOCKS 请求：

```sh
python3 scripts/socks5_acceptance.py \
  --proxy-host <iphone-lan-ip> \
  --target-host <mac-lan-ip> \
  --bind-host 0.0.0.0 \
  --target-domain <phone-can-resolve-domain> \
  --target-ipv6 <reachable-ipv6> \
  --bind-ipv6 ::
```

`--target-domain` 必须能由 iPhone 当前网络解析，并指向这个测试 server；`--target-ipv6` 也必须是实际可达的 IPv6 地址。脚本使用临时端口并在输出中显示端口，不会安装依赖或改动系统网络设置。

## 分层验收与 VPN 测试

验收结果按层记录，低层通过不能替代高层：

1. 先运行上面的协议脚本，确认 SOCKS5、HTTP、HTTPS `CONNECT` 解析和 TCP relay 行为。
2. 在模拟器中启动 App，用脚本默认的本机目标做转发测试。
3. 在真实 iPhone 上，用 Mac 通过 iPhone 的局域网地址执行 `curl --socks5-hostname`，确认真实 Wi-Fi、前台生命周期和局域网可达性。
4. 在 iPhone 连接企业 VPN 的状态下验证经企业 VPN 出口访问内网。

VPN 真机验收步骤：

- 准备一个只有 VPN 内网可达的地址（内网 IP 或内网域名）。Mac 保持不连接企业 VPN。
- 企业 VPN 断开时，从 Mac 经 iPhone 代理访问该地址，必须失败。
- 企业 VPN 连接时，先确认 Mac 仍能连上 `<iphone-lan-ip>:10808`（如果企业 VPN 把局域网流量也收进隧道，这一步会失败，需要单独处理），再用 `--socks5-hostname` 访问：

  ```sh
  curl --socks5-hostname <iphone-lan-ip>:10808 http://<内网地址>/
  curl --proxy http://<iphone-lan-ip>:10808 https://<内网域名>/
  ```

  两条命令都能拿到内网响应，才能同时确认手机经企业 VPN 出口连接，以及域名在手机侧解析。

真实 iPhone、企业 VPN 或内网地址任一条件缺失时，相关项目记录为“未验证”；本 README 不把模拟器或静态检查写成真机已通过。

## 当前验证状态

阶段二（灵动岛实时活动、保活自愈、App 图标）已实现。

2026-09-18 模拟器实测（Xcode 27 / iOS 27、iPhone 18 Pro 模拟器）：

- `swift test` 13/13；Xcode `test` 24/24（新增 11 个 `AppModelLifecycleTests`）；构建无编译警告。
- 主屏显示新图标；启动代理后灵动岛紧凑态显示绿色路由器图标，长按展开显示“代理运行中 / 端口 10808 / 连接数”，锁屏实时活动显示同样内容，连接数随保持的隧道变为 1。
- App 在后台时 `scripts/socks5_acceptance.py` 11/11 通过；`background_hold_acceptance.py` 180 秒 7/7，同一条隧道保持全程；`background_acceptance.py` 150 秒 7/7。
- 重新启动 App 会清掉上一个进程残留的实时活动。
- 停止代理后实时活动消失，10808 端口关闭。
- 模拟器不会产生真实的来电/Siri 中断，也不能代表真机的后台挂起策略；这些以真机结果为准。

2026-09-18 真机实测（iPhone 17 Pro Max，iOS 27.0，Wi-Fi 局域网，企业 VPN 已连接）：

- Mac 经 iPhone 的 SOCKS5（`--socks5-hostname`，域名在手机侧解析）和 HTTP 代理（HTTPS `CONNECT`）访问仅内网可达的 HTTPS 地址均成功（内网返回 301/401）；Mac 不经代理直连同一地址失败。
- 锁屏 15 分钟、两轮：保持连接 31/31 与 31/31（全程同一条隧道），新建连接（含 5 分钟空闲）14/14 与 13/13，全部经企业 VPN 访问内网成功。
- 灵动岛：心跳 + 过期时间的旧设计在锁屏约 4 分钟后误报灰色（代理实际正常，日志证实为系统拒绝后台音频进程的更新）；改为按事件更新后，锁屏 5.5 分钟仍为绿色，同时经代理访问内网正常。
- 注意：Mac 上 Xcode 自带的 `python3` 访问局域网时会被 macOS"本地网络"权限拦截（`No route to host`），`curl`/`nc` 不受影响；iPhone 上 App 的"本地网络"权限关闭时，经代理访问同一局域网内的设备会失败，访问公网和 VPN 内网不受影响。
- 未验证：来电/Siri/闹钟中断后的自动恢复、与其他 App 音视频同时播放、超过 15 分钟的长时间运行。

当前预期效果（2026-09-19 代码已构建、安装并启动；最终锁屏/灵动岛视觉待真机观察）：running 显示绿色，recovering 显示灰色；展开态和锁屏仅显示代理状态，compact/minimal 仅显示对应颜色的路由器图标，不显示连接数、LAN 地址或端口。
