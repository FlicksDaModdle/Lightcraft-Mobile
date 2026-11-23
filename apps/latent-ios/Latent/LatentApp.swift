import SwiftUI

@main
struct LatentApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}
