import Foundation

// MARK: - Three-tier FFmpeg configure strategy
//
// Tier 1: base — shared across all platforms/architectures.
// Tier 2: platformExtra — per (platform, arch).
// Tier 3: enableFlags — auto-generated from built dependency thinDirs (computed at build time by LibFFmpegBuilder).
// CLI extra-ffmpeg args append last, so they always win.

enum FFmpegOptions {
    static let base: [String] = [
        // Disable unused ARM sub-targets
        "--disable-armv5te", "--disable-armv6", "--disable-armv6t2",
        // Disable system libs / unused features
        "--disable-bzlib", "--disable-gray", "--disable-iconv", "--disable-linux-perf",
        "--disable-shared", "--disable-small", "--disable-swscale-alpha",
        "--disable-symver", "--disable-xlib",
        // Cross-compile / optimisation
        "--enable-cross-compile",
        "--enable-optimizations", "--enable-pic", "--enable-runtime-cpudetect",
        "--enable-static", "--enable-thumb", "--enable-version3",
        "--pkg-config-flags=--static",
        // Documentation off
        "--disable-doc", "--disable-htmlpages", "--disable-manpages",
        "--disable-podpages", "--disable-txtpages",
        // Core libraries
        "--enable-avcodec", "--enable-avformat", "--enable-avutil",
        "--enable-network", "--enable-swresample", "--enable-swscale",
        // Disable device layers / postproc; selectively re-enable below
        "--disable-devices", "--disable-outdevs", "--disable-indevs", "--disable-postproc",
        "--enable-indev=lavfi",
        // Non-Apple hardware accel off
        "--disable-d3d11va", "--disable-dxva2", "--disable-vaapi", "--disable-vdpau",
        // Vulkan video codecs cause link issues — disable until shaderc fully wired
        "--disable-hwaccel=av1_vulkan,hevc_vulkan,h264_vulkan",
        // All codec/format/protocol groups on (full-open strategy)
        "--enable-muxers", "--enable-encoders", "--enable-protocols",
        "--enable-demuxers", "--enable-bsfs", "--enable-decoders",
        // Filters: disable all then re-enable a curated common set
        "--disable-filters",
        "--enable-filter=aformat", "--enable-filter=amix", "--enable-filter=anull",
        "--enable-filter=aresample", "--enable-filter=areverse", "--enable-filter=asetrate",
        "--enable-filter=atempo", "--enable-filter=atrim",
        "--enable-filter=boxblur", "--enable-filter=bwdif", "--enable-filter=delogo",
        "--enable-filter=equalizer", "--enable-filter=estdif",
        "--enable-filter=firequalizer", "--enable-filter=format", "--enable-filter=fps",
        "--enable-filter=gblur",
        "--enable-filter=hflip", "--enable-filter=hwdownload",
        "--enable-filter=hwmap", "--enable-filter=hwupload",
        "--enable-filter=idet", "--enable-filter=lenscorrection",
        "--enable-filter=lut*", "--enable-filter=negate", "--enable-filter=null",
        "--enable-filter=overlay",
        "--enable-filter=palettegen", "--enable-filter=paletteuse", "--enable-filter=pan",
        "--enable-filter=rotate",
        "--enable-filter=scale", "--enable-filter=setpts", "--enable-filter=superequalizer",
        "--enable-filter=transpose", "--enable-filter=trim",
        "--enable-filter=vflip", "--enable-filter=volume",
        "--enable-filter=w3fdif", "--enable-filter=yadif", "--enable-filter=subtitles",
        // Vulkan-based filters (requires vulkan/MoltenVK)
        "--enable-filter=avgblur_vulkan", "--enable-filter=blend_vulkan",
        "--enable-filter=bwdif_vulkan", "--enable-filter=chromaber_vulkan",
        "--enable-filter=flip_vulkan", "--enable-filter=gblur_vulkan",
        "--enable-filter=hflip_vulkan", "--enable-filter=nlmeans_vulkan",
        "--enable-filter=overlay_vulkan", "--enable-filter=vflip_vulkan",
        "--enable-filter=xfade_vulkan",
    ]

    static func platformExtra(_ platform: PlatformType, _ arch: ArchType) -> [String] {
        var args: [String] = []

        args.append("--arch=\(arch.cpuFamily)")
        args.append("--target-os=darwin")
        // libxml2 is always available as an Apple system framework
        args.append("--enable-libxml2")

        // x86_64 and Mac Catalyst require ASM disabled:
        // x86_64 binaries are built without ASM support since ASM for x86_64 is
        // actually x86 and that confuses xcodebuild -create-xcframework.
        if platform == .maccatalyst || arch == .x86_64 {
            args.append("--disable-neon")
            args.append("--disable-asm")
        } else {
            args.append("--enable-neon")
            args.append("--enable-asm")
        }

        // Apple hardware acceleration (not supported on tvOS/visionOS)
        if ![.tvos, .tvsimulator, .xros, .xrsimulator].contains(platform) {
            args.append("--enable-videotoolbox")
            args.append("--enable-audiotoolbox")
            args.append("--enable-filter=yadif_videotoolbox")
            args.append("--enable-filter=scale_vt")
            args.append("--enable-filter=transpose_vt")
        }

        // audiotoolbox output device — macOS only
        if platform == .macos {
            args.append("--enable-outdev=audiotoolbox")
        }

        // AVFoundation capture — not available on tvOS/visionOS
        if ![.tvos, .tvsimulator, .xros, .xrsimulator].contains(platform) {
            args.append("--enable-indev=avfoundation")
        }

        // Disable CLI tools for all cross-compiled targets
        args.append("--disable-programs")

        return args
    }
}
