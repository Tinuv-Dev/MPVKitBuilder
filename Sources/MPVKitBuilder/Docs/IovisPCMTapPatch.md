# iovis PCM Tap · 实时转录字幕全链路设计与落地

> 状态：**全链路已在 tvOS 真机验证通过（实验阶段）**。
> 已验证：libmpv 补丁出 PCM（M3）→ Swift 拿到字节、dump WAV 可听（M4）→ `SpeechTranscriber` 实时出文本（转录打通）。
> 分支：MPVKitBuilder `exp/ao-iovis-tap`；补丁 `Sources/MPVKitBuilder/Resources/Patch/libmpv/0001-add-iovis-pcm-tap.patch`。
> 上层需求文档：`IovisPlayertvOS/Docs/LiveCaptioning-CustomAO-Prerequisites.md`。
>
> **本文是工程落地依据**：包含为什么这么做、实测数据、完整 API 用法、实验里走的捷径、以及产品化必须补齐的优化/修复项。实验代码全部可 git 回退，落地时按第八/十节重写到生产形态。

---

## 一、整条链路总览

```
 mpv 解码 → 音频滤镜链 → AO 缓冲(buffer_state)
                              │  ao_read_data() 填好成品 PCM
                              ▼
        [PATCH] iovis_tap_feed(ao, data, pos, out_time_ns)   ← audio/out/buffer.c
                              │  只读拷贝，不改数据流
                              ▼
        iovis_tap_set_callback 注册的 C 回调（mpv 音频线程）   ← audio/out/iovis_tap.c
                              │
══════════════════ 进程内 C ABI 边界 ═══════════════════════
                              │  IovisTapBridge（Swift 可见的 C 声明）
                              ▼
        IovisLiveTranscriber.feed(chunk)                      ← IovisPlayerCore
          取 plane0 (floatp 左声道) → AVAudioPCMBuffer(44100/mono/float)
                              │  AVAudioConverter 转成分析器格式(典型 16kHz/mono)
                              ▼
        AsyncStream<AnalyzerInput> → SpeechAnalyzer.analyzeSequence
                              │
                              ▼
        transcriber.results (AsyncSequence) → result.text (AttributedString)
                              ▼
                        实时字幕文本
```

链路分两段，落在两个仓库：

- **第一段（MPVKitBuilder）**：给 libmpv 打补丁，把 AO 层的成品 PCM 经一个进程级 C 回调暴露出来。见第二~四节。
- **第二段（IovisKit）**：在 `IovisPlayerCore` 里桥接该 C 符号、做格式转换、喂给 tvOS 26 的 `SpeechAnalyzer`/`SpeechTranscriber`。见第五~六节。

---

## 二、第一段为什么必须打补丁（不能只改编译参数）

Apple TV 上识别端（`SpeechAnalyzer`/`SpeechTranscriber`）没有瓶颈，瓶颈是**实时拿到 mpv 解码后的 PCM**。核实 libmpv `v0.41.0` 源码后确认：

- `include/mpv/render.h` 的 render API 只覆盖视频；`include/mpv/client.h:1334` 在 `MPV_EVENT_AUDIO_RECONFIG` 注释里明确写 *"there is no such thing as audio output embedding"*——**没有任何公开音频回调**。
- 现有 AO 全是终端 sink：`audiounit`/`coreaudio` 交给系统但不外露，`pcm` 写文件且独占 ao（开了没声），`null` 静音，`lavc` 是编码模式。
- meson option 只能开关**已存在**的源文件，开不出新能力。

**结论**：必须给 libmpv 打源码补丁；**FFmpeg 不用动**（抽取点在 mpv 的 AO 层，是解码+滤镜之后、与播放对齐的成品 PCM，完全在 mpv 内）。

### 关键发现：tap 点不是「tee AO」，而是 `ao_read_data`

前置文档最初设想 push 型 tee AO（`--ao=iovis_tap,audiounit`，在 `write()` 转发）。核实源码后**不成立**：

- tvOS `audiounit`、macOS `coreaudio`、`avfoundation` **全是 pull 模型**：没有 `.write`，靠各自渲染回调主动调 `ao_read_data(ao, …)` 拉数据（`audio/out/ao_audiounit.m:100`、`ao_coreaudio.c:98`、`ao_avfoundation.m:80`）。
- mpv 的 `buffer_state`（`audio/out/buffer.c`）是「一个 ao 一份缓冲、由 core 单向喂」。在 AO 内部再 spawn 下级 pull AO 并替它泵数据，要深挖内部状态，复杂且脆弱。

三种 pull AO 都汇流到 `audio/out/buffer.c:207` 的 `ao_read_data()`。它持锁填好成品 PCM、返回真实样本数 `pos`、解锁。**在解锁后挂一个只读钩子**即可：一处改动覆盖全部 Apple AO、完全不碰 `--ao`、只读拷贝不改数据流、默认关闭（没注册回调就什么都不做）。

> 与前置文档的偏差：放弃命名 AO 方案，改为 read-side tap；运行时开关由「是否注册回调」决定。

---

## 三、补丁做了什么

4 处改动（`git diff --stat`：4 files, +99）：

| 文件 | 类型 | 内容 |
|---|---|---|
| `audio/out/iovis_tap.h` | 新增 | `iovis_tap_set_callback` + `struct iovis_tap_chunk` + 内部入口 `iovis_tap_feed` |
| `audio/out/iovis_tap.c` | 新增 | 注册了回调就喂 chunk；没注册就按约每秒打一行 `MP_INFO` 日志（M3 自验证用） |
| `audio/out/buffer.c` | 改 | `#include "iovis_tap.h"`；`ao_read_data` 解锁后插一行 `iovis_tap_feed(ao, data, pos, out_time_ns)` |
| `meson.build` | 改 | 把 `audio/out/iovis_tap.c` 加进 sources |

### chunk 契约（与 Swift 侧桥接必须逐字段对齐）

```c
struct iovis_tap_chunk {
    const void *data;     // PCM 样本（plane 0）
    int samples;          // 实际填充的真实帧数（不含静音补齐）
    int channels;
    int samplerate;
    int format;           // AF_FORMAT_*
    int64_t pts_us;       // out_time_ns / 1000：最后一个样本到达扬声器前的延迟
};
typedef void (*iovis_tap_callback)(void *user, const struct iovis_tap_chunk *chunk);
void iovis_tap_set_callback(iovis_tap_callback cb, void *user);  // 全进程一次性注册，cb=NULL 关闭
```

ABI 内存布局（务必与桥接一致）：`data`(8) + `samples/channels/samplerate/format`(4×4=16) + `pts_us`(8, 偏移 24, 8 对齐) = **32 字节**。

### 设计取舍

- **线程**：回调在 mpv 音频拉取线程，**禁止阻塞**；注册用 `atomic` 存取避免与音频线程竞争。
- **样本数**：`pos` 是真实样本数（静音补齐不计入），暂停时 `pos=0` 自动跳过——转录在暂停时自然停止。
- **时间戳**：暂用 `out_time_ns/1000`，语义是「到扬声器的延迟」（含设备缓冲），**非** `time-pos`（见第九节，需校准）。
- **平面**：第一版只暴露 `data[0]`。交错格式即整块；planar 只给第一个平面。
- **默认关闭**：没注册回调只有一行节流日志，不改播放行为。

### 实验期刻意简化（产品化要补）

- **没加 `-Diovis_tap` meson 选项**：直接无条件编入 sources（纯 C、无平台依赖），运行时靠回调开关。
- **没改 `LibMpvBuilder.swift`**：无条件编入就不需要追加 meson 参数。

---

## 四、补丁怎么被构建系统应用

- `Builder.preCompile()`（`Sources/MPVKitBuilder/Builders/Builder.swift:50`）扫描 `Resources/Patch/<lib>/*.patch`，按文件名排序应用。
- `applyPatchIfNeeded()`（同文件 `:280`）先 `git apply --check` 再 apply；已应用的（reverse-check 通过）跳过，**幂等**。
- 源码已存在时 `obtainSource()` 跳过 clone，patch 应用在现有源码树。

新增补丁丢进 `Sources/MPVKitBuilder/Resources/Patch/libmpv/` 即自动生效。

### 单平台快速迭代

```bash
make build only=libmpv force=libmpv platform=macos          # 最快，先验逻辑
make build only=libmpv force=libmpv platform=tvossimulator  # 或 tvOS 模拟器
```

- `force=libmpv` **必须带**：否则已有 `.a` 被 `builtLibrariesExist` 跳过（`Builder.swift:93`）；它只清 libmpv 产物，不动 ffmpeg 等依赖与源码树。
- 平台名（`PlatformType.parse`）：`macos / ios / iossimulator / tvos / tvossimulator / maccatalyst / visionos / visionossimulator`。

校验补丁可干净应用：

```bash
cd build/libmpv-source-v0.41.0 && git checkout -- .
git apply --check ../../Sources/MPVKitBuilder/Resources/Patch/libmpv/0001-add-iovis-pcm-tap.patch && echo OK
```

校验符号编进产物：

```bash
nm dist/Libmpv.xcframework/tvos-arm64/Libmpv.framework/Libmpv | grep iovis_tap
# 期望：T _iovis_tap_set_callback / T _iovis_tap_feed（buffer.c 处为 U 引用）
```

---

## 五、第二段：IovisKit 接入

> 实验期所有改动都在 IovisKit，且都 git 可回退。文件清单见第十二节。

### 5.1 把依赖指向打过补丁的本地 MPVKit

`IovisKit/Package.swift`：

```swift
dependencies: [
    .package(path: "/Users/tinuv/Downloads/MPVKit-20260529-1011"),   // 原为远端 mpvkit
],
// IovisPlayerCore 的产品引用同步改名（path 依赖 identity = 目录名）
.product(name: "MPVKit", package: "MPVKit-20260529-1011"),
```

> 生产应改为：fork MPVKit + 自定义 tag（如 `0.41.0-iovis.1`），`Package.swift` pin 到该 tag。见前置文档 4.2/4.6。

### 5.2 桥接 C 符号：`IovisTapBridge`

补丁里的 `iovis_tap.h` 在 `audio/out/`，**没进** xcframework 公开头，所以 `Libmpv` 模块里没有该声明。实验期用一个 C target 重新声明（链接期由 Libmpv 提供定义）：

- `Sources/IovisTapBridge/include/IovisTapBridge.h`：逐字段复刻 `iovis_tap_chunk` + `iovis_tap_set_callback` 声明。
- `Sources/IovisTapBridge/shim.c`：仅 `#include`，占位（SwiftPM 的 C target 需至少一个源）。
- `Package.swift`：新增 `.target(name: "IovisTapBridge")`，`IovisPlayerCore` 依赖之。

> **脆弱点**：桥接头是手抄的，一旦 mpv 侧 chunk 布局变了、桥接没同步，会静默读错内存。**产品化必须把 `iovis_tap.h` 纳入 MPVKit 打包公开头**（见第八节），消费方直接 `import Libmpv` 用，不再手抄。

### 5.3 注册点

`IovisPlayer+MPV.swift` 的 `configureCallbacks(for:)` 里进程级注册一次（tap 回调是单槽）：

```swift
if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
    IovisLiveTranscriber.shared.enable()   // 要回到 WAV dump 改成 IovisPCMTapRecorder.shared.enable()
}
```

### 5.4 两个消费者（实验用，二选一）

- `IovisPCMTapRecorder`：抓前 15s plane0 落 mono float32 WAV + 经原始 TCP 推回 Mac（验证 PCM 字节正确）。
- `IovisLiveTranscriber`：把 PCM 喂 `SpeechTranscriber`，结果打 console（验证转录链路）。

两者都通过 `iovis_tap_set_callback` 注册同一个全进程回调，**只能存在一个**。

---

## 六、SpeechAnalyzer / SpeechTranscriber API 用法（已验证）

> 来源：Apple 官方文档 + WWDC25 session 277 示例。可用性：iOS/macOS/tvOS/visionOS **26.0+**。全程**本地、无服务器**。

### 6.1 标准 8 步流程

```swift
import Speech

// 1. 选 locale（同步，非 async）+ 建 transcriber
guard let locale = SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { /* 不支持 */ }
let preset = SpeechTranscriber.Preset.progressiveTranscription      // 实时音频：volatile + fast
let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: preset.transcriptionOptions,
    reportingOptions: preset.reportingOptions,
    attributeOptions: preset.attributeOptions
)

// 2. 装资产（首次需联网下载语音模型）
if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await request.downloadAndInstall()
}

// 3. 取分析器格式（分析器不自动转码，必须我们转到这个格式）
guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
    /* 资产仍缺失 */
}

// 4. 输入流 + 分析器
let (sequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
let analyzer = SpeechAnalyzer(modules: [transcriber])

// 5. 消费结果
Task {
    for try await result in transcriber.results {
        let text = String(result.text.characters)      // result.text 是 AttributedString
        // result.isFinal == false 是实时临时结果（会刷新修正），true 是定稿
    }
}

// 6. 喂音频（在 tap 回调里 builder.yield(AnalyzerInput(buffer: 转换后的buffer))）
// 7. 跑分析
_ = try await analyzer.analyzeSequence(sequence)
// 8. 收尾：finalizeAndFinishThroughEndOfInput() / finalizeAndFinish(through:) / cancelAndFinishNow()
```

预设对照（`SpeechTranscriber.Preset`）：实时字幕用 **`progressiveTranscription`**（volatile+fast）或 `timeIndexedProgressiveTranscription`（带时间码）。

### 6.2 音频格式转换（关键）

分析器**不做采样率/格式转换**（为保 `CMTime` 采样精度）。我们的 PCM 是 `floatp / 44100 / stereo`，分析器要的典型是 `16kHz / mono / float`，所以：

```swift
// 源格式：取 plane0 当 mono；采样率应来自 chunk.samplerate（实验里写死 44100，是 bug，见第八节）
let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
let converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)

// 每个 tap chunk：plane0 → AVAudioPCMBuffer → 转换 → yield
let inBuf = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)!
inBuf.frameLength = frames
memcpy(inBuf.floatChannelData![0], chunk.data, Int(chunk.samples) * MemoryLayout<Float>.size)

let outBuf = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outCap)!
var fed = false
converter.convert(to: outBuf, error: &err) { _, status in
    if fed { status.pointee = .noDataNow; return nil }
    fed = true; status.pointee = .haveData; return inBuf      // 流式重采样：喂一块、出一块
}
if outBuf.frameLength > 0 { builder.yield(AnalyzerInput(buffer: outBuf)) }
```

`AnalyzerInput(buffer:)` 假设与上一块连续；seek/跳读要用 `AnalyzerInput(buffer:bufferStartTime:)` 显式给时间码（见 `init(buffer:bufferStartTime:)` 的 priming 警告）。

### 6.3 鉴权 / Info.plist

新本地 API 实测**不需要** `SFSpeechRecognizer.requestAuthorization`。若运行崩在缺 usage description，给 Example target 加构建设置 `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription`。

---

## 七、端到端验证步骤与排错（真机）

### 验证

1. MPVKit 出包后 `nm` 确认 `iovis_tap_*` 符号在 tvOS slice（第四节）。
2. IovisKit 指向本地包，`swift package resolve` 通过。
3. Xcode 打开 `IovisKit.xcworkspace`，必要时 **File → Packages → Reset Package Caches**。
4. 跑 Example 到 Apple TV，播**与系统语言一致**的有声内容。
5. 控制台依次：`🎙 正在下载语音模型资产…` → `🎙 资产就绪` → `🎙 transcriber 就绪 locale=… analyzerFormat=16000.0Hz/1ch` → `📝 [volatile]/[final] <文本>`。

### tvOS 取文件的两个坑（已踩，记录备查）

- **Documents 不可写**：真机 tvOS 沙盒 Documents 写入报 `NSPOSIXErrorDomain Code=1`。只能写 `Library/Caches` 或 `tmp`。
- **Download Container 失败**：整包拉取会卡在 `Library/Caches/com.apple.dyld/…`（系统文件，权限拒绝），取不到你的文件。改用**网络推回**：App 用原始 TCP（`Network.NWConnection`，**绕过 ATS，无需改 Info.plist**）把字节发到 Mac，Mac 端 `nc -l <port> > out.wav`；发完 `isComplete` 发 EOF，nc 收完落盘退出。
- **端口冲突**：macOS 7000 被 ControlCenter/AirPlay 占用，换 7700 等。

### 转录排错

- 文本是乱码 → ATV 系统语言与片源语音语言不一致（看 `locale=` 行）。
- `当前语言不被支持` → 换支持的系统语言。
- 长时间无输出 → 在下模型 / 没联网。

---

## 八、优化 / 修复项（实验捷径 → 产品化）

### A. libmpv 补丁侧

1. **公开头打包**：把 `iovis_tap.h` 纳入 MPVKit 打包公开头（放进 `include/mpv/` 或独立 modulemap），消费方直接用，**消除手抄桥接的内存风险**。落点：`LibMpvBuilder.headerRoot` / 打包逻辑。
2. **meson 开关**：加 `-Diovis_tap`（默认 auto / Apple 平台 enabled），`LibMpvBuilder.appleOptions` 追加；便于关闭与合规审计。
3. **planar 全平面**：chunk 增加 `num_planes` 与 `data[1..]`（或在 tap 内下混 mono），不要只给左声道。
4. **格式通用化**：chunk 已带 `format`（AF_FORMAT_*），但消费侧目前假设 float。要么 tap 内统一转 float，要么消费侧按 `format` 分支（s16/floatp/float…）。实测当前流是 `floatp`。
5. **时间戳口径**：`pts_us` 现为「到扬声器延迟」（实测起点约 +1.25s 设备缓冲）。字幕同步要的是流时间/`time-pos`。方案：chunk 同时带「设备延迟」和「流内 PTS」，或在补丁里用 `ao` 的播放位置换算；需实测对齐误差。
6. **多实例**：回调是全进程单例。PiP/多 player 要在 chunk 加 `void *opaque`（用 mpv `user-data` 注入）区分实例。
7. **GPL/LGPL**：tap 仅用 ao 内部 + msg，保持 LGPL 兼容，勿引入 GPL-only 符号。

### B. IovisKit 消费侧

1. **采样率写死 bug**：`IovisLiveTranscriber` 源格式写死 `44100`，应从 `chunk.samplerate` 动态建 `sourceFormat`（不同流可能 48000）。**必修**。
2. **音频线程上做重活**：当前在 mpv 音频线程里每个 chunk（~23ms）`AVAudioPCMBuffer` 分配 + 转码 + yield。产品化应：回调内只 memcpy 进**无锁 ring buffer**，转码/喂分析器放到独立 consumer task；复用 buffer，避免每次分配。
3. **背压**：`AsyncStream` 默认无界缓冲。识别跟不上会堆积内存。用 bounded buffering / drop-oldest 策略。
4. **生命周期**：转录的 start/stop 绑定 player 生命周期；停止时 `finalizeAndFinishThroughEndOfInput()`；`deinit` 注销回调（`iovis_tap_set_callback(nil, nil)`）。
5. **track 切换 / seek**：mpv `reset` 时要 flush converter，必要时重启 analyzer；seek 后用 `bufferStartTime` 标记不连续。
6. **locale 策略**：用片源音轨语言（`track-list` 元数据）而非设备语言；允许用户选。注意 `Locale.current` 受 App `CFBundleLocalizations` 限制会回落英文，要用 `Locale.preferredLanguages` 或片源语言。
6b. **AssetInventory 配额管理**：每 App 最多保留 `maximumReservedLocales` 个 locale（实测 tvOS 为 **1**）且跨启动持久。切换语言前必须 `AssetInventory.release(reservedLocale:)` 释放旧 locale，否则 `assetInstallationRequest` 报 `SFSpeechErrorDomain Code=11 "Too many allocated locales"`。生产里要管理保留/释放生命周期。`supportedLocales` 实测含 `zh_CN/zh_TW/zh_HK/yue_CN` 等。
7. **mono/下混**：当前只取左声道；按需下混双声道提升识别。
8. **错误/资产 UX**：模型下载进度、失败重试、离线提示。

---

## 九、风险与待决问题

- **时间戳对齐**：见 八.A.5，是字幕能否准的核心，需真机实测延迟并校准。
- **planar/格式**：见 八.A.3/4，目前只左声道 + 假设 float。
- **多实例**：见 八.A.6。
- **音频线程负载/背压**：见 八.B.2/3，长时间播放下的内存与卡顿风险。
- **资产体积/首启延迟**：语音模型首次下载，需联网与等待；离线不可用。
- **语言覆盖**：`SpeechTranscriber.supportedLocale` 不支持的语言无法转录。
- **rebase 上游**：补丁只碰 `buffer.c` 一行 + 两个新文件，rebase 成本低；但 `ao_read_data` 签名若上游变动需跟进。

---

## 十、产品化落地计划

### 公开 API 形态（前置文档 4.4 的契约，落地目标）

```swift
public protocol IovisPlayerPCMSource: AnyObject {
    func setHandler(_ handler: ((IovisPCMChunk) -> Void)?)
}
public struct IovisPCMChunk {
    public let data: UnsafeBufferPointer<UInt8>
    public let frames: Int
    public let channels: Int
    public let samplerate: Int
    public let format: IovisPCMFormat
    public let ptsMicroseconds: Int64
}
```

- `IovisPlayer` 暴露 `var pcmSource: IovisPlayerPCMSource? { get }`，仅编译开关 `IOVIS_AUDIO_TAP` 打开时非空。
- 运行时默认 off；Live Captioning 启动时才注册 tap 回调。

### MVVM-C 落点（IovisKit）

- **Service**：`IovisPCMTapSource`（包装 `iovis_tap_set_callback` + ring buffer，实现 `IovisPlayerPCMSource`）；`LiveCaptioningService`（持 `SpeechAnalyzer`/`SpeechTranscriber`，消费 PCM 出文本）。副作用全收口在此层。
- **ViewModel**：字幕状态、开关意图、文本流映射。
- **Component**：字幕渲染视图（tvOS）。
- **Coordinator**：在播放页装配上述，控制开启/关闭。
- PCM tap、转码、模型下载等 side effect **不进** View/ViewModel。

### 里程碑

1. **补丁产品化**：八.A 全部落地，fork MPVKit + CI 出包 + pin tag（前置文档 4.2/4.6）。
2. **PCM 通路**：八.B.1~4，落 `IovisPlayerPCMSource` 公开协议 + ring buffer + 生命周期。
3. **转录 Service**：locale 策略、背压、track/seek 处理、错误 UX。
4. **字幕 Feature**：MVVM-C 切分、渲染、UI/UX（独立 Feature 设计文档）。

---

## 十一、回滚与开关

### libmpv 补丁

- 删 `Sources/MPVKitBuilder/Resources/Patch/libmpv/0001-add-iovis-pcm-tap.patch`，`make build only=libmpv force=libmpv` 回原版。
- 或删 `build/libmpv-source-v0.41.0` 重新 clone 干净源码。

### IovisKit 实验改动

```bash
cd /Users/tinuv/Developer/Apple/Library/IovisKit
git checkout Package.swift Package.resolved \
  Sources/IovisPlayerCore/Player/IovisPlayer+Events.swift \
  Sources/IovisPlayerCore/Player/IovisPlayer+MPV.swift
rm -rf Sources/IovisTapBridge \
  Sources/IovisPlayerCore/Player/IovisPCMTapRecorder.swift \
  Sources/IovisPlayerCore/Player/IovisLiveTranscriber.swift
# Xcode 再 Reset Package Caches 切回远端 MPVKit
```

### 消费者切换

tap 回调单槽，在 `configureCallbacks` 改一行即可在「转录 / WAV dump / 关闭」之间切：
`IovisLiveTranscriber.shared.enable()` ↔ `IovisPCMTapRecorder.shared.enable()` ↔ 都不调。

---

## 十二、关键文件清单

### MPVKitBuilder（补丁仓库）

- `Sources/MPVKitBuilder/Resources/Patch/libmpv/0001-add-iovis-pcm-tap.patch` — 补丁本体。
- `Sources/MPVKitBuilder/LibBuilders/LibMpvBuilder.swift` — meson 参数（产品化加 `-Diovis_tap` / 公开头）。
- `Sources/MPVKitBuilder/Builders/Builder.swift:50,280,93` — patch 应用 / 幂等 / force 重编。
- mpv 源码侧（补丁内容）：`audio/out/iovis_tap.{h,c}`、`audio/out/buffer.c`、`meson.build`。

### IovisKit（消费仓库 · 实验改动）

- `Package.swift` — 依赖指向本地 MPVKit + `IovisTapBridge` target。
- `Sources/IovisTapBridge/include/IovisTapBridge.h`、`shim.c` — C 桥接。
- `Sources/IovisPlayerCore/Player/IovisLiveTranscriber.swift` — PCM → SpeechTranscriber → 文本。
- `Sources/IovisPlayerCore/Player/IovisPCMTapRecorder.swift` — PCM → WAV + TCP 推回（验证用）。
- `Sources/IovisPlayerCore/Player/IovisPlayer+MPV.swift` `configureCallbacks` — 注册点。
- `Sources/IovisPlayerCore/Player/IovisPlayer+Events.swift` `handleLogMessage` — M3 节流日志打印。

### 实测结论（真机 tvOS，2026-05-29）

- 上游交付：`fmt=floatp`(planar float)、`rate=44100`、`ch=2`、每次 `write` 1024 帧。
- pts 校验：相邻节流日志 `Δpts_us` 恒为 `1021678`，正好 `44×1024/44100 s`，与墙钟吻合 → 时间戳跟真实音频时钟、**无丢帧**。
- `pts_us` 起点约 `+1.25s`（设备缓冲延迟，印证八.A.5）。
- WAV 可听 = PCM 字节真实可用；`SpeechTranscriber` 实时出 `[volatile]/[final]` 文本 = 转录链路打通。
