import ListLensCore
import ListLensGlasses
import MWDATCore
import SwiftUI

struct ContentView: View {
	@Bindable var model: AppModel
	@State private var newItem = ""
	@State private var showingSettings = false
	@FocusState private var addingItem: Bool

	var body: some View {
		NavigationStack {
			List {
				glassesSection
				shoppingSection
				listSection
				if !model.log.isEmpty {
					logSection
				}
			}
			.navigationTitle("ListLens")
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						showingSettings = true
					} label: {
						Image(systemName: "gearshape")
					}
					.accessibilityLabel("Settings")
				}
			}
			.sheet(isPresented: $showingSettings) {
				SettingsView(apiKey: $model.apiKey, drawsOnGlasses: $model.drawsOnGlasses)
			}
			.alert("Something went wrong", isPresented: Binding(
				get: { model.errorMessage != nil },
				set: { if !$0 { model.errorMessage = nil } }
			)) {
				Button("OK") {}
			} message: {
				Text(model.errorMessage ?? "")
			}
		}
	}

	@ViewBuilder private var glassesSection: some View {
		Section("Glasses") {
			if model.glasses.registration == .registered {
				Label(glassesStatus, systemImage: "eyeglasses")
			} else {
				Button {
					Task {
						do {
							try await model.glasses.register()
						} catch {
							model.errorMessage = error.localizedDescription
						}
					}
				} label: {
					Label("Connect your glasses", systemImage: "eyeglasses")
				}
				.disabled(model.glasses.registration == .registering)
			}
		}
	}

	private var glassesStatus: String {
		switch model.glasses.phase {
		case .idle: model.glasses.hasActiveDevice ? "Ready" : "Put on your glasses"
		case .connecting: "Connecting…"
		case .streaming: model.glasses.isDisplayReady ? "Watching, display on" : "Watching"
		case .failed(let message): message
		}
	}

	@ViewBuilder private var shoppingSection: some View {
		Section {
			#if DEBUG
			if let mock = MockGlasses.glasses {
				MockDisplayPreview(glasses: mock)
					.aspectRatio(1, contentMode: .fit)
					.clipShape(RoundedRectangle(cornerRadius: 12))
					.accessibilityHidden(true)
			}
			#endif
			if model.isShopping {
				if let preview = model.preview {
					Image(uiImage: preview)
						.resizable()
						.scaledToFit()
						.frame(maxHeight: 260)
						.clipShape(RoundedRectangle(cornerRadius: 12))
						.overlay(alignment: .bottomLeading) {
							if let held = model.held {
								Text("In hand: \(held.name)")
									.font(.callout.weight(.semibold))
									.padding(.horizontal, 10)
									.padding(.vertical, 6)
									.background(.ultraThinMaterial, in: Capsule())
									.padding(10)
							}
						}
						.accessibilityLabel(model.held.map { "Glasses camera. In hand: \($0.name)" } ?? "Glasses camera")
				}
				if let check = model.lastCheckOff {
					HStack {
						Label("Checked off \(check.name)", systemImage: "checkmark.circle.fill")
							.foregroundStyle(.green)
						Spacer()
						Button("Undo") {
							Task { await model.undo(check.itemID) }
						}
					}
					.accessibilityElement(children: .combine)
				}
				Text(stats)
					.font(.footnote.monospacedDigit())
					.foregroundStyle(.secondary)
			}
			Button {
				Task {
					if model.isShopping {
						await model.stopShopping()
					} else {
						await model.startShopping()
					}
				}
			} label: {
				Label(model.isShopping ? "Stop" : "Start shopping", systemImage: model.isShopping ? "stop.fill" : "cart")
					.frame(maxWidth: .infinity)
					.font(.headline)
			}
			.buttonStyle(.borderedProminent)
			.tint(model.isShopping ? .red : .accentColor)
			.disabled(model.glasses.registration != .registered && !model.isShopping)
			.listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
		}
	}

	private var stats: String {
		let latency = model.medianLatency.map { String(format: " · %.1f s typical", $0) } ?? ""
		return String(format: "%d frames judged · $%.3f", model.calls, model.cost) + latency
	}

	@ViewBuilder private var listSection: some View {
		Section {
			TextField("List name", text: $model.listTitle)
				.font(.headline)
			ForEach(model.items) { item in
				Button {
					Task { await model.setChecked(item.id, !item.isChecked) }
				} label: {
					Label {
						Text(item.name)
							.strikethrough(item.isChecked)
							.foregroundStyle(item.isChecked ? .secondary : .primary)
					} icon: {
						Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
							.foregroundStyle(item.isChecked ? .green : .secondary)
					}
				}
				.accessibilityLabel(item.name)
				.accessibilityValue(item.isChecked ? "Checked" : "Not checked")
			}
			.onDelete { model.items.remove(atOffsets: $0) }
			.deleteDisabled(model.isShopping)
			if !model.isShopping {
				TextField("Add an item", text: $newItem)
					.focused($addingItem)
					.submitLabel(.done)
					.onSubmit {
						model.addItem(newItem)
						newItem = ""
						addingItem = true
					}
			}
		} header: {
			Text("\(model.remaining) left")
		} footer: {
			if !model.isShopping && model.remaining < model.items.count {
				Button("Uncheck all") { model.uncheckAll() }
			}
		}
	}

	@ViewBuilder private var logSection: some View {
		Section {
			ForEach(model.log.prefix(60)) { line in
				Text(line.text)
					.font(line.isEvent ? .footnote.weight(.semibold) : .caption.monospaced())
					.foregroundStyle(line.isEvent ? .primary : .secondary)
			}
		} header: {
			Text("What the model sees")
		} footer: {
			Text("Every trip is saved with its frames, video and log in Files › On My iPhone › ListLens › trips.")
		}
	}
}

private struct SettingsView: View {
	@Binding var apiKey: String
	@Binding var drawsOnGlasses: Bool
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			Form {
				Section {
					SecureField("Meta Model API key", text: $apiKey)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				} footer: {
					Text("ListLens sends glasses frames to Muse Spark with this key. Create one at dev.meta.ai under API keys. It stays in this phone's keychain.")
				}
				Section {
					Toggle("Show the list on the glasses", isOn: $drawsOnGlasses)
				} footer: {
					Text("Turn this off to keep another list app on the glasses display while ListLens watches the camera.")
				}
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { dismiss() }
				}
			}
		}
	}
}
