import SwiftUI
import UsageCore

/// The small icon-and-label heading at the top of every module.
struct CardTitle: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct StatTile: View {
    let label: String
    let systemImage: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CardTitle(label, systemImage: systemImage)
            MorphingText(value)
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Layout.modulePadding)
        .padding(.vertical, 13)
        .module(cornerRadius: Theme.Layout.tileRadius)
    }
}

/// A value whose characters morph into their replacements when it changes: each character that
/// changes blurs and shrinks away while the new one sharpens in over it, and the rest stay put.
/// Characters are matched from the right, so units stay over units as a number grows. Text with a word
/// in it, such as a model's name, morphs as one piece. The morph redraws the glyphs every frame, which
/// is fine for values that change on a switch or a refresh; text that follows the pointer cross-fades
/// instead.
struct MorphingText: View {
    let text: String

    /// How far text shrinks to fit before it's cut off.
    fileprivate static let minimumScale: CGFloat = 0.7

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Holds a full line's height, so text shrunk to fit doesn't make its tile shorter than its
            // neighbors.
            Text(" ")
                .hidden()
            // Changing a word letter by letter would scramble it.
            if text.contains(/\p{L}{3}/) {
                Text(text)
                    .lineLimit(1)
                    .minimumScaleFactor(Self.minimumScale)
                    .id(text)
                    .transition(.morph)
            } else {
                Glyphs(text: text)
                    .transition(.morph)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.Motion.morph, value: text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A number's characters side by side, each morphing on its own, shrunk to fit its space.
private struct Glyphs: View {
    let text: String

    @State private var width: CGFloat = 0
    @State private var room: CGFloat = .infinity

    private struct Place: Identifiable {
        /// Counted from the right.
        let id: Int
        let character: Character
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(places) { place in
                Glyph(character: place.character)
                    .transition(.morph)
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            // Fits the first value straight away; a later one that needs a different size eases into it.
            withAnimation(width == 0 ? nil : Theme.Motion.morph) { width = newWidth }
        }
        .scaleEffect(scale, anchor: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
    }

    private var places: [Place] {
        text.reversed().enumerated().map { Place(id: $0.offset, character: $0.element) }.reversed()
    }

    private var scale: CGFloat {
        width > room ? max(room / width, MorphingText.minimumScale) : 1
    }
}

/// One character, morphing into its replacement in place. Its width eases to the new character's, with
/// both drawn centered over it.
private struct Glyph: View {
    let character: Character

    var body: some View {
        Text(String(character))
            .hidden()
            .overlay {
                Text(String(character))
                    .fixedSize()
                    .id(character)
                    .transition(.morph)
            }
    }
}

/// Text part-way through morphing away, 0 being fully shown and 1 gone. Opacity falls with the square
/// of progress, so where a character crosses its replacement both are still bright and read as one
/// shape turning into the other, not a fade through gray.
private struct Morph: ViewModifier, Animatable {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // A spring carries progress a little past either end. Only the scale follows it there, so a
        // character arriving pops past full size rather than dimming or blurring again.
        let faded = min(max(progress, 0), 1)
        content
            .blur(radius: 4 * faded)
            .scaleEffect(1 - 0.15 * progress)
            .opacity(1 - faded * faded)
    }
}

private extension AnyTransition {
    static var morph: AnyTransition {
        .modifier(active: Morph(progress: 1), identity: Morph(progress: 0))
    }
}

/// Text that cross-fades when it changes. Old and new are separate layers faded by the GPU, so it keeps
/// up with text that changes as the pointer moves.
struct CrossfadeText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Holds a full line's height, so text shrunk to fit (or empty) doesn't make its tile or the
            // footer shorter than its neighbors.
            Text(" ")
                .hidden()
            Text(text)
                .id(text)
                // The old text clears out faster than the new one arrives, so they barely overlap.
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(Theme.Motion.textOut)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A capsule of glass holding a few choices, the selected one lifted out on a lighter pill that slides
/// between them.
struct GlassSegmentedControl<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    @Namespace private var namespace

    init(_ label: String, selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        self.label = label
        _selection = selection
        self.options = options
        self.title = title
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(Theme.Motion.select) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.primary.opacity(0.16))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { Text(title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// A small round button face that brightens under the pointer, like the AirPlay button in Control
/// Center's Sound module. Drawn here rather than by a button style, which gives menus a smaller circle
/// than buttons.
struct CircleIcon: View {
    let systemImage: String
    var size: CGFloat = 30

    @State private var hovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: size, height: size)
            .background(Circle().fill(.primary.opacity(hovering ? 0.2 : 0.1)))
            .contentShape(.circle)
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
    }
}

/// Presses sink a little and spring back. Only for buttons without glass of their own.
struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// Dips and bounces back each time `trigger` changes.
struct Pop<Trigger: Equatable & Sendable>: ViewModifier {
    let trigger: Trigger

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(0.84, duration: 0.09)
            SpringKeyframe(1, duration: 0.5, spring: Spring(duration: 0.5, bounce: 0.55))
        }
    }
}

/// The logos of the providers that are on, in a capsule of glass. The selected one is lifted out on a
/// pill with its name; providers without history on this Mac are dimmed. A logo pops when it's clicked.
struct ProviderPicker: View {
    @Binding var selection: Provider?
    let providers: [Provider]
    let available: Set<Provider>

    @Namespace private var namespace
    /// Counts clicks on each logo, which pop it.
    @State private var clicks: [Provider?: Int] = [:]

    var body: some View {
        HStack(spacing: 0) {
            item(nil)
            ForEach(providers) { item($0) }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .accessibilityRepresentation {
            Picker("Provider", selection: $selection) {
                Text("All Providers").tag(Provider?.none)
                ForEach(providers) { Text($0.name).tag(Provider?.some($0)) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func item(_ provider: Provider?) -> some View {
        let selected = provider == selection
        let hasData = provider.map(available.contains) ?? true
        return Button {
            clicks[provider, default: 0] += 1
            withAnimation(Theme.Motion.select) { selection = provider }
        } label: {
            HStack(spacing: 6) {
                ProviderIcon(provider: provider, size: 16)
                    .opacity(hasData || selected ? 1 : 0.35)
                    .modifier(Pop(trigger: clicks[provider, default: 0]))
                if selected {
                    // The old name goes at once and the new one fades in as the pill slides over, so
                    // the two never overlap.
                    Text(provider?.name ?? "All")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -4)), removal: .identity))
                }
            }
            .padding(.horizontal, selected ? 12 : 0)
            .frame(maxWidth: selected ? nil : .infinity)
            .frame(height: 28)
            .background {
                if selected {
                    Capsule()
                        .fill(.primary.opacity(0.16))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(provider?.name ?? "All Providers")
    }
}

/// Lays its views out in rows like words in a paragraph, wrapping to a new row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(subviews, width: bounds.width).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

/// Stacks its views at the top, like a `ZStack`, but takes the size of only the one in view. The size
/// follows in the same layout pass as the content, so nothing waits a frame for a measurement.
struct ShownLayout: Layout {
    var shown: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        return subviews[min(shown, subviews.count - 1)].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// A vertical scroll view as tall as its content, up to `maxHeight`. Its height is worked out with the
/// content's, so it grows and shrinks in step with rows animating in and out.
struct CappedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    /// Fades content out at an edge it continues past. Off for content that is itself glass, which
    /// a mask would cut rather than fade.
    var fadesEdges = true
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .modifier(ScrollEdgeFade(enabled: fadesEdges))
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Fades a scroll view's content out at the edges it continues past, which shows there's more without
/// a scroller. With a mouse connected, macOS draws legacy scrollers that sit on top of the glass and run
/// past its rounded corners, so the panel's lists hide them and fade instead.
struct ScrollEdgeFade: ViewModifier {
    var enabled = true
    var length: CGFloat = 16
    @State private var edges = Edges()

    struct Edges: Equatable {
        var top = false
        var bottom = false
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onScrollGeometryChange(for: Edges.self) { geometry in
                    let offset = geometry.contentOffset.y + geometry.contentInsets.top
                    let overflow = geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom - geometry.containerSize.height
                    return Edges(top: offset > 0.5, bottom: offset < overflow - 0.5)
                } action: { _, new in
                    edges = new
                }
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(edges.top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: length)
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(edges.bottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: length)
                    }
                    .animation(Theme.Motion.hover, value: edges)
                }
        } else {
            content
        }
    }
}
