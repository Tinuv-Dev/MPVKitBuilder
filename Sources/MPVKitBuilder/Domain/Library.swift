import Foundation

enum Library: String, CaseIterable, Codable {
    case openssl
    case libunibreak
    case libfreetype
    case libfribidi
    case libharfbuzz
    case libass
    case libuchardet
    case libbluray
    case libsrt
    case libzvbi
    case libsmbclient
    case vulkan
    case libshaderc
    case lcms2
    case libplacebo
    case libdav1d
    case libuavs3d
    case libdovi
    case libluajit
    case ffmpeg
    case libmpv
}

// MARK: - Metadata

extension Library {
    var version: String {
        switch self {
        case .openssl:       return "3.3.5"
        case .libunibreak:   return "libunibreak_6_1"
        case .libfreetype:   return "VER-2-13-3"
        case .libfribidi:    return "v1.0.13"
        case .libharfbuzz:   return "10.1.0"
        case .libass:        return "0.17.4"
        case .libuchardet:   return "v0.0.8"
        case .libbluray:     return "1.3.4"
        case .libsrt:        return "v1.5.3"
        case .libzvbi:       return "v0.2.42"
        case .libsmbclient:  return "samba-4.15.13"
        case .vulkan:        return "v1.2.11"
        case .libshaderc:    return "v2024.4"
        case .lcms2:         return "lcms2.17"
        case .libplacebo:    return "v7.351.0"
        case .libdav1d:      return "1.5.1"
        case .libuavs3d:     return "v1.2.1"
        case .libdovi:       return "3.3.2"
        case .libluajit:     return "v2.1"
        case .ffmpeg:        return "n8.1.1"
        case .libmpv:        return "v0.41.0"
        }
    }

    var repoURL: String {
        switch self {
        case .openssl:       return "https://github.com/openssl/openssl"
        case .libunibreak:   return "https://github.com/adah1972/libunibreak"
        case .libfreetype:   return "https://github.com/freetype/freetype"
        case .libfribidi:    return "https://github.com/fribidi/fribidi"
        case .libharfbuzz:   return "https://github.com/harfbuzz/harfbuzz"
        case .libass:        return "https://github.com/libass/libass"
        case .libuchardet:   return "https://gitlab.freedesktop.org/uchardet/uchardet"
        case .libbluray:     return "https://code.videolan.org/videolan/libbluray"
        case .libsrt:        return "https://github.com/Haivision/srt"
        case .libzvbi:       return "https://github.com/zapping-vbi/zvbi"
        case .libsmbclient:  return "https://github.com/samba-team/samba"
        case .vulkan:        return "https://github.com/KhronosGroup/MoltenVK"
        case .libshaderc:    return "https://github.com/google/shaderc"
        case .lcms2:         return "https://github.com/mm2/Little-CMS"
        case .libplacebo:    return "https://github.com/haasn/libplacebo"
        case .libdav1d:      return "https://code.videolan.org/videolan/dav1d"
        case .libuavs3d:     return "https://github.com/uavs3/uavs3d"
        case .libdovi:       return "https://github.com/quietvoid/dovi_tool"
        case .libluajit:     return "https://github.com/LuaJIT/LuaJIT"
        case .ffmpeg:        return "https://github.com/FFmpeg/FFmpeg"
        case .libmpv:        return "https://github.com/mpv-player/mpv"
        }
    }

    var sourceReference: String {
        switch self {
        case .openssl:
            return "openssl-\(version)"
        default:
            return version
        }
    }

    var expectedFrameworks: [String] {
        switch self {
        case .openssl:
            return ["Libssl", "Libcrypto"]
        default:
            return [rawValue]
        }
    }

    /// Whether this library is enabled by ffmpeg when present (used to auto-emit `--enable-libxxx`).
    var isFFmpegDependentLibrary: Bool {
        switch self {
        case .openssl, .libass, .libsmbclient, .vulkan, .libshaderc,
             .lcms2, .libplacebo, .libdav1d, .libuavs3d, .libbluray,
             .libsrt, .libzvbi:
            return true
        default:
            return false
        }
    }

    func makeBuilder(context: BuildContext) throws -> Builder {
        switch self {
        case .openssl:       return LibOpenSSLBuilder(context: context)
        case .libunibreak:   return LibUnibreakBuilder(context: context)
        case .libfreetype:   return LibFreetypeBuilder(context: context)
        case .libfribidi:    return LibFribidiBuilder(context: context)
        case .libharfbuzz:   return LibHarfbuzzBuilder(context: context)
        case .libass:        return LibAssBuilder(context: context)
        case .libbluray:     return LibBlurayBuilder(context: context)
        case .libsrt:        return LibSrtBuilder(context: context)
        case .libzvbi:       return LibZvbiBuilder(context: context)
        case .libsmbclient:  return LibSmbclientBuilder(context: context)
        case .vulkan:        return LibVulkanBuilder(context: context)
        case .libshaderc:    return LibShadercBuilder(context: context)
        case .lcms2:         return LibLcms2Builder(context: context)
        case .libplacebo:    return LibPlaceboBuilder(context: context)
        case .libdav1d:      return LibDav1dBuilder(context: context)
        case .libuavs3d:     return LibUavs3dBuilder(context: context)
        case .ffmpeg:        return LibFFmpegBuilder(context: context)
        default:
            throw BuildError.unexpected("\(rawValue) builder is not implemented yet")
        }
    }
}
