import SwiftUI

// ═══════════════════════════════════════════════════════
// Design tokens — matching Flutter "Paytin" palette
// ═══════════════════════════════════════════════════════
struct FTheme {
    // Core palette
    static let background   = Color(red: 0.95, green: 0.97, blue: 0.91)   // #F2F7E8 warm cream-lime
    static let foreground   = Color(red: 0.10, green: 0.18, blue: 0.10)   // #1A2E1A deep forest text
    static let ink          = Color(red: 0.12, green: 0.20, blue: 0.13)   // #1E3320 dark green cards
    static let primary      = Color(red: 0.72, green: 0.90, blue: 0.21)   // #B8E636 lime accent
    static let primaryGlow  = Color(red: 0.83, green: 0.96, blue: 0.48)   // #D4F47A lighter lime
    static let card         = Color.white
    static let muted        = Color(red: 0.42, green: 0.48, blue: 0.42)   // #6B7B6B muted text
    static let success      = Color(red: 0.29, green: 0.87, blue: 0.50)   // #4ADE80 green
    static let border       = Color(red: 0.12, green: 0.20, blue: 0.13).opacity(0.1)
    static let destructive  = Color(red: 0.94, green: 0.27, blue: 0.27)   // #EF4444
    static let secondaryBg  = Color(red: 0.94, green: 0.96, blue: 0.89)   // #F0F5E4 light lime card bg
}

// ── Stat Tile Helper ──
struct StatTile: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
                .tracking(1)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
    }
}

// ── Rounded Shape Helper ──
struct RoundedShape: Shape {
    var corners: UIRectCorner
    var radius: CGFloat
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
