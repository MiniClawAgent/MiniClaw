import SwiftUI
import UIKit

/// Opaque rounded-card preview shownText under a message's long-press context menu.
///
/// The message cells are hosted with a
///
///
/// The earlier version hard-capped
struct MessageContextMenuPreview: View {
    let text: String

    /// Width is now a CAP, not a fixed
    private let maxCardWidth: CGFloat = 360
    private var maxCardHeight: CGFloat { UIScreen.main.bounds.height*0.55 }

    @State private var contentSize: CGSize = .zero

    var body: some View {
        let shownText = text.isEmpty ? " " : text
        ScrollView(.vertical,showsIndicators: true) {
            Text(shownText)
                .font(.system(size: FontSettings.shared.scaledMessage(16.5)))
                .foregroundStyle(ChatColors.primaryText)
                .multilineTextAlignment(.leading)
                .padding(16)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: PreviewContentSizeKey.self,value: geo.size)
                    }
                )
        }
        .onPreferenceChange(PreviewContentSizeKey.self) { contentSize = $0 }
        .frame(
            width: contentSize.width>0 ? min(max(contentSize.width,60),maxCardWidth) : maxCardWidth,
            height: contentSize.height>0 ? min(contentSize.height,maxCardHeight) : maxCardHeight
        )
        .background(ChatColors.background)
    }
}

private struct PreviewContentSizeKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize,nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width,next.width),height: max(value.height,next.height))
    }
}
