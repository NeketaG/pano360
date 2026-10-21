import SwiftUI

extension Color {
    /// Акцентный цвет приложения — холодный голубой, как небо на панорамах.
    static let panoAccent = Color(red: 0.38, green: 0.78, blue: 1.0)
}

extension View {
    /// Главная кнопка экрана: Liquid Glass на iOS 26, обычная заливка на старых версиях.
    @ViewBuilder
    func primaryActionStyle() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glassProminent).controlSize(.extraLarge)
        } else {
            self.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    /// Второстепенная кнопка экрана.
    @ViewBuilder
    func secondaryActionStyle() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glass).controlSize(.extraLarge)
        } else {
            self.buttonStyle(.bordered).controlSize(.large)
        }
    }

    /// Стеклянная подложка; на iOS до 26 — полупрозрачный материал той же формы.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Группа стеклянных элементов. Стекло не умеет "отражать" соседнее стекло,
/// поэтому кнопки одной панели должны жить в общем контейнере.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Круглая стеклянная кнопка с иконкой — для панелей поверх камеры и панорамы.
struct GlassIconButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 54, height: 54)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle(), interactive: true)
        .accessibilityLabel(title)
    }
}

/// Медленно плывущая по кругу панорама — фон главного экрана. Equirectangular-кадр
/// бесшовно замыкается по горизонтали, поэтому две копии подряд дают бесконечную ленту.
struct PanoramaBackdrop: View {
    let image: UIImage
    var speed: Double = 14 // точек в секунду

    var body: some View {
        GeometryReader { geo in
            // Берём только среднюю полосу панорамы: полюса сильно растянуты и некрасивы.
            let height = geo.size.height * 1.5
            let width = height * 2
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate * speed
                let offset = CGFloat(elapsed.truncatingRemainder(dividingBy: Double(width)))
                HStack(spacing: 0) {
                    Image(uiImage: image).resizable().frame(width: width, height: height)
                    Image(uiImage: image).resizable().frame(width: width, height: height)
                }
                .offset(x: -offset, y: (geo.size.height - height) / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
