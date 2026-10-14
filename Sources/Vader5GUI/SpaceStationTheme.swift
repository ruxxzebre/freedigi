import SwiftUI

enum SpaceStationTheme {
    static let darkest = Color(red: 0x18 / 255, green: 0x18 / 255, blue: 0x18 / 255)
    static let secondDark = Color(red: 0x1C / 255, green: 0x1D / 255, blue: 0x1F / 255)
    static let thirdDark = Color(red: 0x21 / 255, green: 0x22 / 255, blue: 0x25 / 255)
    static let option = Color(red: 0x26 / 255, green: 0x27 / 255, blue: 0x2A / 255)
    static let line = Color(red: 0x2E / 255, green: 0x30 / 255, blue: 0x35 / 255)
    static let accent = Color(red: 0x3E / 255, green: 0x95 / 255, blue: 1)
    static let secondaryText = Color(red: 0x9C / 255, green: 0xA3 / 255, blue: 0xAC / 255)

    static let smallRadius = 8.0
    static let mediumRadius = 12.0
    static let sectionSpacing = 24.0
}

struct ConfigurationCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let content: Content

    init(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SpaceStationTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(SpaceStationTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpaceStationTheme.thirdDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(SpaceStationTheme.line))
    }
}
