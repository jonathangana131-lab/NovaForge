import Foundation
import SwiftUI
import UIKit

enum AgentTheme: String, CaseIterable, Identifiable {
    case matrixRain
    case midnightBlack
    case whiteGold
    case arcticGlass
    case emberCore

    static let storageKey = "novaForgeTheme"
    static let defaultTheme: AgentTheme = .midnightBlack

    var id: String { rawValue }

    static var current: AgentTheme {
        let stored = UserDefaults.standard.string(forKey: storageKey) ?? AgentTheme.defaultTheme.rawValue
        return resolved(from: stored)
    }

    static func resolved(from rawValue: String?) -> AgentTheme {
        guard let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .defaultTheme
        }
        return AgentTheme(rawValue: rawValue) ?? theme(matching: rawValue) ?? .defaultTheme
    }

    @discardableResult
    static func normalizeStoredTheme() -> AgentTheme {
        let stored = UserDefaults.standard.string(forKey: storageKey)
        let theme = resolved(from: stored)
        if stored != theme.rawValue {
            UserDefaults.standard.set(theme.rawValue, forKey: storageKey)
        }
        return theme
    }

    static func theme(matching value: String) -> AgentTheme? {
        let key = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        switch key {
        case "matrixrain", "matrix", "terminal", "terminalnoir":
            return .matrixRain
        case "midnightblack", "midnight", "graphite", "graphiteblack", "novalight", "novadark":
            return .midnightBlack
        case "whitegold", "gold", "luxury", "lightglass":
            return .whiteGold
        case "arcticglass", "arctic", "aurora", "auroranight":
            return .arcticGlass
        case "embercore", "ember", "solar", "eclipse":
            return .emberCore
        default:
            return nil
        }
    }

    static func launchOverride(from arguments: [String]) -> AgentTheme? {
        for argument in arguments {
            if argument.hasPrefix("--theme-world=") {
                return theme(matching: String(argument.dropFirst("--theme-world=".count)))
            }
            if argument.hasPrefix("--theme=") {
                return theme(matching: String(argument.dropFirst("--theme=".count)))
            }
        }

        if let index = arguments.firstIndex(of: "--theme-world"),
           arguments.indices.contains(arguments.index(after: index)) {
            return theme(matching: arguments[arguments.index(after: index)])
        }
        if let index = arguments.firstIndex(of: "--theme"),
           arguments.indices.contains(arguments.index(after: index)) {
            return theme(matching: arguments[arguments.index(after: index)])
        }
        return nil
    }

    var title: String {
        switch self {
        case .matrixRain: "Matrix Rain"
        case .midnightBlack: "Midnight Black"
        case .whiteGold: "White Gold"
        case .arcticGlass: "Arctic Glass"
        case .emberCore: "Ember Core"
        }
    }

    var subtitle: String {
        switch self {
        case .matrixRain: "Black glass, green codefall, tuned terminal glow"
        case .midnightBlack: "Quiet black workspace with crisp premium contrast"
        case .whiteGold: "Bright luxury glass with warm gold controls"
        case .arcticGlass: "Icy blue proof surfaces and calm hybrid glass"
        case .emberCore: "Graphite command center with amber-red energy"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .whiteGold: .light
        default: .dark
        }
    }

    var palette: AgentThemePalette {
        switch self {
        case .matrixRain:
            AgentThemePalette(
                isLight: false,
                material: .codeGlass,
                backgroundEffect: .matrixRain,
                typography: .init(interfaceDesign: .monospaced, displayDesign: .monospaced, codeDesign: .monospaced),
                textPrimary: Color(red: 0.88, green: 1.00, blue: 0.90),
                textSecondary: Color(red: 0.61, green: 0.82, blue: 0.66),
                textTertiary: Color(red: 0.38, green: 0.61, blue: 0.44),
                textQuaternary: Color(red: 0.22, green: 0.40, blue: 0.27),
                backgroundA: Color(red: 0.000, green: 0.020, blue: 0.010),
                backgroundB: Color(red: 0.000, green: 0.050, blue: 0.026),
                backgroundC: Color(red: 0.016, green: 0.130, blue: 0.060),
                backgroundD: Color(red: 0.000, green: 0.006, blue: 0.004),
                surface: Color(red: 0.010, green: 0.050, blue: 0.030).opacity(0.96),
                surfaceElevated: Color(red: 0.018, green: 0.095, blue: 0.052).opacity(0.98),
                surfaceAlt: Color(red: 0.025, green: 0.180, blue: 0.090).opacity(0.72),
                row: Color(red: 0.012, green: 0.075, blue: 0.040).opacity(0.94),
                rowSelected: Color(red: 0.090, green: 0.820, blue: 0.340).opacity(0.56),
                controlFill: Color(red: 0.018, green: 0.095, blue: 0.052).opacity(0.92),
                controlFillSelected: Color(red: 0.090, green: 0.820, blue: 0.340).opacity(0.62),
                controlBorder: Color(red: 0.280, green: 1.000, blue: 0.470).opacity(0.26),
                border: Color(red: 0.420, green: 1.000, blue: 0.550).opacity(0.18),
                divider: Color(red: 0.360, green: 0.880, blue: 0.480).opacity(0.22),
                primaryAccent: Color(red: 0.180, green: 1.000, blue: 0.360),
                secondaryAccent: Color(red: 0.150, green: 0.900, blue: 0.620),
                storageAccent: Color(red: 0.240, green: 0.780, blue: 0.420),
                semanticSuccess: Color(red: 0.200, green: 0.960, blue: 0.400),
                semanticWarning: Color(red: 1.000, green: 0.760, blue: 0.270),
                semanticError: Color(red: 1.000, green: 0.330, blue: 0.330),
                semanticInfo: Color(red: 0.310, green: 0.980, blue: 0.660),
                semanticApproval: Color(red: 0.330, green: 1.000, blue: 0.520),
                semanticRunning: Color(red: 0.530, green: 1.000, blue: 0.390),
                semanticBlocked: Color(red: 1.000, green: 0.250, blue: 0.250),
                terminalBackground: Color(red: 0.000, green: 0.018, blue: 0.010),
                terminalText: Color(red: 0.780, green: 1.000, blue: 0.800),
                terminalPrompt: Color(red: 0.170, green: 1.000, blue: 0.350),
                terminalCommand: Color(red: 0.580, green: 1.000, blue: 0.620),
                terminalOutput: Color(red: 0.650, green: 0.880, blue: 0.680),
                terminalWarning: Color(red: 1.000, green: 0.760, blue: 0.270),
                terminalError: Color(red: 1.000, green: 0.360, blue: 0.330),
                terminalSelection: Color(red: 0.140, green: 0.920, blue: 0.360).opacity(0.28),
                codeBackground: Color(red: 0.000, green: 0.024, blue: 0.012),
                codeText: Color(red: 0.820, green: 1.000, blue: 0.840),
                codeKeyword: Color(red: 0.240, green: 1.000, blue: 0.380),
                codeString: Color(red: 0.760, green: 1.000, blue: 0.560),
                codeComment: Color(red: 0.360, green: 0.600, blue: 0.390),
                codeType: Color(red: 0.460, green: 1.000, blue: 0.720),
                codeCursor: Color(red: 0.220, green: 1.000, blue: 0.420),
                glassTint: Color(red: 0.020, green: 0.180, blue: 0.080).opacity(0.42),
                glassStroke: Color(red: 0.330, green: 1.000, blue: 0.480).opacity(0.22),
                glow: Color(red: 0.110, green: 1.000, blue: 0.340).opacity(0.58),
                shadow: Color.black.opacity(0.50),
                backgroundMotionOpacity: 0.60,
                glowRadius: 18
            )

        case .midnightBlack:
            AgentThemePalette(
                isLight: false,
                material: .blackGlass,
                backgroundEffect: .midnightDepth,
                typography: .init(interfaceDesign: .rounded, displayDesign: .rounded, codeDesign: .monospaced),
                textPrimary: Color(red: 0.950, green: 0.960, blue: 0.980),
                textSecondary: Color(red: 0.700, green: 0.730, blue: 0.790),
                textTertiary: Color(red: 0.500, green: 0.530, blue: 0.590),
                textQuaternary: Color(red: 0.340, green: 0.370, blue: 0.430),
                backgroundA: Color(red: 0.006, green: 0.007, blue: 0.010),
                backgroundB: Color(red: 0.020, green: 0.023, blue: 0.030),
                backgroundC: Color(red: 0.045, green: 0.052, blue: 0.064),
                backgroundD: Color(red: 0.000, green: 0.000, blue: 0.004),
                surface: Color(red: 0.055, green: 0.060, blue: 0.072).opacity(0.90),
                surfaceElevated: Color(red: 0.080, green: 0.088, blue: 0.108).opacity(0.92),
                surfaceAlt: Color(red: 0.150, green: 0.170, blue: 0.210).opacity(0.28),
                row: Color(red: 0.082, green: 0.090, blue: 0.110).opacity(0.84),
                rowSelected: Color(red: 0.380, green: 0.760, blue: 0.940).opacity(0.16),
                controlFill: Color(red: 0.092, green: 0.100, blue: 0.120).opacity(0.86),
                controlFillSelected: Color(red: 0.380, green: 0.760, blue: 0.940).opacity(0.16),
                controlBorder: Color.white.opacity(0.14),
                border: Color.white.opacity(0.145),
                divider: Color.white.opacity(0.12),
                primaryAccent: Color(red: 0.640, green: 0.830, blue: 0.960),
                secondaryAccent: Color(red: 0.760, green: 0.780, blue: 0.880),
                storageAccent: Color(red: 0.620, green: 0.700, blue: 0.900),
                semanticSuccess: Color(red: 0.340, green: 0.820, blue: 0.600),
                semanticWarning: Color(red: 1.000, green: 0.720, blue: 0.320),
                semanticError: Color(red: 1.000, green: 0.420, blue: 0.500),
                semanticInfo: Color(red: 0.540, green: 0.820, blue: 1.000),
                semanticApproval: Color(red: 0.600, green: 0.780, blue: 1.000),
                semanticRunning: Color(red: 0.720, green: 0.740, blue: 0.980),
                semanticBlocked: Color(red: 1.000, green: 0.420, blue: 0.500),
                terminalBackground: Color(red: 0.010, green: 0.012, blue: 0.016),
                terminalText: Color(red: 0.900, green: 0.930, blue: 0.960),
                terminalPrompt: Color(red: 0.640, green: 0.830, blue: 0.960),
                terminalCommand: Color(red: 0.820, green: 0.860, blue: 0.920),
                terminalOutput: Color(red: 0.700, green: 0.740, blue: 0.800),
                terminalWarning: Color(red: 1.000, green: 0.720, blue: 0.320),
                terminalError: Color(red: 1.000, green: 0.420, blue: 0.500),
                terminalSelection: Color(red: 0.540, green: 0.820, blue: 1.000).opacity(0.20),
                codeBackground: Color(red: 0.020, green: 0.023, blue: 0.030),
                codeText: Color(red: 0.920, green: 0.940, blue: 0.970),
                codeKeyword: Color(red: 0.620, green: 0.820, blue: 1.000),
                codeString: Color(red: 0.550, green: 0.840, blue: 0.690),
                codeComment: Color(red: 0.500, green: 0.540, blue: 0.600),
                codeType: Color(red: 0.770, green: 0.760, blue: 0.960),
                codeCursor: Color(red: 0.720, green: 0.880, blue: 1.000),
                glassTint: Color.white.opacity(0.08),
                glassStroke: Color.white.opacity(0.16),
                glow: Color(red: 0.540, green: 0.820, blue: 1.000).opacity(0.22),
                shadow: Color.black.opacity(0.52),
                backgroundMotionOpacity: 0.18,
                glowRadius: 10
            )

        case .whiteGold:
            AgentThemePalette(
                isLight: true,
                material: .lightLuxuryGlass,
                backgroundEffect: .whiteGoldVeil,
                typography: .init(interfaceDesign: .serif, displayDesign: .serif, codeDesign: .monospaced),
                textPrimary: Color(red: 0.115, green: 0.105, blue: 0.085),
                textSecondary: Color(red: 0.335, green: 0.300, blue: 0.245),
                textTertiary: Color(red: 0.530, green: 0.470, blue: 0.380),
                textQuaternary: Color(red: 0.650, green: 0.585, blue: 0.485),
                backgroundA: Color(red: 0.990, green: 0.980, blue: 0.945),
                backgroundB: Color(red: 0.965, green: 0.935, blue: 0.850),
                backgroundC: Color(red: 0.930, green: 0.850, blue: 0.620),
                backgroundD: Color(red: 1.000, green: 0.995, blue: 0.970),
                surface: Color(red: 1.000, green: 0.990, blue: 0.955).opacity(0.88),
                surfaceElevated: Color(red: 1.000, green: 0.985, blue: 0.930).opacity(0.94),
                surfaceAlt: Color(red: 0.900, green: 0.730, blue: 0.380).opacity(0.20),
                row: Color(red: 0.980, green: 0.955, blue: 0.895).opacity(0.86),
                rowSelected: Color(red: 0.780, green: 0.560, blue: 0.145).opacity(0.20),
                controlFill: Color(red: 1.000, green: 0.985, blue: 0.930).opacity(0.90),
                controlFillSelected: Color(red: 0.780, green: 0.560, blue: 0.145).opacity(0.18),
                controlBorder: Color(red: 0.520, green: 0.380, blue: 0.100).opacity(0.24),
                border: Color(red: 0.410, green: 0.310, blue: 0.120).opacity(0.18),
                divider: Color(red: 0.420, green: 0.320, blue: 0.160).opacity(0.16),
                primaryAccent: Color(red: 0.560, green: 0.390, blue: 0.060),
                secondaryAccent: Color(red: 0.760, green: 0.560, blue: 0.165),
                storageAccent: Color(red: 0.510, green: 0.500, blue: 0.420),
                semanticSuccess: Color(red: 0.090, green: 0.480, blue: 0.290),
                semanticWarning: Color(red: 0.700, green: 0.420, blue: 0.000),
                semanticError: Color(red: 0.780, green: 0.180, blue: 0.165),
                semanticInfo: Color(red: 0.180, green: 0.390, blue: 0.610),
                semanticApproval: Color(red: 0.470, green: 0.340, blue: 0.060),
                semanticRunning: Color(red: 0.630, green: 0.430, blue: 0.090),
                semanticBlocked: Color(red: 0.780, green: 0.180, blue: 0.165),
                terminalBackground: Color(red: 0.150, green: 0.120, blue: 0.085),
                terminalText: Color(red: 0.980, green: 0.930, blue: 0.780),
                terminalPrompt: Color(red: 0.980, green: 0.760, blue: 0.260),
                terminalCommand: Color(red: 1.000, green: 0.880, blue: 0.520),
                terminalOutput: Color(red: 0.880, green: 0.800, blue: 0.630),
                terminalWarning: Color(red: 1.000, green: 0.730, blue: 0.240),
                terminalError: Color(red: 1.000, green: 0.470, blue: 0.390),
                terminalSelection: Color(red: 0.780, green: 0.560, blue: 0.145).opacity(0.28),
                codeBackground: Color(red: 0.140, green: 0.115, blue: 0.085),
                codeText: Color(red: 0.990, green: 0.955, blue: 0.850),
                codeKeyword: Color(red: 1.000, green: 0.760, blue: 0.230),
                codeString: Color(red: 0.660, green: 0.880, blue: 0.620),
                codeComment: Color(red: 0.690, green: 0.630, blue: 0.500),
                codeType: Color(red: 0.950, green: 0.620, blue: 0.260),
                codeCursor: Color(red: 1.000, green: 0.780, blue: 0.200),
                glassTint: Color.white.opacity(0.46),
                glassStroke: Color(red: 0.760, green: 0.560, blue: 0.165).opacity(0.28),
                glow: Color(red: 0.920, green: 0.680, blue: 0.220).opacity(0.34),
                shadow: Color(red: 0.280, green: 0.200, blue: 0.080).opacity(0.20),
                backgroundMotionOpacity: 0.22,
                glowRadius: 14
            )

        case .arcticGlass:
            AgentThemePalette(
                isLight: false,
                material: .arcticGlass,
                backgroundEffect: .arcticPrism,
                typography: .init(interfaceDesign: .rounded, displayDesign: .rounded, codeDesign: .monospaced),
                textPrimary: Color(red: 0.930, green: 0.985, blue: 1.000),
                textSecondary: Color(red: 0.700, green: 0.830, blue: 0.910),
                textTertiary: Color(red: 0.500, green: 0.650, blue: 0.760),
                textQuaternary: Color(red: 0.340, green: 0.470, blue: 0.590),
                backgroundA: Color(red: 0.012, green: 0.040, blue: 0.068),
                backgroundB: Color(red: 0.035, green: 0.095, blue: 0.145),
                backgroundC: Color(red: 0.080, green: 0.190, blue: 0.260),
                backgroundD: Color(red: 0.004, green: 0.018, blue: 0.035),
                surface: Color(red: 0.065, green: 0.135, blue: 0.190).opacity(0.86),
                surfaceElevated: Color(red: 0.095, green: 0.180, blue: 0.245).opacity(0.90),
                surfaceAlt: Color(red: 0.165, green: 0.420, blue: 0.560).opacity(0.26),
                row: Color(red: 0.075, green: 0.155, blue: 0.220).opacity(0.84),
                rowSelected: Color(red: 0.180, green: 0.850, blue: 1.000).opacity(0.18),
                controlFill: Color(red: 0.080, green: 0.170, blue: 0.240).opacity(0.84),
                controlFillSelected: Color(red: 0.180, green: 0.850, blue: 1.000).opacity(0.16),
                controlBorder: Color(red: 0.480, green: 0.920, blue: 1.000).opacity(0.23),
                border: Color(red: 0.600, green: 0.930, blue: 1.000).opacity(0.19),
                divider: Color(red: 0.540, green: 0.900, blue: 1.000).opacity(0.17),
                primaryAccent: Color(red: 0.300, green: 0.910, blue: 1.000),
                secondaryAccent: Color(red: 0.600, green: 0.760, blue: 1.000),
                storageAccent: Color(red: 0.600, green: 0.820, blue: 1.000),
                semanticSuccess: Color(red: 0.300, green: 0.890, blue: 0.670),
                semanticWarning: Color(red: 1.000, green: 0.790, blue: 0.340),
                semanticError: Color(red: 1.000, green: 0.410, blue: 0.520),
                semanticInfo: Color(red: 0.300, green: 0.910, blue: 1.000),
                semanticApproval: Color(red: 0.470, green: 0.780, blue: 1.000),
                semanticRunning: Color(red: 0.640, green: 0.820, blue: 1.000),
                semanticBlocked: Color(red: 1.000, green: 0.410, blue: 0.520),
                terminalBackground: Color(red: 0.010, green: 0.035, blue: 0.055),
                terminalText: Color(red: 0.850, green: 0.980, blue: 1.000),
                terminalPrompt: Color(red: 0.300, green: 0.910, blue: 1.000),
                terminalCommand: Color(red: 0.740, green: 0.930, blue: 1.000),
                terminalOutput: Color(red: 0.650, green: 0.800, blue: 0.880),
                terminalWarning: Color(red: 1.000, green: 0.790, blue: 0.340),
                terminalError: Color(red: 1.000, green: 0.410, blue: 0.520),
                terminalSelection: Color(red: 0.300, green: 0.910, blue: 1.000).opacity(0.24),
                codeBackground: Color(red: 0.012, green: 0.040, blue: 0.064),
                codeText: Color(red: 0.900, green: 0.985, blue: 1.000),
                codeKeyword: Color(red: 0.300, green: 0.910, blue: 1.000),
                codeString: Color(red: 0.560, green: 0.900, blue: 0.760),
                codeComment: Color(red: 0.480, green: 0.640, blue: 0.720),
                codeType: Color(red: 0.680, green: 0.780, blue: 1.000),
                codeCursor: Color(red: 0.580, green: 0.950, blue: 1.000),
                glassTint: Color(red: 0.120, green: 0.360, blue: 0.480).opacity(0.34),
                glassStroke: Color(red: 0.570, green: 0.920, blue: 1.000).opacity(0.25),
                glow: Color(red: 0.300, green: 0.910, blue: 1.000).opacity(0.36),
                shadow: Color(red: 0.000, green: 0.040, blue: 0.080).opacity(0.50),
                backgroundMotionOpacity: 0.28,
                glowRadius: 16
            )

        case .emberCore:
            AgentThemePalette(
                isLight: false,
                material: .emberGlass,
                backgroundEffect: .emberPulse,
                typography: .init(interfaceDesign: .rounded, displayDesign: .rounded, codeDesign: .monospaced),
                textPrimary: Color(red: 1.000, green: 0.940, blue: 0.890),
                textSecondary: Color(red: 0.820, green: 0.700, blue: 0.620),
                textTertiary: Color(red: 0.640, green: 0.500, blue: 0.430),
                textQuaternary: Color(red: 0.450, green: 0.350, blue: 0.310),
                backgroundA: Color(red: 0.045, green: 0.030, blue: 0.026),
                backgroundB: Color(red: 0.095, green: 0.050, blue: 0.036),
                backgroundC: Color(red: 0.180, green: 0.060, blue: 0.035),
                backgroundD: Color(red: 0.018, green: 0.014, blue: 0.013),
                surface: Color(red: 0.105, green: 0.070, blue: 0.058).opacity(0.88),
                surfaceElevated: Color(red: 0.150, green: 0.090, blue: 0.065).opacity(0.90),
                surfaceAlt: Color(red: 0.410, green: 0.130, blue: 0.050).opacity(0.26),
                row: Color(red: 0.135, green: 0.080, blue: 0.062).opacity(0.84),
                rowSelected: Color(red: 1.000, green: 0.380, blue: 0.120).opacity(0.18),
                controlFill: Color(red: 0.150, green: 0.088, blue: 0.064).opacity(0.85),
                controlFillSelected: Color(red: 1.000, green: 0.420, blue: 0.120).opacity(0.17),
                controlBorder: Color(red: 1.000, green: 0.520, blue: 0.200).opacity(0.22),
                border: Color(red: 1.000, green: 0.560, blue: 0.250).opacity(0.18),
                divider: Color(red: 1.000, green: 0.500, blue: 0.220).opacity(0.16),
                primaryAccent: Color(red: 1.000, green: 0.540, blue: 0.180),
                secondaryAccent: Color(red: 1.000, green: 0.250, blue: 0.170),
                storageAccent: Color(red: 0.950, green: 0.420, blue: 0.220),
                semanticSuccess: Color(red: 0.520, green: 0.900, blue: 0.450),
                semanticWarning: Color(red: 1.000, green: 0.620, blue: 0.150),
                semanticError: Color(red: 1.000, green: 0.280, blue: 0.220),
                semanticInfo: Color(red: 1.000, green: 0.540, blue: 0.180),
                semanticApproval: Color(red: 1.000, green: 0.680, blue: 0.240),
                semanticRunning: Color(red: 1.000, green: 0.430, blue: 0.160),
                semanticBlocked: Color(red: 1.000, green: 0.250, blue: 0.170),
                terminalBackground: Color(red: 0.035, green: 0.025, blue: 0.022),
                terminalText: Color(red: 1.000, green: 0.880, blue: 0.760),
                terminalPrompt: Color(red: 1.000, green: 0.540, blue: 0.180),
                terminalCommand: Color(red: 1.000, green: 0.740, blue: 0.420),
                terminalOutput: Color(red: 0.860, green: 0.700, blue: 0.590),
                terminalWarning: Color(red: 1.000, green: 0.620, blue: 0.150),
                terminalError: Color(red: 1.000, green: 0.300, blue: 0.220),
                terminalSelection: Color(red: 1.000, green: 0.420, blue: 0.120).opacity(0.24),
                codeBackground: Color(red: 0.045, green: 0.030, blue: 0.026),
                codeText: Color(red: 1.000, green: 0.910, blue: 0.820),
                codeKeyword: Color(red: 1.000, green: 0.540, blue: 0.180),
                codeString: Color(red: 0.980, green: 0.820, blue: 0.420),
                codeComment: Color(red: 0.650, green: 0.490, blue: 0.400),
                codeType: Color(red: 1.000, green: 0.360, blue: 0.280),
                codeCursor: Color(red: 1.000, green: 0.630, blue: 0.200),
                glassTint: Color(red: 0.340, green: 0.110, blue: 0.040).opacity(0.38),
                glassStroke: Color(red: 1.000, green: 0.530, blue: 0.220).opacity(0.24),
                glow: Color(red: 1.000, green: 0.360, blue: 0.120).opacity(0.44),
                shadow: Color.black.opacity(0.48),
                backgroundMotionOpacity: 0.32,
                glowRadius: 18
            )
        }
    }
}

enum AgentThemeMaterial: String, CaseIterable {
    case codeGlass
    case blackGlass
    case lightLuxuryGlass
    case arcticGlass
    case emberGlass
}

enum AgentThemeBackgroundEffect: String, CaseIterable {
    case matrixRain
    case midnightDepth
    case whiteGoldVeil
    case arcticPrism
    case emberPulse
}

struct AgentThemeTypography {
    let interfaceDesign: Font.Design
    let displayDesign: Font.Design
    let codeDesign: Font.Design
}

struct AgentThemePalette {
    let isLight: Bool
    let material: AgentThemeMaterial
    let backgroundEffect: AgentThemeBackgroundEffect
    let typography: AgentThemeTypography
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textQuaternary: Color
    let backgroundA: Color
    let backgroundB: Color
    let backgroundC: Color
    let backgroundD: Color
    let surface: Color
    let surfaceElevated: Color
    let surfaceAlt: Color
    let row: Color
    let rowSelected: Color
    let controlFill: Color
    let controlFillSelected: Color
    let controlBorder: Color
    let border: Color
    let divider: Color
    let primaryAccent: Color
    let secondaryAccent: Color
    let storageAccent: Color
    let semanticSuccess: Color
    let semanticWarning: Color
    let semanticError: Color
    let semanticInfo: Color
    let semanticApproval: Color
    let semanticRunning: Color
    let semanticBlocked: Color
    let terminalBackground: Color
    let terminalText: Color
    let terminalPrompt: Color
    let terminalCommand: Color
    let terminalOutput: Color
    let terminalWarning: Color
    let terminalError: Color
    let terminalSelection: Color
    let codeBackground: Color
    let codeText: Color
    let codeKeyword: Color
    let codeString: Color
    let codeComment: Color
    let codeType: Color
    let codeCursor: Color
    let glassTint: Color
    let glassStroke: Color
    let glow: Color
    let shadow: Color
    let backgroundMotionOpacity: Double
    let glowRadius: CGFloat

    var cyan: Color { backgroundEffect == .matrixRain ? semanticInfo : primaryAccent }
    var lilac: Color { backgroundEffect == .matrixRain ? semanticRunning : secondaryAccent }
    var green: Color { backgroundEffect == .matrixRain ? semanticSuccess : primaryAccent }
    var rose: Color { semanticError }
}

@MainActor
enum AgentThemeUIKit {
    static func apply(_ theme: AgentTheme = AgentTheme.current) {
        let palette = theme.palette
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: palette.isLight ? .systemUltraThinMaterialLight : .systemUltraThinMaterialDark)
        appearance.backgroundColor = .clear
        appearance.shadowColor = UIColor(palette.border).withAlphaComponent(theme == .matrixRain ? 0.55 : 0.34)
        let selectedTint = palette.textPrimary

        let item = UITabBarItemAppearance(style: .stacked)
        item.normal.iconColor = UIColor(palette.textTertiary)
        let normalFont: UIFont
        let selectedFont: UIFont
        if theme == .matrixRain {
            normalFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            selectedFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        } else {
            normalFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
            selectedFont = UIFont.systemFont(ofSize: 12, weight: .bold)
        }

        item.normal.titleTextAttributes = [
            .foregroundColor: UIColor(palette.textTertiary),
            .font: normalFont
        ]
        item.selected.iconColor = UIColor(selectedTint)
        item.selected.titleTextAttributes = [
            .foregroundColor: UIColor(selectedTint),
            .font: selectedFont
        ]

        for state in [item.normal, item.selected, item.disabled, item.focused] {
            state.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -2)
        }

        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().tintColor = UIColor(selectedTint)
        UITabBar.appearance().unselectedItemTintColor = UIColor(palette.textTertiary)
        UITabBar.appearance().backgroundColor = .clear
        UITabBar.appearance().barTintColor = .clear
        UITabBar.appearance().isTranslucent = true
    }
}
