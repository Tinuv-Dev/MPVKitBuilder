# iovis PCM Tap · libmpv 补丁设计与验证

> 状态：**实验阶段（M3 最小版本已落地）**。
> 分支：`exp/ao-iovis-tap`。补丁文件：`Sources/MPVKitBuilder/Resources/Patch/libmpv/0001-add-iovis-pcm-tap.patch`。
> 目标：从 mpv 解码链实时拿到与播放对齐的 PCM，且不影响扬声器输出、默认关闭。
> 对应上层需求文档：`IovisPlayertvOS/Docs/LiveCaptioning-CustomAO-Prerequisites.md`（Live Captioning 前置工作）。

---

## 一、要解决的问题

Apple TV 上要做实时语音转录字幕，识别端（`SpeechAnalyzer` / `SpeechTranscriber`）没有瓶颈，瓶颈是**怎么把 mpv 解码出来的 PCM 实时拿到手**。核实 libmpv `v0.41.0` 公开 API 后确认拿不到：

- `include/mpv/render.h` 的 render API 只覆盖视频（OpenGL / SW）。
- `include/mpv/client.h:1334` 在 `MPV_EVENT_AUDIO_RECONFIG` 处明确写着 *"there is no such thing as audio output embedding"*——没有任何音频输出回调。
- 现有 AO 全是终端 sink：`audiounit` / `coreaudio` 把 PCM 交给系统但不外露，`pcm` 写文件且独占 ao（开了没声音），`null` 静音，`lavc` 是编码模式。

**结论：单靠 meson 编译参数开不出这个能力，必须给 libmpv 打源码补丁。FFmpeg 不需要动**——抽取点在 mpv 的 AO 层（解码 + 音频滤镜之后的成品 PCM），完全在 mpv 内部；FFmpeg 只负责 demux/decode，拿不到与 `time-pos` 对齐的播放 PCM。

---

## 二、关键发现：tap 点为什么不是「tee AO」

上层前置文档最初设想的是一个 **push 型 tee AO**（`--ao=iovis_tap,audiounit`，在 `write()` 里把 PCM 转发给下级 AO）。核实源码后这个形态在 Apple 平台**不成立**：

- tvOS 的 `audiounit`、macOS 的 `coreaudio`、`avfoundation` **全是 pull 模型**：没有 `.write`，靠各自的渲染回调主动调 `ao_read_data(ao, …)` 拉数据。
  - `audio/out/ao_audiounit.m:100`
  - `audio/out/ao_coreaudio.c:98`
  - `audio/out/ao_avfoundation.m:80`
- mpv 的 `buffer_state`（见 `audio/out/buffer.c`）是「一个 ao 对应一份缓冲，由 core 单向喂」的模型。一个 AO 内部再 spawn 一个下级 pull AO、还要替它把数据泵进它自己的 `buffer_state`，需要深挖内部状态，复杂且脆弱，不适合做实验，也不利于将来 rebase 上游。

`ao_driver` 的 push / pull 两种契约见 `audio/out/internal.h:97-129`、`130-199`。

### 选定的 tap 点

三种 pull AO 都汇流到同一个函数：`audio/out/buffer.c:207` 的 `ao_read_data()`。它在持锁状态下把成品 PCM 填进调用方缓冲、返回真实样本数 `pos`，随后解锁。**在解锁之后挂一个只读钩子**就能拿到 PCM，且：

- 一处改动覆盖全部 Apple AO（audiounit / coreaudio / avfoundation）。
- 完全不碰 `--ao`，播放行为与改造前一致。
- 只读拷贝，不改 mpv 的数据流。
- 默认关闭：没注册回调就什么都不做（仅一个 NULL 判断 + 实验期的节流日志）。

> 与前置文档的偏差：放弃 `--ao=iovis_tap,audiounit` 的命名 AO 方案，改为 read-side tap；运行时开关由「是否注册回调」决定，而不是 `--ao` 参数。

---

## 三、补丁做了什么

补丁共 4 处改动（`git diff --stat`：4 files, +99）：

| 文件 | 类型 | 内容 |
|---|---|---|
| `audio/out/iovis_tap.h` | 新增 | 公开符号 `iovis_tap_set_callback` + `struct iovis_tap_chunk` + 内部入口 `iovis_tap_feed` 声明 |
| `audio/out/iovis_tap.c` | 新增 | tap 实现：注册了回调就喂 chunk；没注册就按约每秒打一行 `MP_INFO` 日志 |
| `audio/out/buffer.c` | 改 | `#include "iovis_tap.h"`；在 `ao_read_data` 解锁后插一行 `iovis_tap_feed(ao, data, pos, out_time_ns)` |
| `meson.build` | 改 | 把 `audio/out/iovis_tap.c` 加进 sources 列表 |

### chunk 契约（`iovis_tap.h`）

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

### 关键设计取舍

- **线程**：回调跑在 mpv 的 audio 拉取线程上，**禁止阻塞**——消费侧只能 memcpy 到自己的 ring buffer 然后异步消费。回调注册用 `atomic` 存取，避免与 audio 线程竞争。
- **样本数**：传给 tap 的 `pos` 是 `ao_read_data` 返回的**真实样本数**（静音补齐不计入），所以暂停时 `pos=0`，tap 自动跳过——转录在暂停时自然停止，符合预期。
- **时间戳**：暂用 `out_time_ns / 1000`，语义是「最后一个样本到达扬声器前的延迟」。**这是待校准项**（见第六节风险）。
- **平面**：第一版只暴露 `data[0]`（plane 0）。交错格式即整块；planar 格式只给第一个平面。多平面留待后续。
- **默认关闭**：没注册回调时只有一行节流日志，不改变任何播放行为。

### 与前置文档的两点刻意简化

- **没加 `-Diovis_tap` meson 选项**：直接无条件编入 sources（纯 C，只依赖 ao 内部 + msg，无平台依赖），运行时靠回调开关。产品化时再补 meson 开关即可。
- **没改 `LibMpvBuilder.swift`**：无条件编入就不需要追加 meson 参数。

---

## 四、补丁怎么被应用（构建机制）

builder 的 patch 流水线会自动处理，无需手动 `git apply`：

- `Builder.preCompile()`（`Sources/MPVKitBuilder/Builders/Builder.swift:50`）扫描 `Resources/Patch/<lib>/*.patch`，按文件名排序逐个应用。
- `applyPatchIfNeeded()`（同文件 `:280`）先 `git apply --check`，再 apply；已应用的（reverse-check 通过）直接跳过——**幂等**，重复构建不会重复打。
- 源码已存在时 `obtainSource()` 跳过 clone，patch 应用在现有源码树上。

新增补丁只要丢进 `Sources/MPVKitBuilder/Resources/Patch/libmpv/` 即可自动生效。

---

## 五、怎么编译与验证

### 5.1 单平台快速迭代

```bash
# macOS 最快，先验证逻辑
make build only=libmpv force=libmpv platform=macos
# 或 tvOS 模拟器
make build only=libmpv force=libmpv platform=tvossimulator
```

- `force=libmpv` **必须带**：否则已有 `.a` 会被 `builtLibrariesExist` 跳过不重编（`Builder.swift:93`）。它只清 libmpv 的构建产物（`cleanBuildProducts`），不动已编好的 ffmpeg 等依赖，也不动源码树（patch 保留）。
- `only=libmpv` 不会重编依赖，libmpv 依赖 ffmpeg 等已存在的产物即可。
- patch 加了新 source，meson 会重新 configure 并编译 `iovis_tap.c`。

平台名对照（`PlatformType.parse`）：`macos` / `ios` / `iossimulator` / `tvos` / `tvossimulator` / `maccatalyst` / `visionos` / `visionossimulator`。

### 5.2 M3 验收标准（tap 只打 log，不接 Swift）

1. **编译通过**，目标平台出 xcframework。
2. App 换上本地包后播放**行为与改造前完全一致**（VOD / Live / seek / 暂停 / 音轨切换），因为没动 `--ao`。
3. 把 mpv 日志级别开到 info 及以上，能看到节流日志：
   ```
   [iovis_tap] pcm flowing: <frames> frames, fmt=<fmt>, rate=<hz>, ch=<n>, pts_us=<...>
   ```
   - 看不到日志通常是 IovisPlayer 的 mpv log level 没到 info——调高，或直接进 M4 注册回调。
4. 暂停时日志停止刷新（`pos=0` 跳过），恢复后继续——确认暂停语义正确。

### 5.3 验证 patch 本身可干净应用

```bash
cd build/libmpv-source-v0.41.0
git stash -u 2>/dev/null; git checkout -- .   # 确保源码树干净
git apply --check Sources/.../0001-add-iovis-pcm-tap.patch && echo OK
```

---

## 六、风险与待决问题

- **时间戳口径**：当前 `pts_us = out_time_ns / 1000` 是「到扬声器的延迟」，不是 `time-pos`。要在 patch 阶段实测与字幕对齐的误差，必要时换口径。
- **多平面 / planar 格式**：第一版只给 `data[0]`。若上游交付 planar 格式且消费侧需要全部声道，要扩展 chunk。
- **多 mpv 实例**：回调是全进程单例，第一版只支持单 player。画中画 / 多窗要在 chunk 里加 `void *opaque` 区分实例。
- **GPL/LGPL**：tap 只用 ao 内部 + msg，不引入 GPL-only 符号，保持 LGPL 兼容。
- **公开头暴露（M4 前置）**：`iovis_tap_set_callback` 要从 Swift 调，需要把 `iovis_tap.h` 放进打包的公开头目录。M3 不需要，M4 再做。

---

## 七、回滚

- 删除 `Sources/MPVKitBuilder/Resources/Patch/libmpv/0001-add-iovis-pcm-tap.patch`，重新 `make build only=libmpv force=libmpv` 即回到原版 libmpv。
- 或 `obtainSource` 重新拉一份干净源码（删 `build/libmpv-source-v0.41.0`）。
- 对 mpv 的依赖始终可降级回上游。

---

## 八、下一步（M4：接通 Swift）

1. 把 `iovis_tap.h` 纳入打包公开头。
2. Swift 侧桥接 / `dlsym` 调 `iovis_tap_set_callback`，回调里只 memcpy 进 ring buffer。
3. 把 PCM dump 成 wav，与原片肉眼/波形对拍，验证内容与时间戳。
4. 通过后再进 Live Captioning Feature 的独立设计与实现（见前置文档 M5）。
