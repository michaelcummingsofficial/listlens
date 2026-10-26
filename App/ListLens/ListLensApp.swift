import ListLensGlasses
import SwiftUI

@main
struct ListLensApp: App {
	@State private var model: AppModel

	init() {
		GlassesLink.configure()
		_model = State(initialValue: AppModel())
	}

	var body: some Scene {
		WindowGroup {
			ContentView(model: model)
				.onOpenURL { url in
					Task { await model.glasses.handle(url) }
				}
		}
	}
}
