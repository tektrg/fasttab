import SwiftUI

extension View {
    /// macOS greys a window's buttons while that window isn't the active one. The corner card is often
    /// not active, so its Send looked grey while the main panel's was in the accent colour. Card send
    /// buttons draw as active everywhere so both surfaces look the same.
    func keepsColorWhenInactive() -> some View {
        environment(\.controlActiveState, .key)
    }
}
