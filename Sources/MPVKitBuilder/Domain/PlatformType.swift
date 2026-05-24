import Foundation

enum PlatformType: String, CaseIterable, Codable {
    case macos
    case ios
    case isimulator
    case tvos
    case tvsimulator
    case xros
    case xrsimulator
    case maccatalyst
}

extension PlatformType {
    static var defaultEnabled: [PlatformType] {
        [.macos, .ios, .isimulator, .tvos, .tvsimulator, .xros, .xrsimulator, .maccatalyst]
    }

    var minVersion: String {
        switch self {
        case .ios, .isimulator:       return "13.0"
        case .tvos, .tvsimulator:     return "13.0"
        case .macos:                  return "10.15"
        case .maccatalyst:            return "14.0"
        case .xros, .xrsimulator:     return "1.0"
        }
    }

    var name: String {
        switch self {
        case .macos, .ios, .tvos: return rawValue
        case .isimulator:         return "iossim"
        case .tvsimulator:        return "tvossim"
        case .maccatalyst:        return "maccat"
        case .xros:               return "visionos"
        case .xrsimulator:        return "visionossim"
        }
    }

    var frameworkName: String {
        switch self {
        case .ios:          return "ios-arm64"
        case .maccatalyst:  return "ios-arm64_x86_64-maccatalyst"
        case .isimulator:   return "ios-arm64_x86_64-simulator"
        case .macos:        return "macos-arm64_x86_64"
        case .tvos:         return "tvos-arm64_arm64e"
        case .tvsimulator:  return "tvos-arm64_x86_64-simulator"
        case .xros:         return "xros-arm64"
        case .xrsimulator:  return "xros-arm64_x86_64-simulator"
        }
    }

    var architectures: [ArchType] {
        switch self {
        case .ios, .xros:                       return [.arm64]
        case .tvos:                             return [.arm64, .arm64e]
        case .isimulator, .tvsimulator:         return [.arm64, .x86_64]
        case .xrsimulator:                      return [.arm64]
        case .macos:
            #if arch(x86_64)
            return [.x86_64, .arm64]
            #else
            return [.arm64, .x86_64]
            #endif
        case .maccatalyst:                      return [.arm64, .x86_64]
        }
    }

    var sdk: String {
        switch self {
        case .ios:                   return "iPhoneOS"
        case .isimulator:            return "iPhoneSimulator"
        case .tvos:                  return "AppleTVOS"
        case .tvsimulator:           return "AppleTVSimulator"
        case .xros:                  return "XROS"
        case .xrsimulator:           return "XRSimulator"
        case .maccatalyst, .macos:   return "MacOSX"
        }
    }

    var mesonSubSystem: String {
        switch self {
        case .isimulator:    return "ios-simulator"
        case .tvsimulator:   return "tvos-simulator"
        case .xrsimulator:   return "xros-simulator"
        default:             return rawValue
        }
    }

    var cc: String { "/usr/bin/clang" }
}

// MARK: - Cross compile flags

extension PlatformType {
    func host(arch: ArchType) -> String {
        switch self {
        case .macos:
            return "\(arch.targetCpu)-apple-darwin"
        case .ios, .tvos, .xros:
            return "\(arch.targetCpu)-\(rawValue)-darwin"
        case .isimulator, .maccatalyst:
            return PlatformType.ios.host(arch: arch)
        case .tvsimulator:
            return PlatformType.tvos.host(arch: arch)
        case .xrsimulator:
            return PlatformType.xros.host(arch: arch)
        }
    }

    func deploymentTarget(_ arch: ArchType) -> String {
        switch self {
        case .ios, .macos, .tvos, .xros:
            return "\(arch.targetCpu)-apple-\(rawValue)\(minVersion)"
        case .maccatalyst:
            return "\(arch.targetCpu)-apple-ios\(minVersion)-macabi"
        case .isimulator:
            return PlatformType.ios.deploymentTarget(arch) + "-simulator"
        case .tvsimulator:
            return PlatformType.tvos.deploymentTarget(arch) + "-simulator"
        case .xrsimulator:
            return PlatformType.xros.deploymentTarget(arch) + "-simulator"
        }
    }

    var osVersionMin: String {
        switch self {
        case .ios, .tvos:                        return "-m\(rawValue)-version-min=\(minVersion)"
        case .macos:                             return "-mmacosx-version-min=\(minVersion)"
        case .isimulator:                        return "-mios-simulator-version-min=\(minVersion)"
        case .tvsimulator:                       return "-mtvos-simulator-version-min=\(minVersion)"
        case .maccatalyst, .xros, .xrsimulator:  return ""
        }
    }

    func cFlags(arch: ArchType) -> [String] {
        var flags = ldFlags(arch: arch)
        if !osVersionMin.isEmpty { flags.append(osVersionMin) }
        flags.append("-fno-common")
        return flags
    }

    func ldFlags(arch: ArchType) -> [String] {
        let sysroot = isysroot
        var flags = ["-arch", arch.rawValue, "-isysroot", sysroot, "-target", deploymentTarget(arch)]
        if self == .maccatalyst {
            flags.append("-iframework")
            flags.append("\(sysroot)/System/iOSSupport/System/Library/Frameworks")
        }
        return flags
    }

    var isysroot: String {
        Xcrun.find(tool: "--show-sdk-path", sdk: sdk)
    }

    func xcrunFind(tool: String) -> String {
        Xcrun.find(tool: tool, sdk: sdk)
    }
}

// MARK: - Xcrun helper

enum Xcrun {
    static func find(tool: String, sdk: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        if tool.hasPrefix("--") {
            task.arguments = ["--sdk", sdk.lowercased(), tool]
        } else {
            task.arguments = ["--sdk", sdk.lowercased(), "--find", tool]
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
