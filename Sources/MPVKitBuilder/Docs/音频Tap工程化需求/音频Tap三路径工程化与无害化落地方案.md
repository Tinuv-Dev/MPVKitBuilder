# 音频 Tap 三路径 · 工程化与无害化落地方案

> 状态：**已工程化（含二期订正）**。本文最初是「事实梳理 + 工程化准备」的历史基线，其后两条补丁已完成工程化/无害化落地，二期又做了一轮 review 订正（链接安全、时间戳语义、segmented codec、wrapped avframe、原子配对、生命周期契约）。
>
> 阅读须知：第六节「现状事实」各 bullet 已就地更新为**当前补丁事实**；凡描述「无条件入口调用 / 无回调节流日志 / pts_us 为延迟 / 全进程双 atomic 单槽」等的旧表述属历史基线，已订正。决策类章节（第四~七节的处置依据、对照表）仍然有效，未改。
>
> 配套既有文档：
> - `Docs/IovisPCMTapPatch.md` —— realtime-pcm-tap 的全链路设计与 tvOS 真机实测（PoC 权威记录）。
> - `Docs/提前转录需求/提前转录-字幕策略.md` —— ahead 路径拿到文本之后的字幕策略。
> - `Docs/提前转录需求/提前转录-spec-tasks.json` —— 提前转录任务编排。
>
> 补丁本体：
> - `Resources/Patch/libmpv/0001-add-iovis-pcm-tap.patch`
> - `Resources/Patch/libmpv/0002-add-iovis-lookahead.patch`
>
> 构建分支：`exp/ao-iovis-tap`。补丁经 `Builder.preCompile()` 用 `git apply` 幂等应用到 libmpv 源码树。

---

## 一、为什么要做这件事

两条 PoC 补丁已在 tvOS 真机验证「能拿到 PCM / 压缩包并喂转录」。但 PoC 形态有几个共性问题，直接进生产会出事：

- 未启用时仍有可观察影响（节流日志、无条件入口调用）。
- 启用时把重活压在 mpv 的关键线程上（音频拉取线程 / demux 锁内）。
- 全进程单槽回调，多实例（PiP / 多 player）会串台。
- 头文件没进 xcframework 公开头，消费侧靠**手抄声明**对齐 ABI，布局一漂移就静默读错内存。
- 切流 / seek / 退出的生命周期没有收敛。

本轮把 PoC 的三条逻辑路径**定型并命名**，对其中两条做工程化、一条做无害化冻结，让能力边界与维护责任清晰可控。

---

## 二、三条路径定型（权威对照表）

PoC 阶段两条补丁里其实藏了**三条逻辑路径**。0002 一个补丁内含两条（Path D / Path A），共用同一编译单元与同一入口函数 —— 这是后续拆分与无害化的关键事实。

| 工程代号 | 来源 | 代码实体 | 挂载点 | 数据形态 | 回调线程 | 本轮处置 |
|---|---|---|---|---|---|---|
| **realtime-pcm-tap** | 0001 | `iovis_tap.{h,c}` · `iovis_tap_set_callback` / `iovis_tap_feed` | `audio/out/buffer.c` 的 `ao_read_data()` 解锁之后 | 成品 PCM（贴播放头、含设备缓冲延迟） | mpv 音频拉取线程，**不持 ao 锁** | **工程化** |
| **ahead-package-tap** | 0002 · Path D | `iovis_lookahead.{h,c}` · `iovis_lookahead_set_callback` / `feed_packet_path` | `demux/demux.c` 的 `add_packet_locked()` | 压缩音频包 + `AVCodecParameters`（超前播放头，消费侧自行解码） | demux 线程，**持 demux 锁** | **工程化** |
| **ahead-pcm-tap** | 0002 · Path A | `iovis_lookahead.{h,c}` · `iovis_lookahead_set_pcm_callback` / `pcm_worker` / `feed_pcm_path` | `add_packet_locked()` → 拷包入队 → worker 解码 | PCM（mpv 内 libavcodec 解码出，超前播放头） | 专用 worker 线程 | **无害化** |

三条路径互斥与组合关系：
- realtime 与 ahead 系来自不同补丁、不同挂载点，互不依赖，可独立启停。
- ahead-package-tap 与 ahead-pcm-tap **共用 `iovis_lookahead_feed()` 入口**：该入口对每个选中音频包先调 `feed_packet_path()` 再调 `feed_pcm_path()`。两条路径由「注册了哪个 setter」在运行时各自决定是否生效，可同时注册、可只注册其一。

---

## 三、命名与术语约定

- **路径代号**统一用本文三个名字：`realtime-pcm-tap`、`ahead-package-tap`、`ahead-pcm-tap`。任务、提交信息、文档、Swift 侧类型沟通一律采用，避免再用「Path A / Path D / lookahead / tap」等易混说法。
- **代号 ↔ 现有 C 符号映射以第二节表格为准**。本轮**不要求**立即重命名 C 符号或拆分文件（属工程化准备里的待决项，见第七节），先用代号建立共识。
- 「工程化」「无害化」定义见第四、第六节。

---

## 四、什么叫「工程化」「无害化」（验收口径）

### 工程化（realtime-pcm-tap、ahead-package-tap）

| 维度 | 量化标准 |
|---|---|
| 未启用零影响 | 没注册回调时，入口路径只剩一次 `atomic_load` 比较即早退；**无日志、无累加、无分配**。 |
| 启用不拖垮关键线程 | mpv 侧回调只做「构造轻量 struct + 一次间接调用」，不分配、不阻塞、不重入 mpv；重活（解码/转码/识别）由消费侧异步承接。契约写进公开头并由消费侧 ring buffer 落实。 |
| 生命周期清晰 | 注册 / 注销对称；注销后无悬挂线程、无残留资源；可重复 enable/disable。 |
| 外部不易误用 | 头文件进 xcframework 公开头，消费侧 `import` 直接用、不手抄；字段语义、线程契约、生命周期在头注释中明确。 |
| 多实例 / 切流 / 退出可控 | 能区分多个 player 实例；切音轨 / seek 时字段变化可被消费侧感知并重锚；退出 teardown 干净。 |

### 无害化（ahead-pcm-tap）

- **保留路径与回调接口**，未注册回调时严格 **no-op**（现状已满足：`g_pcm_active=false` 时 `feed_pcm_path()` 第一行早退）。
- **不增加功能**：planar 全平面、切轨解码器刷新、背压通知、多实例等一律**不做**，这些能力由 ahead-package-tap 承担。
- **只修潜在 bug**：见第六节 bug 清单，按「不扩面、不改契约」原则修复。
- 冻结但不删除：作为 ahead-package-tap 的对照 / 兜底实现保留。

---

## 五、路径分配决策依据（为什么 ahead-pcm-tap 被无害化）

超前转录（lookahead）这条业务线，工程投入压在 **ahead-package-tap（Path D）**，**ahead-pcm-tap（Path A）冻结**，依据如下：

| 对比项 | ahead-package-tap（选为工程化主线） | ahead-pcm-tap（无害化冻结） |
|---|---|---|
| mpv 侧职责 | 只搬运 demux 已有的压缩包指针 | 在 mpv 内再养一套 libavcodec 解码器 |
| 线程 | 无新线程 | 专用 worker 线程 + 条件变量 + 队列 |
| 全局可变状态 | 仅两个 atomic 回调槽 | mutex/cond/thread/队列/`g_par`/解码器 ctx，一大坨 |
| 与 mpv 内部耦合 | 低（包指针 + codecpar） | 高（重复解码、与 mpv 自身解码器并存） |
| 切轨 / seek | 消费侧重建解码器即可，mpv 侧无状态 | 解码器 ctx 只认首个 `g_par`，切轨后解码错误（见 bug 清单） |
| rebase 上游成本 | 低 | 高 |
| 解码职责归属 | 落在消费侧，与其管理 `SpeechAnalyzer` 资产/格式同层、更内聚 | 落在 mpv 内，与上层格式需求割裂 |
| 主要代价 | 回调持 **demux 锁**，对消费侧契约要求最严 | 看似省了消费侧解码，实则把复杂度沉到难维护的位置 |

结论：ahead-package-tap 让 mpv 侧保持「零解码、零线程、零队列」，把可变复杂度交给本就要管转录管线的消费侧，是更可维护的边界。ahead-pcm-tap 的复杂度无法用「省一次解码」抵消，故冻结。

---

## 六、逐路径事实梳理与任务边界

### 6.1 realtime-pcm-tap（工程化）

**现状事实**（`0001-add-iovis-pcm-tap.patch`，已工程化 + 二期订正）
- `ao_read_data()` 解锁后调用 `iovis_tap_feed(ao, data, pos, out_time_ns, stream_pts)`，**调用点与 include 用 `#ifdef HAVE_IOVIS_TAP` 条件编译**（meson `-Diovis_tap=enabled` 时注入该宏）；disabled 时调用点与符号一并消失，stock build 链接干净。`stream_pts` 形参始终编译，disabled 分支 `(void)stream_pts` 消警告。
- `iovis_tap_feed`：`atomic_load(&g_reg)` 拿到**原子配对**的 `{cb,user}`（见下「原子配对」），有回调则构造 `iovis_tap_chunk`（`data/samples/channels/samplerate/format(AF_FORMAT_*)/num_planes/planes/pts_us/pts_stream/opaque`）并在音频拉取线程同步调用；**无回调即一次 atomic load 早退，无日志/累加/分配**。可选诊断日志仅在 `-Diovis_tap_log=enabled` 编入（生产默认关）。
- chunk 暴露全平面（`num_planes` + `planes[]`），由消费侧下混/重采样；含 `opaque` 实例令牌支持多 player 区分。实测上游为 `floatp / 44100 / 2ch / 每次 1024 帧`。
- `pts_us = out_time_ns/1000`，语义是 **mpv 单调钟域（`mp_time_ns()`）中本 chunk 最后一个请求样本预计可听见的绝对时刻**，**既非延迟也非流时间戳**；要取设备延迟须自行减去 `mp_time_us()`（当前时刻）。边界提示：`pts_stream` 是本 chunk **首个真实样本**的流内 PTS（同 `time-pos` 钟域，供字幕对齐，未知为 `MP_NOPTS_VALUE`），`pts_us` 是**最后请求样本**，两者边界不一致。
- **原子配对 + 生命周期**：`{cb,user}` 打包成不可变 `iovis_tap_reg` 由单个 `_Atomic` 指针原子发布/替换，feed 端一次 load 拿到自洽配对，杜绝「旧 cb 配 NULL/错 user」撕裂；旧 reg 故意不 free（每次切换泄漏约 16 字节，规避热路径无锁下的 UAF）。无 join 屏障：`set_callback(NULL)` 返回后仍可能有**最多一次配对自洽**的旧回调在跑，消费侧释放 user 资源前须自行确保无 in-flight（契约写进公开头）。

**工程化任务**
1. 去掉无回调时的节流日志分支，未启用时只留一次 `atomic_load` 早退（满足「零影响」）。可保留一个 `-Diovis_tap` 默认 disabled 的诊断日志开关供排障，但生产默认关。
2. chunk 增 `void *opaque` 实例标识（经 mpv `user-data` 注入），支撑多实例区分。
3. planar 处理：要么 chunk 增 `num_planes` + 多平面指针，要么在 tap 内下混 mono；不再「只给左声道还假装是全部」。
4. 时间戳口径：同时给「设备延迟」与「流内 PTS / time-pos」，供字幕对齐；需真机实测校准（沿用 IovisPCMTapPatch.md 八.A.5）。
5. 公开头 + meson 开关 + 符号验证（见第七节共性项）。

**本路径不做**：在 mpv 侧做转码 / 重采样 / 识别（属消费侧）。

> realtime-pcm-tap 的全链路接入、Swift 桥接、SpeechTranscriber 用法、真机排错已在 `IovisPCMTapPatch.md` 完整记录，本文不重复，仅补「定型 + 工程化边界」。

### 6.2 ahead-package-tap（工程化）

**现状事实**（`0002-add-iovis-lookahead.patch` · Path D，已工程化 + 二期订正）
- `add_packet_locked()` 中，对 `ds->type == STREAM_AUDIO` 的包调用 `iovis_lookahead_feed()`，**调用点与 include 用 `#ifdef HAVE_IOVIS_LOOKAHEAD` 条件编译**（meson `-Diovis_lookahead=enabled` 注入）；disabled 时调用点与符号一并消失，stock build 链接干净。
- 共享入口 `iovis_lookahead_feed()`（在 `iovis_lookahead.c`）先 guard 后分发到两条独立编译单元。**guard 已增 `dp->is_wrapped_avframe` 早退**（`!sh || !dp || dp->is_cached || dp->is_wrapped_avframe || !dp->buffer || dp->len==0`），与 mpv disk-cache 排除口径一致，避免把 wrapped AVFrame 指针当压缩包吐出/送解码。
- `iovis_ahead_package_feed`（Path D，`iovis_ahead_package.c`）：`atomic_load(&g_pkt_reg)` 拿到**原子配对** `{cb,user}`，无回调早退；有则构造 `iovis_la_packet`（`data`=压缩字节、`size`、`pts/dts`、`keyframe`、`codecpar`、`samplerate/channels`、`opaque`=`demuxer->global`）并调用。**codec 取值已修正为 `dp->segmented && dp->codec ? dp->codec : sh->codec`**，正确处理 ordered chapters / EDL 的 packet-specific codec。
- 回调在 **demux 线程、持 demux 锁**时运行；契约：必须 cheap、不阻塞、不重入 mpv。
- **原子配对 + 生命周期**：与 realtime 同构（`iovis_la_reg` 单 `_Atomic` 指针原子替换、旧 reg 不 free、无 join 屏障，`set_callback(NULL)` 后最多一次配对自洽旧回调）；契约写进公开头。
- `codecpar` 生命周期 = track 生命周期，消费侧若 retain 必须 copy。

**工程化任务**
1. 强化「持锁回调」契约：公开头明确「禁止在回调内阻塞 / 调任何 mpv API」；消费侧标准实现 = 锁内只 `memcpy` 压缩字节 + 拷 codecpar 摘要进无锁队列，立即返回，解码在队列另一端异步做。
2. 多实例 `opaque`：packet 增实例标识，区分多个 demuxer / player。
3. 切轨：消费侧检测 `codecpar` 变化重建解码器；mpv 侧无状态，无需改动，文档明确。
4. 未启用零影响：`feed_packet_path` 已是单 `atomic_load` 早退，达标；确认与 ahead-pcm-tap 拆分后入口仍只剩必要的 atomic 检查（见 6.3 与第七节拆分项）。
5. 公开头 + meson 开关 + 符号验证（第七节）。

**本路径不做**：在 mpv 侧解码（解码是消费侧职责，正是与 ahead-pcm-tap 的根本分界）。

### 6.3 ahead-pcm-tap（无害化）

**现状事实**（`0002-add-iovis-lookahead.patch` · Path A）
- `feed_pcm_path()`：`atomic_load(&g_pcm_active)` 早退（no-op 保证）；否则加锁，`g_run` 为假或队列满（`IOVIS_LA_QUEUE_CAP=1024`）则丢弃新包；首包用 `avcodec_parameters_copy` 捕获 `g_par`；`malloc` 节点 + `av_malloc` 数据 + `memcpy` + `AV_INPUT_BUFFER_PADDING_SIZE` 补零；入队 + `mp_cond_signal`。
- `pcm_worker()`：取队首；首次 `avcodec_find_decoder/alloc_context3/parameters_to_context/open2` 建解码器 ctx；`send_packet` + `receive_frame` 循环出 PCM，构造 `iovis_la_pcm`（plane0、`samples/channels/samplerate/format(AVSampleFormat)/pts`）在 worker 线程调 cb；释放节点。
- `iovis_lookahead_set_pcm_callback(cb,user)`：cb 非空时惰性 init mutex/cond（`g_started`）、置 `g_run`、按需建线程、`g_pcm_active=true`；cb 为空时 `g_pcm_active=false` → 加锁置 `g_run=false`、清回调、`broadcast` → `join` 线程 → `free_queue_locked` + `avcodec_parameters_free(&g_par)`。

**潜在 bug / 风险清单（#1~#4、#7 已按「不扩面」修复；#5/#6 明确不做）**

| # | 现象 | 严重度 | 处置（不增功能） |
|---|---|---|---|
| 1 | 解码器 ctx 创建后只认**首个** `g_par`，切音轨（codec 变化）后继续用旧解码器 → 解码错误 / 静默无输出 | 高 | **已修**：`g_par_gen` 代际变化时重建 ctx（仍限 PCM 输出，不扩接口） |
| 2 | `g_par` 在 feed 里 `if(!g_par)` 仅捕获一次，换轨不刷新 | 高 | **已修**：feed 比对 `codec_id/sample_rate/channels` 变化则刷新 `g_par` 并 `g_par_gen++` |
| 3 | 解码器 `open2` 失败后 ctx 仍 NULL，之后**每个包**都重试 `find_decoder/alloc`（无退避）→ 持续开销 | 中 | **已修**：失败也标记 `built_gen`，同一轨不再重试 |
| 4 | 队列满（>1024）静默丢新包，转录漏音频段，无任何信号 | 中 | **已修**：`g_drop_count` 计数，首次及每满 CAP 一条 `MP_WARN`（不改 no-op、不扩公开接口） |
| 5 | planar 仅取 `frame->data[0]`，多声道只剩 plane0 | 低（无害化下接受） | 不做（属功能增量，归 package 路径） |
| 6 | `g_started` / mutex 一旦 init 进程内不销毁 | 低 | 可接受（进程级单例语义），仅记录 |
| 7 | segmented（ordered chapters / EDL）包用 `sh->codec` 而非 packet-specific `dp->codec` | 中 | **已修（二期）**：`dp->segmented && dp->codec ? dp->codec : sh->codec`，与 package 路径同口径 |

> 复核结论：disable 路径 `broadcast → join → free_queue → free(g_par)` 时序正确，worker 退出后再清队列，**无 use-after-free / double-free**；`g_pcm_active` 先于 `g_run` 翻假保证 feed 快速早退。这些是现状已正确的点，无害化时勿动。

**无害化边界**
- 接口、字段、线程模型、队列容量**维持不变**。
- 只修 #1~#4、#7 的正确性问题；#5/#6 明确不做。
- 未注册回调时严格 no-op（现状达标，回归测试守住）。

---

## 七、跨路径共性工程化（准备项）

以下为三条路径（无害化路径按需）共同涉及、需要在工程化阶段统一处理的事项。本轮只列清单与落点，不实施。

### 7.1 公开头打包（消除手抄 ABI 风险）
- 现状：`iovis_tap.h`、`iovis_lookahead.h` 在 mpv 源码 `audio/out/`、`demux/`，**未**进 xcframework 公开头；消费侧（IovisKit `IovisTapBridge`）手抄声明，布局漂移会静默读错内存。
- 落点：`LibMpvBuilder.headerRoot()`（现指向 `include/mpv`）/ XCFramework 打包逻辑，把两个头随产物装出来或独立 modulemap。
- 验收：消费侧 `import Libmpv` 直接拿到 `iovis_*` 声明，删除手抄桥接。

### 7.2 meson 编译开关（已落地 + 二期加固）
- 现状：`meson.options` 增 `iovis_tap` / `iovis_tap_log` / `iovis_lookahead` 三个 feature（默认 disabled）；`meson.build` 用 `get_option(...).allowed()` gate 对应 `.c` 进 sources。`LibMpvBuilder.iovisTapOptions()` 对 Apple 平台统一 `-Diovis_tap=enabled` / `-Diovis_lookahead=enabled`。
- **二期加固（链接安全）**：enabled 时同时 `add_project_arguments('-DHAVE_IOVIS_TAP' / '-DHAVE_IOVIS_LOOKAHEAD')`，`buffer.c` / `demux.c` 的**调用点与 include 用该宏条件编译**。此前调用点无条件存在、而 `.c` 仅 enabled 才编入 → disabled 构建会留下未定义引用（链接失败）；加宏后 disabled 时调用点与符号一并消失，stock build 链接干净，符号也不入产物。

### 7.3 符号导出验证
- 静态库 `.a` 默认保留符号，但需防 LTO / dead-strip 误删。出包后校验：
  ```bash
  nm dist/Libmpv.xcframework/<slice>/Libmpv.framework/Libmpv | grep -E 'iovis_tap|iovis_lookahead'
  # 期望：T _iovis_tap_set_callback / T _iovis_lookahead_set_callback / T _iovis_lookahead_set_pcm_callback
  ```

### 7.4 多实例 opaque
- 三条路径回调均为**全进程单槽**，chunk/packet 无实例标识。PiP / 多 player 会串台。
- 工程化路径（realtime、package）在数据结构里加 `void *opaque`，由 mpv `user-data` 注入；ahead-pcm-tap 不做（无害化）。

### 7.5 ahead 两路径的文件 / 符号拆分（待决，推荐执行）
- 现状：ahead-package-tap 与 ahead-pcm-tap 同处 `iovis_lookahead.{h,c}`、共用 `iovis_lookahead_feed()` 入口。
- 风险：无害化冻结 pcm 路径、同时工程化 package 路径时，**改一个易误伤另一个**。
- 推荐：工程化阶段把两条路径拆到独立编译单元（package 路径继续演进、pcm 路径冻结文件），`iovis_lookahead_feed()` 内对两条路径的调用各自用独立 active 标志短路。是否同步把 C 符号改成与代号一致（如 `iovis_ahead_package_*` / `iovis_ahead_pcm_*`）一并在该阶段决策。
- 本轮：仅建立代号映射（第二节），不动文件。

### 7.6 LGPL 合规
- realtime-pcm-tap / ahead-package-tap 仅用 mpv 内部 + msg，不引 GPL-only 符号，保持 LGPL 兼容。
- ahead-pcm-tap 用 libavcodec（已是 mpv 既有依赖，LGPL 范围内），无害化不扩大依赖面。

---

## 八、验证策略（工程化阶段执行，本轮仅定义）

> 遵循默认验证策略：优先单平台快速迭代，不默认全量构建。

**单平台快速迭代**
```bash
make build only=libmpv force=libmpv platform=macos          # 最快验逻辑
make build only=libmpv force=libmpv platform=tvossimulator  # tvOS 模拟器
```
`force=libmpv` 必带，否则 `builtLibrariesExist` 跳过已有 `.a`（`Builder.swift:93`）。

**补丁可干净应用**
```bash
cd build/libmpv-source-v0.41.0 && git checkout -- .
git apply --check ../../Sources/MPVKitBuilder/Resources/Patch/libmpv/0001-add-iovis-pcm-tap.patch && echo OK
git apply --check ../../Sources/MPVKitBuilder/Resources/Patch/libmpv/0002-add-iovis-lookahead.patch && echo OK
```

**关键验收点**
- 未启用零影响：不注册任何回调跑一段播放，确认无 `iovis` 相关日志、CPU 无可测增量。
- realtime 启用：`nm` 见符号 + 消费侧收到 chunk + 实测 `Δpts_us` 与墙钟吻合（IovisPCMTapPatch.md 已建立基线 `1021678`）。
- ahead-package 启用：消费侧在锁外异步解码出 PCM，demux 无卡顿（观察缓冲水位）。
- ahead-pcm 无害化回归：注册 pcm 回调能出 PCM；切音轨后验证 #1 修复；不注册时 no-op。

---

## 九、风险与回滚

- **持锁回调（ahead-package-tap）**：消费侧任何阻塞都会卡 demuxer → 缓冲耗尽。最高优先级契约，靠公开头强约束 + 消费侧 ring buffer 兜底。
- **时间戳对齐**：realtime 的 `pts_us` 是 **mpv 单调钟域中最后请求样本的绝对可听见时刻**（既非延迟也非流时间戳，要延迟须减 `mp_time_us()`）；流内对齐用 `pts_stream`（首个真实样本，同 `time-pos`）。ahead 的 pts 是 mpv 秒可能 `MP_NOPTS_VALUE`。字幕对齐需重锚机制（见字幕策略文档 2.1）。
- **回调生命周期（无 join 屏障）**：realtime / ahead-package 的 `{cb,user}` 原子配对替换，杜绝撕裂，但 `set_callback(NULL)` 返回后仍可能有最多一次配对自洽的旧回调在跑（这两条挂在 mpv 自有线程、无可 join 的 worker）。消费侧释放 user 资源前须自行确保无 in-flight（契约已写公开头）。ahead-pcm 因有 `mp_thread_join` 本就有真正屏障。
- **rebase 上游**：realtime 仅碰 `buffer.c`（含 `#ifdef` 调用点）+ 两新文件；ahead 仅碰 `demux.c`（含 `#ifdef` 调用点）+ 五新文件。成本低，但 `ao_read_data` / `add_packet_locked` 签名、`demux_packet` 的 `segmented/codec/is_wrapped_avframe` 字段若上游变动需跟进。
- **回滚**：删对应 `.patch` 后 `make build only=libmpv force=libmpv` 回原版；或删 `build/libmpv-source-v0.41.0` 重 clone。

---

## 十、任务边界小结（待拆 task，本文不拆）

| 路径 | 处置 | 必做 | 明确不做 |
|---|---|---|---|
| realtime-pcm-tap | 工程化（已落地） | 去 PoC 日志 / opaque / planar / 时间戳口径 / 公开头 / meson 开关 / **二期：`#ifdef` 链接安全 + pts_us 注释订正 + 原子配对** | mpv 侧转码识别 |
| ahead-package-tap | 工程化（已落地） | 持锁契约 / opaque / 切轨文档 / 公开头 / meson 开关 / 与 pcm 路径拆分 / **二期：`#ifdef` 链接安全 + segmented codec + wrapped avframe guard + 原子配对** | mpv 侧解码 |
| ahead-pcm-tap | 无害化（已落地） | 修 bug #1~#4、#7（segmented codec）/ 守住 no-op | planar(#5) / 多实例 / 背压增强 / 改接口 |
| 共性 | 工程化（已落地） | 公开头打包 / meson 开关 / 符号验证 / opaque / LGPL 复核 / ahead 拆分 | — |

> 本文最初为事实梳理与工程化准备；其后两条补丁已完成工程化/无害化落地，二期 review 又订正了链接安全、时间戳语义、segmented codec、wrapped avframe、原子配对与生命周期契约。第六节「现状事实」与第七节落点已同步为**当前补丁事实**；C 符号重命名、ahead 两路径进一步拆分仍可按第五~七节推荐继续决策。
