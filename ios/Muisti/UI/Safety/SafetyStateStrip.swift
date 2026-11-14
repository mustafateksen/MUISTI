import SwiftUI

/// What Muisti last saw of each watched object, as a sideways strip of photo tiles that runs
/// to the screen edges.
struct SafetyStateStrip: View {
    let states: [ObjectState]
    let frameURL: (String) -> URL

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: Theme.Spacing.s) {
                ForEach(states, id: \.object) { state in
                    SafetyStateTile(state: state, url: state.evidenceFrame.map(frameURL))
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, SafetyView.margin, for: .scrollContent)
        .padding(.horizontal, -SafetyView.margin)
    }
}
