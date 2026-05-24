# MPVKitBuilder Dependency Graph Independent Verification

Generated graph under review: `.build/reports/dependency-graph.txt`

Scope:

- Verify dependency edges independently from upstream projects, official docs, and tagged build scripts.
- Do not use `Sources/MPVKitBuilder` as evidence for correctness.
- Distinguish hard upstream dependencies from optional feature dependencies and MPVKitBuilder policy choices.

Status legend:

- `[ ]` Not checked
- `[~]` In progress or partially checked
- `[x]` Checked
- `[!]` Mismatch, missing condition, or needs correction

## Evidence Rules

- Prefer tagged upstream build files matching the graph versions.
- Prefer official docs when tagged build files are unavailable or insufficient.
- Treat optional dependencies as correct only when the graph clearly represents an enabled feature set.
- Record platform/version caveats explicitly.

## Verification Checklist

### FFmpeg n8.1.1 Feature Dependencies

- [x] `ffmpeg -> openssl`
- [x] `ffmpeg -> libass`
- [x] `ffmpeg -> libsmbclient`
- [x] `ffmpeg -> vulkan`
- [x] `ffmpeg -> libshaderc`
- [x] `ffmpeg -> lcms2`
- [x] `ffmpeg -> libplacebo`
- [x] `ffmpeg -> libdav1d`
- [x] `ffmpeg -> libuavs3d`
- [x] `ffmpeg -> libbluray`
- [x] `ffmpeg -> libsrt`
- [x] `ffmpeg -> libzvbi`
- [x] Check whether `ffmpeg -> libdovi` is absent by design or a missing edge.

### mpv v0.41.0 Dependencies

- [x] `libmpv -> ffmpeg`
- [x] `libmpv -> libass`
- [x] `libmpv -> libplacebo`
- [x] `libmpv -> libuchardet`
- [x] `libmpv -> libluajit`
- [x] `libmpv -> libbluray`
- [!] Check whether `libmpv -> lcms2` is a missing edge or optional indirect feature.
- [!] Check whether `libmpv -> vulkan` is a missing direct edge or satisfied through libplacebo/FFmpeg.

### Supporting Library Dependencies

- [x] `libass -> libfreetype`
- [x] `libass -> libfribidi`
- [x] `libass -> libharfbuzz`
- [x] `libass -> libunibreak`
- [x] Check libass font provider dependency policy: CoreText/fontconfig/disabled.
- [x] `libharfbuzz -> libfreetype`
- [x] `libbluray -> libfreetype`
- [x] `libsrt -> openssl`
- [!] `libsmbclient -> openssl`
- [x] `libplacebo -> vulkan`
- [x] `libplacebo -> libshaderc`
- [x] `libplacebo -> lcms2`
- [!] Check whether `libplacebo -> libdovi` is absent by design or a missing optional edge.

### Standalone Libraries

- [x] `openssl -> -`
- [x] `libunibreak -> -`
- [x] `libfreetype -> -`
- [x] `libfribidi -> -`
- [x] `libuchardet -> -`
- [x] `libzvbi -> -`
- [x] `vulkan -> -`
- [x] `libshaderc -> -`
- [x] `lcms2 -> -`
- [x] `libdav1d -> -`
- [x] `libuavs3d -> -`
- [x] `libdovi -> -`
- [x] `libluajit -> -`

## Findings

## Overall Verdict

The generated dependency graph is partially correct, but it is not precise enough to be called a verified upstream dependency graph.

It is mostly valid as a project-level build-order graph for an enabled-feature policy, provided the graph explicitly documents that:

- Many edges are optional-feature edges, not upstream hard dependencies.
- System libraries, build tools, package-manager dependencies, Cargo dependencies, and vendored/internal third-party dependencies are out of scope.
- GPL and platform conditions are part of the dependency semantics.

Items that should be corrected or explicitly documented:

- `libsmbclient -> openssl` is likely wrong from upstream evidence. Samba points to GnuTLS for cryptography. Keep this edge only if a local patch or build policy truly wires Samba/libsmbclient to OpenSSL, and document that it is patch-specific.
- `ffmpeg -> libsmbclient` should be annotated as GPLv3/GPL-only.
- `libmpv -> lcms2` is a potential missing direct conditional edge if mpv's `lcms2` option is left as `auto` and lcms2 is visible through pkg-config.
- `libmpv -> vulkan` is a potential missing direct conditional edge if mpv's `vulkan` option is enabled/auto-detected.
- `libplacebo -> libdovi` is a potential missing conditional edge if libplacebo's `libdovi` option is enabled/auto-detected.
- `libass -> libunibreak`, `libplacebo -> vulkan/libshaderc/lcms2`, `libbluray -> libfreetype`, and `libsrt -> openssl` should be labeled as enabled-feature or policy edges.
- `libshaderc -> -`, `vulkan -> -`, and `libdovi -> -` are only true within this graph's top-level library scope; their internal third-party or package-manager dependencies are not represented.

Recommended next documentation update:

- Rename the graph description from a generic "Dependency Graph" to "Selected top-level build graph".
- Add a legend for hard edge, optional enabled-feature edge, GPL edge, system/out-of-scope dependency, and internal/vendor dependency.
- Add a short "Known omitted dependency classes" note for system frameworks, build tools, shaderc third-party DEPS, MoltenVK `fetchDependencies`, and Rust/Cargo crates.

### FFmpeg n8.1.1

- The FFmpeg edges in the graph are valid as enabled-feature dependencies, not as minimum FFmpeg build dependencies.
- `ffmpeg -> libsmbclient` is conditional on GPLv3 in FFmpeg configure, so the graph should make that condition visible on the FFmpeg edge, not only on the `libsmbclient` library row.
- `ffmpeg -> vulkan` is valid when Vulkan filters/hwaccels or the libplacebo filter path are enabled. FFmpeg also has a direct Vulkan feature check.
- `ffmpeg -> libshaderc` is valid when runtime GLSL-to-SPIR-V compilation or Vulkan filters requiring `spirv_library`/`spirv_compiler` are enabled.
- `ffmpeg -> libdovi` is correctly absent for FFmpeg n8.1.1 external library dependencies. FFmpeg's configure references internal `dovi_rpudec` selection for `libdav1d`, not an external `libdovi` package edge.

### mpv v0.41.0

- `libmpv -> ffmpeg` is valid, but upstream expresses it as direct dependencies on FFmpeg component libraries: `libavcodec`, `libavfilter`, `libavformat`, `libavutil`, `libswresample`, and `libswscale`.
- `libmpv -> libass` and `libmpv -> libplacebo` are valid hard dependencies in mpv's top-level Meson build.
- `libmpv -> libbluray`, `libmpv -> libuchardet`, and `libmpv -> libluajit` are not hard upstream dependencies. They are valid only when those features are enabled or auto-detected. Lua is especially important: mpv supports several Lua package names; `libluajit` is one implementation choice, not the only upstream edge.
- Potential graph issue: mpv has a direct optional `lcms2` dependency. If MPVKitBuilder leaves mpv's `lcms2` option as `auto` while its pkg-config path exposes lcms2, `libmpv -> lcms2` should be represented as a direct conditional edge.
- Potential graph issue: mpv has a direct optional `vulkan` dependency when Vulkan context support is enabled, and it requires libplacebo to have Vulkan support. If enabled, `libmpv -> vulkan` should be represented as a direct conditional edge, even though the graph already reaches Vulkan through `libplacebo`.

### libass 0.17.4

- `libass -> libfreetype`, `libass -> libfribidi`, and `libass -> libharfbuzz` are valid upstream dependencies.
- `libass -> libunibreak` is optional upstream, controlled by the `libunibreak` option. It is valid only as an enabled-feature dependency.
- The graph does not show a font provider edge. On Apple platforms, libass can use CoreText; fontconfig is optional. A graph that intentionally disables fontconfig and uses CoreText does not need a third-party font provider edge.

### libplacebo v7.351.0

- `libplacebo -> vulkan`, `libplacebo -> libshaderc`, and `libplacebo -> lcms2` are valid optional-feature dependencies, not mandatory minimum dependencies.
- Potential graph issue: libplacebo also has optional `libdovi` support. If this build enables or auto-detects libdovi, the graph should include `libplacebo -> libdovi`. If libdovi is intentionally not exposed to libplacebo or disabled, the absent edge is acceptable but should be documented as a policy choice.

### Other Supporting Libraries

- `libbluray -> libfreetype` is valid when FreeType support is enabled. Upstream libbluray treats FreeType, libxml2, and fontconfig as default-enabled optional dependencies, so the graph is only complete if libxml2/fontconfig are intentionally supplied by the system or disabled/out of scope.
- `libsrt -> openssl` is valid when SRT encryption is enabled. Upstream documents OpenSSL as the dependency for encryption; the edge is a policy dependency if encryption is kept on.
- `libsmbclient -> openssl` is not supported by the independent upstream evidence checked so far. Samba's official dependency documentation names GnuTLS for cryptography, and the Samba 4.15.13 build scripts process `system_gnutls` and build `GNUTLS_HELPERS`. Unless a local patch intentionally replaces or supplements this with OpenSSL, the graph edge should be considered wrong or at least patch-specific and undocumented.

### Standalone Rows

- The `depends on: -` rows are mostly valid only as top-level MPVKitBuilder graph rows. They do not mean the upstream projects have no build tools, system libraries, bundled dependencies, or optional dependencies.
- `libfreetype -> -` is valid only if optional Brotli, bzip2, HarfBuzz, PNG, and zlib integration are disabled or intentionally out of this graph.
- `lcms2 -> -` is valid only if optional JPEG, TIFF, and zlib support are disabled or intentionally out of this graph.
- `libzvbi -> -` omits system-level dependencies such as math, pthread, iconv, optional PNG, and optional X11. None of these are graph libraries, so the row is acceptable for a top-level library graph.
- `libdav1d -> -` omits build tools/system dependencies such as NASM and threads. None are graph libraries.
- `libshaderc -> -` is not a complete upstream dependency statement. Shaderc's own DEPS file includes glslang, SPIR-V Headers, SPIR-V Tools, Abseil, Effcee, RE2, and GoogleTest under `third_party`. This is acceptable only if the graph scope excludes internal third-party fetches.
- `vulkan -> -` means the graph treats MoltenVK as the top-level Vulkan provider. MoltenVK itself requires `fetchDependencies` for external open-source libraries and Xcode to build.
- `libdovi -> -` omits Rust crate dependencies. This is acceptable only if the graph scope is limited to MPVKitBuilder top-level libraries rather than Cargo dependencies.
- `libunibreak`, `libfribidi`, `libuchardet`, `libuavs3d`, `libluajit`, and `openssl` did not show dependencies on other libraries in this graph scope in the checked upstream files/docs.

## Sources Consulted

- FFmpeg `n8.1.1` `configure`: `https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.1.1/configure`
  - Option declarations: `--enable-lcms2`, `--enable-libass`, `--enable-libbluray`, `--enable-libdav1d`, `--enable-libplacebo`, `--enable-libshaderc`, `--enable-libsmbclient`, `--enable-libsrt`, `--enable-libuavs3d`, `--enable-libzvbi`, `--enable-openssl`.
  - Feature deps: `libdav1d_decoder_deps`, `libuavs3d_decoder_deps`, `libzvbi_teletext_decoder_deps`, `bluray_protocol_deps`, `libsmbclient_protocol_deps`, `libsrt_protocol_deps`, `libplacebo_filter_deps`.
  - Package checks: `require_pkg_config` / `check_pkg_config` for the external packages above.
- mpv `v0.41.0` `meson.build`: `https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/meson.build`
  - Hard deps: FFmpeg component libraries, `libplacebo`, `libass`.
  - Optional deps: `lcms2`, `libbluray`, Lua packages including `luajit`, `uchardet`, `vulkan`.
- mpv `v0.41.0` `meson.options`: `https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/meson.options`
  - Defaults: `lcms2`, `libbluray`, `lua`, `uchardet`, and `vulkan` are `auto`; `gpl` defaults to true.
- libass `0.17.4` `meson.build`: `https://raw.githubusercontent.com/libass/libass/0.17.4/meson.build`
  - Dependencies checked: `freetype2`, `fribidi`, `harfbuzz`, optional `libunibreak`, font providers.
- HarfBuzz `10.1.0` `meson.build`: `https://raw.githubusercontent.com/harfbuzz/harfbuzz/10.1.0/meson.build`
  - FreeType dependency checked through `freetype2` / `FreeType` lookup.
- libplacebo `v7.351.0` `README.md`: `https://raw.githubusercontent.com/haasn/libplacebo/v7.351.0/README.md`
  - Optional dependencies list checked: `lcms`, `libdovi`, `shaderc`, `vulkan`.
- libplacebo `v7.351.0` `meson_options.txt`: `https://raw.githubusercontent.com/haasn/libplacebo/v7.351.0/meson_options.txt`
  - Defaults checked: `vulkan`, `shaderc`, `lcms`, `libdovi` are `auto`.
- libbluray `1.3.4` `configure.ac`: `https://code.videolan.org/videolan/libbluray/-/raw/1.3.4/configure.ac`
  - Default-enabled optional checks for `libxml2`, `freetype2`, `fontconfig`.
- SRT `v1.5.3` `README.md`: `https://raw.githubusercontent.com/Haivision/srt/v1.5.3/README.md`
  - Requirement checked: OpenSSL for encryption unless `ENABLE_ENCRYPTION=OFF`.
- Samba `samba-4.15.13` `wscript`: `https://raw.githubusercontent.com/samba-team/samba/samba-4.15.13/wscript`
  - Checked `system_gnutls` and `lib/crypto` recursion.
- Samba `samba-4.15.13` `lib/crypto/wscript_build`: `https://raw.githubusercontent.com/samba-team/samba/samba-4.15.13/lib/crypto/wscript_build`
  - Checked `GNUTLS_HELPERS` and `deps='gnutls samba-errors'`.
- SambaWiki package dependencies: `https://wiki.samba.org/index.php/Package_Dependencies_Required_to_Build_Samba`
  - Official dependency table checked: `gnutls >= 3.4.7` is required for cryptography.
- FreeType `VER-2-13-3` `meson_options.txt`: `https://raw.githubusercontent.com/freetype/freetype/VER-2-13-3/meson_options.txt`
  - Optional deps checked: Brotli, bzip2, HarfBuzz, PNG/libpng, zlib.
- FriBidi `v1.0.13` `meson.build`: `https://raw.githubusercontent.com/fribidi/fribidi/v1.0.13/meson.build`
  - No dependency on another graph library found.
- Shaderc `v2024.4` `DEPS`: `https://raw.githubusercontent.com/google/shaderc/v2024.4/DEPS`
  - Internal third-party deps checked: Abseil, Effcee, glslang, GoogleTest, RE2, SPIR-V Headers, SPIR-V Tools.
- LittleCMS `lcms2.17` `configure.ac`: `https://raw.githubusercontent.com/mm2/Little-CMS/lcms2.17/configure.ac`
  - Optional deps checked: JPEG, TIFF, zlib.
- libunibreak `libunibreak_6_1` `README.md`: `https://raw.githubusercontent.com/adah1972/libunibreak/libunibreak_6_1/README.md`
  - Build instructions checked; no dependency on another graph library found.
- uchardet `v0.0.8` `CMakeLists.txt`: `https://gitlab.freedesktop.org/uchardet/uchardet/-/raw/v0.0.8/CMakeLists.txt`
  - No dependency on another graph library found in CMake file.
- ZVBI `v0.2.42` `configure.ac`: `https://raw.githubusercontent.com/zapping-vbi/zvbi/v0.2.42/configure.ac`
  - System/optional deps checked: math, pthread, iconv, PNG/zlib, X11.
- dav1d `1.5.1` `meson.build`: `https://raw.githubusercontent.com/videolan/dav1d/1.5.1/meson.build`
  - System/build deps checked: threads, `dl`, atomics, NASM.
- uavs3d `master` `CMakeLists.txt`: `https://raw.githubusercontent.com/uavs3/uavs3d/master/CMakeLists.txt`
  - Tag `v1.2.1` raw path returned 404; master CMake showed no dependency on another graph library.
- MoltenVK `v1.2.11` `README.md`: `https://raw.githubusercontent.com/KhronosGroup/MoltenVK/v1.2.11/README.md`
  - `fetchDependencies` and Xcode build requirements checked.
- OpenSSL `openssl-3.3.5` `README.md`: `https://raw.githubusercontent.com/openssl/openssl/openssl-3.3.5/README.md`
  - Build notes checked; no dependency on another graph library found.
- Dolby Vision crate `dolby_vision 3.3.2` `Cargo.toml` via docs.rs: `https://docs.rs/crate/dolby_vision/3.3.2/source/Cargo.toml`
  - Rust crate dependencies checked; no dependency on another graph library found.
- LuaJIT `v2.1` install docs: `https://raw.githubusercontent.com/LuaJIT/LuaJIT/v2.1/doc/install.html`
  - Build/toolchain requirements checked; no dependency on another graph library found.
