import SwiftUI

/// 색상 테마: 앱의 강조색(고른 단추·제목·재생 단추·표시 등). 5가지 단색 + 2가지 그라데이션
enum AppTheme: String, CaseIterable, Identifiable {
    case orange, mocha, teal, lavender, cherry, aurora, ocean
    var id: String { rawValue }

    var name: String {
        switch self {
        case .orange: "시그니처 오렌지"
        case .mocha: "모카 무스"
        case .teal: "트랜스포머티브 틸"
        case .lavender: "디지털 라벤더"
        case .cherry: "체리 레드"
        case .aurora: "오로라"
        case .ocean: "오션 브리즈"
        }
    }

    var note: String {
        switch self {
        case .orange: "MyTube 기본 색"
        case .mocha: "부드러운 브라운, 2025 올해의 색"
        case .teal: "깊은 청록, 2026 트렌드 색"
        case .lavender: "차분한 디지털 보라"
        case .cherry: "선명한 체리 빨강"
        case .aurora: "보라 → 분홍 그라데이션"
        case .ocean: "민트 → 파랑 그라데이션"
        }
    }

    /// 색 (2개 이상이면 그라데이션)
    var colors: [Color] {
        switch self {
        case .orange: [Color(red: 1.00, green: 0.48, blue: 0.10)]
        case .mocha: [Color(red: 0.64, green: 0.47, blue: 0.39)]
        case .teal: [Color(red: 0.10, green: 0.56, blue: 0.56)]
        case .lavender: [Color(red: 0.58, green: 0.50, blue: 0.90)]
        case .cherry: [Color(red: 0.84, green: 0.14, blue: 0.24)]
        case .aurora: [Color(red: 0.48, green: 0.36, blue: 1.00), Color(red: 0.84, green: 0.36, blue: 0.86), Color(red: 1.00, green: 0.40, blue: 0.62)]
        case .ocean: [Color(red: 0.00, green: 0.78, blue: 0.66), Color(red: 0.13, green: 0.60, blue: 0.95), Color(red: 0.25, green: 0.42, blue: 1.00)]
        }
    }

    var isGradient: Bool { colors.count > 1 }

    /// 단색으로 써야 하는 곳(옅은 바탕·슬라이더 등)의 색: 그라데이션이면 가운데 색
    var accent: Color { colors[colors.count / 2] }

    /// 글자·아이콘·채우기에 쓰는 모양 (그라데이션 테마는 그라데이션)
    var style: AnyShapeStyle {
        isGradient
            ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(colors[0])
    }
}

/// 고른 테마 (다음 실행에도 유지)
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published var current = AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .orange {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: "theme") }
    }

    /// 화면 모드: 시스템 설정 따르기 / 늘 밝게 / 늘 어둡게
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { self == .system ? "시스템 따라" : self == .light ? "밝게" : "어둡게" }
        var icon: String { self == .system ? "circle.lefthalf.filled" : self == .light ? "sun.max" : "moon" }
    }

    @Published var appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    private init() { applyAppearance() }

    func applyAppearance() {
        NSApp?.appearance = appearance == .system ? nil : NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.orange
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// 창의 맨 바깥에 붙여 테마를 아래 화면 전체에 전함
struct ThemedRoot: ViewModifier {
    @ObservedObject private var store = ThemeStore.shared

    func body(content: Content) -> some View {
        content
            .environment(\.theme, store.current)
            .tint(store.current.accent)
    }
}

extension View {
    func themed() -> some View { modifier(ThemedRoot()) }
}
