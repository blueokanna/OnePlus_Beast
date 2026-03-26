<!-- markdownlint-disable MD022 MD024 MD032 -->

# OnePlus Beast Wi-Fi Module

## 简体中文

### 项目简介
这是一个面向 OnePlus 11 及后续数字旗舰 / Ace 系列的 KSU/Magisk Wi-Fi 模块。
它的目标是在**不修改 system 分区**的前提下，通过运行时属性、WCNSS 配置覆盖和 Wi-Fi 服务策略，尽可能实现以下效果：

- 默认强制 US 地区
- 使用 AU 风格的高功率档位，但保留热管理与健康安全降额
- 启用 JP 相关附加信道兼容
- 启用 6GHz、Wi-Fi 7、MLO、热点 6GHz 等能力
- 加入类似 WiFi 8 的稳定性增强策略

### 核心特性

#### 1. 国家码与区域策略
- 开机后默认锁定 US。
- 运行时持续重压制国家码，降低被框架或驱动回写成 CN 的概率。
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
| Multi-Link Operation | MLO 相关属性、链路平衡、重关联与修复 | 提升多链路稳定性和吞吐 |
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
   - 在安装阶段从 `/odm/vendor/etc/wifi/` 或 `/vendor/etc/wifi/` 提取 `WCNSS_qcom_cfg.ini`
   - 将补丁写入模块目录下的 `xml/WCNSS_qcom_cfg.ini`
   - 对缺失键执行补写，对已有键执行替换

2. `post-fs-data.sh`
   - 在开机早期把模块里的 `xml/WCNSS_qcom_cfg.ini` bind mount 到系统实际 Wi-Fi cfg 路径
   - 注入关键属性，使 Wi-Fi 框架尽早读取到模块配置

3. `service.sh`
   - 在系统启动后持续应用国家码、功率、MLO、热点 6GHz 和 WiFi 8 风格稳定性策略
   - 通过循环重压制，降低回退到 CN 的概率

### 安装方法

1. 使用 KSU 或支持 Magisk 模块的管理器安装本模块。
2. 重启设备。
3. 进入系统后打开 Wi-Fi，等待模块完成首轮锁定。
4. 如需确认是否生效，可查看日志：
   - `logcat -s OnePlusBeast`

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
2. 重启后检查日志：`logcat -s OnePlusBeast`
3. 确认 `WCNSS_qcom_cfg.ini` 是否已从模块目录挂载到实际 Wi-Fi 路径。
4. 如果国家码仍异常，优先检查是否有其他 Wi-Fi 模块冲突。

### 文件说明

- [customize.sh](customize.sh)
- [post-fs-data.sh](post-fs-data.sh)
- [service.sh](service.sh)
- [system.prop](system.prop)
- [module.prop](module.prop)
- [LICENSE](LICENSE)

## English

### Overview
This is a KSU/Magisk Wi-Fi module for OnePlus 11 and later OnePlus numeric flagship / Ace series devices.
It aims to enhance Wi-Fi behavior **without modifying the system partition**, using runtime properties, Wi-Fi cfg overlay, and service-side enforcement.

### Core Goals

- Force US as the default region
- Use an AU-style high-power profile with thermal/health-aware derating
- Enable JP-specific extra channel compatibility
- Enable 6GHz, Wi-Fi 7, MLO, and 6GHz hotspot support
- Add WiFi 8-like stability improvements

### Key Features

#### 1. Country / Regdom Policy
- US is locked by default after boot.
- The module continuously reasserts the country code to reduce fallback to CN.
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
- MLO link balancing and unstable link healing

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
| Multi-Link Operation | MLO properties, link balancing, reassociation, and healing | Better throughput and stability across links |
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
   - Extracts `WCNSS_qcom_cfg.ini` from `/odm/vendor/etc/wifi/` or `/vendor/etc/wifi/`
   - Writes a patched copy to `xml/WCNSS_qcom_cfg.ini`
   - Replaces existing keys and appends missing keys when needed

2. `post-fs-data.sh`
   - Bind-mounts the module’s cfg overlay onto the real Wi-Fi cfg path during early boot
   - Applies core props before the framework fully initializes

3. `service.sh`
   - Continuously enforces country, power, hotspot, MLO, and WiFi 8-like stability behavior
   - Reasserts the active region on a loop to resist fallback

### Installation

1. Install the module with KSU or a Magisk-compatible manager.
2. Reboot the device.
3. Open Wi-Fi after boot and wait for the initial enforcement cycle.
4. Check logs if needed:
   - `logcat -s OnePlusBeast`

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
2. Reboot and check `logcat -s OnePlusBeast`.
3. Confirm the Wi-Fi cfg overlay is mounted from the module directory.
4. Check for conflicts with other Wi-Fi modules first.
