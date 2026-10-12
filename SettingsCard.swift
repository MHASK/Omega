import SwiftUI

struct SettingsCard<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String?
    let scale: CGFloat
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    init(_ title: String, subtitle: String? = nil, scale: CGFloat, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title=title;self.subtitle=subtitle;self.scale=scale;self.content=content();self.footer=footer()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5 * scale) {
                Text(title).font(.system(size: 12 * scale, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 10 * scale)).foregroundStyle(Color(nsColor: Ink.muted)).fixedSize(horizontal: false, vertical: true).lineSpacing(2 * scale) }
            }.padding(.horizontal, 17 * scale).padding(.vertical, 13 * scale).frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color(nsColor: Ink.separator).opacity(0.65)).frame(height: 1)
            VStack(alignment: .leading, spacing: 12 * scale) { content }.padding(17 * scale).frame(maxWidth: .infinity, alignment: .leading)
            if Footer.self != EmptyView.self {
                Rectangle().fill(Color(nsColor: Ink.separator).opacity(0.65)).frame(height: 1)
                footer.font(.system(size: 10 * scale)).padding(.horizontal, 17 * scale).padding(.vertical, 11 * scale).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: Ink.sidebar).opacity(0.2))
            }
        }
        .background(Color(nsColor: Ink.sidebar).opacity(0.28), in: RoundedRectangle(cornerRadius: 7 * scale))
        .clipShape(RoundedRectangle(cornerRadius: 7 * scale))
        .overlay(RoundedRectangle(cornerRadius: 7 * scale).stroke(Color(nsColor: Ink.separator).opacity(0.85), lineWidth: 1))
    }
}
extension SettingsCard where Footer == EmptyView {
    init(_ title: String, subtitle: String? = nil, scale: CGFloat, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, scale: scale, content: content, footer: { EmptyView() })
    }
}
