<!-- markdownlint-disable MD022 MD024 MD032 -->

# OnePlus Beast Wi-Fi Module

## v2.6.1：修复重启后的厂商服务状态误判

PLK110 重启后的故障现场中，`init.svc.wifiDriverReload` 返回空值，但厂商服务声明、脚本及驱动文件均存在。v2.6 要求此属性必须为 `stopped`，因此误报设备未通过修复检查。

- 在验证机型、SoC、厂商服务声明和驱动文件后，允许服务状态为空或 `stopped` 时进入修复。
- 服务为 `running` / `restarting`，或驱动尚未加载时按暂时不可用处理，在原有观察窗口内推迟；不再直接判为设备不支持。
- 前置检查失败会显示并记录具体原因，覆盖旧的修复结果，避免读取到上一次成功的过期状态。
- 厂商服务启动后允许等待状态发布；等待超时仍会恢复 Wi-Fi，并停止本次尝试。
- 保留每个事件最多一次、跨事件冷却、热点保护及正常连接不反复重载的规则。

## v2.6：操作按钮与重启后初始化

在 KernelSU / Magisk 的模块卡片点击 **操作 / Action** 即可检查并修复 6GHz。
`action.sh` 使用管理器的原生按钮入口（[KernelSU 文档](https://kernelsu.org/guide/module.html#kernelsu-modules)、[Magisk 文档](https://topjohnwu.github.io/Magisk/guides.html#shell-scripts-sh)）。能力正常时只显示结果；确认异常时修复配置挂载和国家码，必要时重载一次厂商驱动，可能短暂中断 Wi-Fi。

- 检测 `system_server` 的 PID 与启动时间，识别不改变内核 boot ID 的框架热重启；执行 `service.sh` 或 `post-fs-data.sh` 会生成模块加载事件。
- 每个事件等待至少 20 秒，连续三轮确认 6GHz 信道缺失/禁用后才修复；观察窗口为 180 秒，每个事件最多尝试一次，跨事件自动修复至少间隔 120 秒。
- 先确认 init 挂载命名空间中的配置覆盖，再恢复国家码；国家码恢复后能力正常就不重载驱动。
- 失败后停止；普通 5GHz 连接、弱信号、未发现 6GHz AP 都不是修复依据。能力确实异常的启动事件允许一次修复，即使当时已连着 5GHz。
- Wi-Fi 关闭、热点/P2P-GO 使用中或查询未知时推迟；窗口结束仍不适合修复则保留现状，可稍后使用按钮。
- 后台与按钮共用内核文件锁；服务重复执行只通知现有服务，不产生多份重连循环。

`init.status` 记录事件初始化进度，`driver-init.status` 记录修复结果；`wifi-heartbeat.status` 仍是只读连接监测。下面 v2.5 的完全手动修复描述是历史行为，由本节的有界事件初始化替代。

验证：PLK110 / Android 17 真机上，修复前为 5220 MHz、CN、6GHz disabled；按钮路径修复后为 6935 MHz、US、6GHz enabled。再次通过管理器相同的 BusyBox standalone 环境执行按钮，会提示无需修复，链路变化计数保持不变。重复执行模块服务入口仍保留原服务进程。框架热重启事件、失败停止、跨事件冷却、关闭 Wi-Fi 和热点保护由模拟回归覆盖；本次未主动重启 Android 框架验证。

### v2.6 behavior (English)

The native module-card Action button checks and repairs 6 GHz capability. Framework
restart identity and module-script invocations open a 180-second initialization window.
After a 20-second settling period, three consecutive absent/disabled capability readings
permit one repair, with a 120-second cross-event cooldown. Configuration mounts and
country are restored first; the OEM driver is reloaded only if capability remains missing.
Failures stop, and ordinary missing APs or weak 5 GHz links never trigger repair. Off,
AP/GO and unknown states defer repair within the window. Manual and automatic requests
share a kernel lock. This replaces v2.5's strictly manual initialization policy below.

## 简体中文

### 项目简介
这是一个面向 OnePlus 11 及后续数字旗舰 / Ace 系列的 KSU/Magisk Wi-Fi 模块。
它的目标是在**不修改 system 分区**的前提下，通过运行时属性、WCNSS 配置覆盖和 Wi-Fi 服务策略，尽可能实现以下效果：

- 默认强制 US 地区
- 启用 6GHz、Wi-Fi 7、MLO、热点 6GHz 等能力

### 一加 15 / Android 17 适配（v2.5）

v2.5 优先保持当前连接。后台不再开关 Wi-Fi、重载驱动、主动扫描、刷新 Wi-Fi 资源或调用 `wpa_cli reassociate`。弱信号、低速、MLO 观测不完整和蜂窝状态变化都不会触发重连。

| 观察到的情况 | 模块处理 |
| --- | --- |
| 已连接 6GHz | 保持连接，记录状态 |
| 已连接 2.4/5GHz，即使附近有 6GHz 或信号弱 | 保持连接，由 Android 选择网络 |
| 未连接，最近缓存没看到 6GHz | 等待系统发现网络，不判定故障 |
| 缓存为空、超过 60 秒或查询失败 | 记为未知，不推断周围没有网络 |
| 未连接且驱动能力连续三次缺失/禁用 | 只提示 `manual_check_recommended` |
| Wi-Fi 关闭、热点/P2P-GO 活跃、连接状态未知 | 不干预 |

国家码只在连续三轮确认所有可见 STA 连接空闲后才允许更新，目标国家码不变时不会重复尝试。连接期间会推迟更新。原来的主动漫游开关默认关闭。

v2.4.2 已在 PLK110 / SM8850、Android 17、下述内核上通过 ADB 验证：
配置挂载与 US 国家码均生效时，旧驱动实例仍只上报 2.4/5GHz；执行一次手机自带的
`wifiDriverReload` 服务后，STA/SAP 6GHz 信道恢复，实际连接达到 **6935 MHz / Wi-Fi 7 / 320 MHz**。
这次验证没有改动配置内容，说明仅开关 Wi-Fi 不足以让该驱动实例重新读取挂载后的配置。

- 上述有中断的操作在 v2.5 移到独立手动入口，开机和后台均不调用它。
- 缺少附近的 6GHz 网络不构成修复条件。
- 状态中的监管域改为实际 Wi-Fi PHY 的国家码，避免把全局 `00` 误当成 self-managed PHY 的国家码。
- `driver-init.status` 记录一次性驱动初始化的返回码和 6GHz 状态。此修复不替换内核或厂商 `.ko`。

驱动初始化行为参考 [一加公开的驱动源码](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850/blob/oneplus/sm8850_b_16.0.0_oneplus_15/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_main.c)。

仅在你接受短暂断网并主动要求驱动修复时执行以下命令；它只处理已验证机型的驱动能力缺失，检测到热点、关闭 Wi-Fi 或未知状态时退出：

```sh
su -c 'sh /data/adb/modules/oneplus_global_wifi_beast/repair-wifi.sh --reload-driver'
```

v2.4.1 修复 KernelSU 安装时被 `OnePlus/OPPO Qualcomm device required` 拦截的问题。
检测优先使用 `/system/bin/getprop`，并组合 product/vendor/odm/system 等属性、SoC 型号和 hardware 标识，兼容 QTI、Qualcomm、Snapdragon 等写法。
属性缺失、读取失败或无法识别时会显示 `unverified` 并继续安装与运行时能力检测；明确检测到其他品牌或非 Qualcomm SoC 时仍会停止。
安装日志会先输出实际读取到的品牌、SoC 和判断原因；`unverified` 仅表示未确认机型，不代表功能验证通过。

本次适配目标是 **OnePlus 15 + Android 17**，用户提供的内核为
`6.12.69-android16-6-g5fd39602326e-ab16372235-4k`。
这是脚本模块，不包含 `.ko`、不替换内核，也不绑定某个内核提交或 OTA 构建号。
系统版本从 `ro.build.version.release` / `ro.build.version.sdk` 读取，内核版本从 `uname -r` 读取，页大小从 `getconf PAGESIZE` 读取。
内核名中的 `android16` 标识内核分支，不用于判断当前 Android 系统版本；参见 [AOSP 内核分支说明](https://source.android.com/docs/core/architecture/kernel/android-common)。

- 安装时发现 Wi-Fi 配置及芯片子目录，为每个文件单独生成覆盖副本；符号链接复制为普通文件，避免修改原文件。
- 配置项写在 `END` 之前，兼容键名周围空白和重复键。
- 根据设备实际的 `cmd wifi help` 探测可用命令；早期开机阶段不调用 Wi-Fi Binder 服务。
- 常驻监测只读；需要重载驱动时由用户明确触发手动修复。
- `iw` 查询失败记为 `unknown`，单网卡 MLO 的 5GHz 观测不再单独触发 6GHz 链路修复。

安装并重启后，可在 root shell 中查看：

```sh
cat /data/adb/modules/oneplus_global_wifi_beast/compatibility.status
cat /data/adb/modules/oneplus_global_wifi_beast/driver-init.status
cat /data/adb/modules/oneplus_global_wifi_beast/xml/overlays.list
cat /data/adb/modules/oneplus_global_wifi_beast/wifi-heartbeat.status
logcat -d -s OnePlusBeast OnePlusBeastHB
```

`compatibility.status` 记录机型、品牌与 SoC 原始属性、设备判断原因、系统、内核、页大小、工具及命令可用性；命令存在不代表驱动已接受配置。
没有 WCNSS 文件的 ROM 会跳过配置覆盖，没有 `iw` 时无法确认 PHY 的 6GHz 信道状态。
**v2.5 已在 PLK110 上通过 ADB 部署验证：实际连接为 5220 MHz（5GHz），PHY 6GHz 能力正常，最近扫描缓存未看到 6GHz，监测选择 `keep_connection`。更新前后 `wlan0/carrier_changes` 均为 8，未调用 Wi-Fi 开关或驱动重载。其他异常场景由本地回归覆盖。**
已验证 6GHz STA 连接及 SAP 信道列表，未验证实际 6GHz 热点客户端连接或多链路 MLO 聚合。写入属性本身不代表功能已生效。

### 核心特性

#### 1. 国家码与区域策略
- 开机后默认锁定 US。
- 连接期间保留当前监管域，空闲状态才允许有限的国家码更新。
- 同时同步 `ro.boot.wificountrycode`、`persist.*`、`iw reg` 和 `cmd wifi force-country-code`。

#### 2. 发射功率策略
- 目标是 AU 风格的高功率档位。
- 运行时会根据温度、信号与屏幕状态进行动态降额。
- 尽量在稳定性、温控和续航之间做平衡。

#### 3. JP 附加信道兼容
- 额外开放 2.4G 的 14 信道相关兼容开关。
- 5G 的 144 信道相关兼容开关。
- 通过 WCNSS 配置和运行时属性双路径保障。

#### 4. 6GHz / Wi-Fi 7 / MLO
- 启用 6GHz、Wi-Fi 7、EHT、MLO、Bridged AP、DBS、ACS 等关键能力。
- 热点侧强制 6GHz 逻辑也已加入。

#### 5. WiFi 8 风格稳定性增强
- 协调式 TWT
- 多 AP 协同
- OFDMA 多 RU
- DSO / NPCA
- DRU 调度
- MLO 链路平衡与不稳定链路修复

### 为什么这样设计

这套组合不是随意堆叠开关，而是按“先可用、再稳定、再尽量接近 WiFi 8 体验”的顺序设计：

- US 作为基础地区，优先保证 OnePlus / Qualcomm Wi‑Fi 框架最容易接受的 regdom 行为。
- AU 风格功率档用于争取更宽松的发射能力，但在脚本层加了热管理和信号判断，避免盲目拉满。
- JP 附加信道兼容用于补足部分路由器和部分频段场景下的可见性和可连性。
- 6GHz / Wi‑Fi 7 / MLO / 热点 6GHz 是核心能力，先保证你这套 Wi‑Fi 7 路由器与终端真正用起来。
- WiFi 8 风格部分是把 WiFi 8 里更偏调度、协同、恢复的能力，尽可能映射到现有 Wi‑Fi 7 平台可执行的策略上。

### WiFi 8 特性对应表

| WiFi 8 特性 | 本模块对应做法 | 作用 |
| --- | --- | --- |
| Coordinated TWT | `persist.vendor.wifi.twt_coordinated_enabled=1`，并持续下发相关策略 | 更好的定时唤醒与低功耗协同 |
| Multi-Link Operation | MLO 相关属性与被动链路观测 | 保持连接，由系统选择链路 |
| Multi-AP Coordination | 多 AP 协同相关开关 | 在复杂网络环境中更稳 |
| OFDMA (# RU per STA) | 开启 OFDMA 多 RU 相关属性 | 更细粒度的空口资源分配 |
| DSO / NPCA | 开启 DSO / NPCA 相关开关 | 降低调度抖动，改善并发体验 |
| DRU | 开启 DRU 调度相关属性 | 提升链路调度灵活性 |
| UL & DL MU-MIMO | 开启上下行 MU-MIMO 优化开关 | 在支持环境下提升并发效率 |
| 320 MHz / 4096 QAM | 依赖终端、AP、固件真实支持；模块只负责尽量放开上层限制 | 不伪造硬件，只减少上层阻碍 |

### 说明

- 上表中的部分能力属于标准层，部分属于厂商实现层，部分属于运行时调度层。
- 本模块做的是“尽量把能打开的全部打开，并让系统持续保持在最优策略上”。
- 它不会把不支持的硬件强行变成支持，但会尽量减少配置、地区和框架策略造成的损失。

### 工作原理

本模块不直接修改 system 分区文件。
它主要通过三层方式工作：

1. `customize.sh`
   - 在安装阶段扫描 `/odm/vendor/etc/wifi/`、`/odm/etc/wifi/`、`/vendor/etc/wifi/`、`/vendor/firmware/wlan/`、`/mnt/vendor/persist/wlan/` 下的 `WCNSS_qcom_cfg.ini`
   - 将补丁写入模块目录下的 `xml/cfg_*.ini`，用 `xml/overlays.list` 记录目标路径
   - 对缺失键执行补写，对已有键执行替换

2. `post-fs-data.sh`
   - 在开机早期按清单把模块里的配置副本 bind mount 到对应 Wi-Fi cfg 路径，并记录挂载结果
   - 注入关键属性，使 Wi-Fi 框架尽早读取到模块配置

3. `service.sh`
   - 在系统启动后设置功能属性，并按连接状态调整功率策略
   - 空闲时有限更新国家码，连接期间保持现有连接

### 安装方法

1. 使用 KSU 或支持 Magisk 模块的管理器安装本模块。
2. 重启设备。
3. 进入系统后打开 Wi-Fi，等待模块完成首轮锁定。
4. 如需确认是否生效，可查看日志：
   - `logcat -s OnePlusBeast OnePlusBeastHB`
   - 心跳日志：`/data/adb/modules/oneplus_global_wifi_beast/wifi-heartbeat.log`
   - 心跳状态：`/data/adb/modules/oneplus_global_wifi_beast/wifi-heartbeat.status`

### 常用参数

#### 默认值
- 国家码：US
- 功率档：AU 风格高功率档
- JP 兼容：开启
- 热点 6GHz：开启
- WiFi 8 风格稳定性：开启

#### 可调属性
以下属性可以按需修改：

- `persist.sys.opb.wifi.hard_unlock_mode`
  - `1` = 开启强制国家码模式
- `persist.sys.opb.wifi.hard_unlock_country`
  - 默认 `US`
- `persist.sys.opb.txpower.max_mbm`
  - 默认 `3000`
- `persist.sys.opb.txpower.target_ratio`
  - 默认 `100`
- `persist.sys.opb.hotspot_6ghz_force`
  - `1` = 强制热点 6GHz
- `persist.sys.opb.6ghz.heartbeat`
  - `1` = 开启只读 6GHz 状态监测
- `persist.sys.opb.6ghz.heartbeat_interval`
  - 默认 `5` 秒，可设置范围为 `5` 到 `60`
- 旧版 `persist.sys.opb.6ghz.recovery_cooldown` 已不使用；后台不存在自动断连恢复。

### 重要说明

- 本模块不会修改 system 分区。
- 实际最终效果仍然受设备驱动、固件、地区法规和路由器侧能力影响。
- 稳定性增强策略，不代表真实的 802.11bn 硬件能力。

### 免责声明

- 本模块按“现状”提供，不附带任何明示或暗示担保。
- 使用、刷入、卸载、回滚、二次修改、重新打包过程中产生的任何问题，包括但不限于无法开机、Wi-Fi 异常、热点异常、信号异常、地区限制、兼容性问题、性能下降、发热升高、数据丢失或其他潜在损失，均由使用者自行承担。
- 本项目作者、维护者与贡献者不对因使用本模块造成的任何直接、间接、附带、特殊、惩罚性或后果性损害负责。
- 你应当在确认设备、固件、地区与路由器环境允许的前提下使用本模块。

### 法规与合规

- 本模块中的国家码、信道、功率、6GHz、Wi-Fi 7、MLO 与热点相关设置，仅应在当地法规、设备许可和网络环境允许的范围内使用。
- 如果你的国家、地区、运营商、监管要求或设备固件不允许某些频段或功率，请不要启用对应功能。
- 你应自行确认你的使用场景符合适用的无线电、射频、通信与终端设备管理规定。
- 本模块不提供任何规避监管、绕过认证、突破法定义务或规避地区限制的承诺。

### 开源许可

- 本项目采用 AGPL-3.0-only 许可。
- 你可以在遵守 AGPL-3.0-only 条款的前提下使用、修改和分发本项目。
- 如果你基于本项目做了修改并对外提供服务、分发或再发布，你需要遵守 AGPL 对源代码提供、许可证保留与修改公开的要求。
- 若你希望使用更宽松的许可，请不要默认假设本项目可以按其他许可证使用。

### 排障建议

如果你发现没有生效：

1. 确认模块已启用。
2. 重启后检查日志：`logcat -s OnePlusBeast OnePlusBeastHB`
3. 检查模块目录内的 `wifi-heartbeat.log` 和 `wifi-heartbeat.status`。
4. 确认 WCNSS 配置是否已从模块目录挂载到实际 Wi-Fi 路径。
5. 如果国家码仍异常，优先检查是否有其他 Wi-Fi 模块冲突。

### 文件说明

- [customize.sh](customize.sh)
- [compat.sh](compat.sh)
- [post-fs-data.sh](post-fs-data.sh)
- [service.sh](service.sh)
- [wifi-heartbeat.sh](wifi-heartbeat.sh)
- [system.prop](system.prop)
- [module.prop](module.prop)
- [LICENSE](LICENSE)

## English

### Overview
This is a KSU/Magisk Wi-Fi module for OnePlus 11 and later OnePlus numeric flagship / Ace series devices.
It aims to enhance Wi-Fi behavior **without modifying the system partition**, using runtime properties, Wi-Fi cfg overlay, and service-side enforcement.

### OnePlus 15 / Android 17 compatibility (v2.5)

Connection preservation is the default. Automatic scripts never toggle Wi-Fi, reload
the driver, request reassociation, initiate scans or reload Wi-Fi resources. Existing
2.4/5 GHz links, weak signals, low rates and incomplete MLO observations stay connected.
The observer distinguishes PHY capability, actual association and cached scan results.
Empty, stale (>60 seconds) or failed queries remain unknown. Three consecutive missing
capability samples while disconnected produce a manual-check recommendation only.
Wi-Fi-off and AP/GO states are respected. Country changes are deferred while connected
and attempted after three idle observations, without retrying an unchanged target.

An explicitly requested OEM driver reload previously restored a real 6935 MHz / Wi-Fi 7 /
320 MHz link on PLK110 / SM8850. That disruptive operation is now available only through
`sh /data/adb/modules/oneplus_global_wifi_beast/repair-wifi.sh --reload-driver` as root;
boot and background scripts do not call it. Missing nearby APs are not a repair trigger.

v2.4.1 fixes overly strict install-time device rejection. Detection prefers native
`/system/bin/getprop`, checks partition-specific identity properties and SoC/hardware
fallbacks, and accepts QTI/Qualcomm/Snapdragon identifiers. Missing, unreadable or unknown
properties produce an `unverified` warning and allow capability checks to continue;
positive evidence of an incompatible brand or SoC still stops the module. Installation
logs and `compatibility.status` include the observed properties and decision reason.

Target: OnePlus 15 running Android 17 with the reported kernel
`6.12.69-android16-6-g5fd39602326e-ab16372235-4k`.
This is a shell module, with no kernel replacement or `.ko` dependency. Android release/SDK,
kernel release and page size are detected independently; the kernel branch is not used as
the userspace Android version. OTA build hashes are not pinned.

The installer discovers per-chipset WCNSS files, copies symlink targets into independent
overlays and places settings before `END`. Runtime commands are selected from the device's
`cmd wifi help`. Background monitoring is read-only. Driver repair requires explicit user action. Failed PHY queries
remain unknown, and a single 5 GHz netdev does not imply a stalled 6 GHz MLO link.

Read `compatibility.status`, `xml/overlays.list` and `wifi-heartbeat.status` in the installed
module directory, plus `logcat -s OnePlusBeast OnePlusBeastHB`, to inspect the actual device.
Missing WCNSS files skip overlays; missing `iw` leaves PHY state unknown. Command availability
and property writes do not prove firmware support. **v2.5 was deployed and observed on PLK110: an existing 5220 MHz link, enabled 6 GHz PHY capability and no 6 GHz AP in the recent cache produced `keep_connection`. The carrier-change counter stayed at 8 across deployment, with no Wi-Fi toggle or driver reload. Other fault scenarios have local regression coverage. Actual 6 GHz hotspot client connectivity and MLO aggregation have not been verified.**

### Core Goals

- Observe capability, association and cached scan results every 5 seconds by default
- Keep existing connections and report confirmed capability issues for manual review
- Keep the 6GHz channel table available across cellular registration and airplane-mode changes
- Treat missing or stale observations as unknown without forcing reconnects
- Use module overlays and runtime properties without writing system, vendor, odm, or persist partition files
- Force US as the default region
- Use an AU-style high-power profile with thermal/health-aware derating
- Enable JP-specific extra channel compatibility
- Enable 6GHz, Wi-Fi 7, MLO, and 6GHz hotspot support
- Add WiFi 8-like stability improvements

### Key Features

#### 1. Country / Regdom Policy
- US is locked by default after boot.
- Country updates are deferred while connected and attempted conservatively while idle.
- It synchronizes `ro.boot.wificountrycode`, `persist.*`, `iw reg`, and `cmd wifi force-country-code`.

#### 2. Power Policy
- The target profile follows an AU-style high-power configuration.
- Runtime derating is applied based on thermal state, signal quality, and screen state.
- The goal is stability and safe sustained operation, not blind maximum output.

#### 3. JP Channel Compatibility
- Adds compatibility for 2.4GHz channel 14.
- Adds compatibility for 5GHz channel 144.
- Applies both cfg-level and runtime property-level enforcement.

#### 4. 6GHz / Wi-Fi 7 / MLO
- Enables 6GHz, Wi-Fi 7, EHT, MLO, Bridged AP, DBS, ACS, and related toggles.
- 6GHz hotspot support is also forced in runtime logic.

#### 5. WiFi 8-like Stability Layer
- Coordinated TWT
- Multi-AP coordination
- OFDMA multi-RU
- DSO / NPCA
- DRU scheduling
- Passive MLO/link observation without forced reassociation

### Why This Design

This combination is not random tuning; it is intentionally built in the order of “usable first, stable second, and WiFi 8-like where the platform can actually support it”:

- US is used as the base region because it is generally the safest default for OnePlus / Qualcomm Wi‑Fi policy handling.
- The AU-style power target gives you a more permissive ceiling, while runtime derating keeps temperature and sustained RF behavior in check.
- JP channel compatibility helps expose extra channel options in mixed router environments.
- 6GHz / Wi‑Fi 7 / MLO / 6GHz hotspot are the core capabilities, so your Wi‑Fi 7 router and terminal can actually use the available performance.
- The WiFi 8-like part is not a fake standard; it maps WiFi 8’s scheduling and coordination ideas onto what the current Wi‑Fi 7 platform can realistically enforce at runtime.

### WiFi 8 Feature Mapping

| WiFi 8 feature | Module mapping | Purpose |
| --- | --- | --- |
| Coordinated TWT | `persist.vendor.wifi.twt_coordinated_enabled=1` plus runtime enforcement | Better wake scheduling and power coordination |
| Multi-Link Operation | MLO properties and passive link observation | Better throughput and stability across links |
| Multi-AP Coordination | Multi-AP coordination toggles | Better roaming and dense-network behavior |
| OFDMA (multiple RUs per STA) | OFDMA multi-RU toggles | Finer air-time allocation |
| DSO / NPCA | DSO / NPCA toggles | Less scheduling jitter and better concurrency |
| DRU | DRU scheduling toggles | More flexible resource scheduling |
| UL & DL MU-MIMO | UL/DL MU-MIMO optimization toggles | Better concurrent transmission efficiency |
| 320 MHz / 4096 QAM | Depends on actual AP/device support; the module only removes policy barriers | No fake hardware claims |

### Notes

- Some items above are standard-level capabilities, some are vendor-level toggles, and some are runtime coordination policies.
- The module’s job is to enable what can be enabled and keep the Wi‑Fi stack in the best practical state.
- It cannot turn unsupported hardware into supported hardware, but it can reduce losses caused by region and framework restrictions.

### How It Works

The module avoids modifying the system partition and works in three stages:

1. `customize.sh`
   - Discovers `WCNSS_qcom_cfg.ini` in ODM/vendor Wi-Fi, vendor WLAN firmware and persist WLAN directories, including chipset subdirectories
   - Writes independent patched copies to `xml/cfg_*.ini` and records targets in `xml/overlays.list`
   - Replaces existing keys and appends missing keys when needed

2. `post-fs-data.sh`
   - Bind-mounts the module’s cfg overlay onto the real Wi-Fi cfg path during early boot
   - Applies core props before the framework fully initializes

3. `service.sh`
   - Sets feature properties after boot and adjusts power policy based on connection state
   - Defers country updates during connections and observes network state without reconnecting

### Installation

1. Install the module with KSU or a Magisk-compatible manager.
2. Reboot the device.
3. Open Wi-Fi after boot and wait for the initial enforcement cycle.
4. Check logs if needed:
   - `logcat -s OnePlusBeast OnePlusBeastHB`

### Default Profile

- Country: US
- Power profile: AU-style high-power target
- JP compatibility: enabled
- 6GHz hotspot: enabled
- WiFi 8-like stability: enabled

### Adjustable Properties

- `persist.sys.opb.wifi.hard_unlock_mode`
  - `1` enables hard country lock mode
- `persist.sys.opb.wifi.hard_unlock_country`
  - Default `US`
- `persist.sys.opb.txpower.max_mbm`
  - Default `3000`
- `persist.sys.opb.txpower.target_ratio`
  - Default `100`
- `persist.sys.opb.hotspot_6ghz_force`
  - `1` forces 6GHz hotspot mode
- `persist.sys.opb.6ghz.heartbeat`
  - `1` enables the read-only 6GHz monitor
- `persist.sys.opb.6ghz.heartbeat_interval`
  - Observation interval in seconds, clamped from `5` to `60`; default `5`
- The former `persist.sys.opb.6ghz.recovery_cooldown` is unused; automatic disconnect recovery has been removed.

### Important Notes

- The module does not modify the system partition.
- Final behavior still depends on the device driver, firmware, regional regulations, and router support.
- “WiFi 8-like” refers to stability-oriented behavior, not literal 802.11bn hardware support.

### Disclaimer

- This module is provided “as is”, without warranties of any kind.
- Any issues caused by installing, using, uninstalling, rolling back, or repackaging this module, including boot failures, Wi-Fi instability, hotspot issues, signal issues, regional restrictions, compatibility problems, performance degradation, extra heat, data loss, or any other damage, are solely the user’s responsibility.
- The author, maintainers, and contributors are not liable for any direct, indirect, incidental, special, punitive, or consequential damages arising from the use of this module.
- You should only use this module when your device, firmware, region, and router environment permit it.

### Legal / Regulatory Compliance

- Country code, channel, power, 6GHz, Wi-Fi 7, MLO, and hotspot settings should only be used within the limits of local laws, regulations, device authorization, and router/environment support.
- If your country, region, carrier, regulator, or firmware does not allow certain bands or power levels, do not enable those functions.
- You are responsible for verifying compliance with applicable radio, RF, telecom, and device regulations.
- This project does not promise or encourage bypassing regulatory requirements, certifications, or regional restrictions.

### License

- This project is licensed under AGPL-3.0-only.
- You may use, modify, and redistribute it only in compliance with AGPL-3.0-only.
- If you modify and redistribute this project, or provide it as part of a service, you must comply with AGPL source disclosure and license-preservation requirements.
- Do not assume any broader rights than those granted by AGPL-3.0-only.

### Troubleshooting

If the module does not appear to work:

1. Make sure the module is enabled.
2. Reboot and check `logcat -s OnePlusBeast OnePlusBeastHB`.
3. Check `wifi-heartbeat.log` and `wifi-heartbeat.status` in the module directory.
4. Confirm the Wi-Fi cfg overlays are mounted from the module directory.
5. Check for conflicts with other Wi-Fi modules first.
