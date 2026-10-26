// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "ListLens",
	platforms: [.iOS("17.2"), .macOS(.v14)],
	products: [
		.library(name: "ListLensCore", targets: ["ListLensCore"]),
		.library(name: "ListLensGlasses", targets: ["ListLensGlasses"]),
		.executable(name: "listlens-replay", targets: ["listlens-replay"])
	],
	dependencies: [
		.package(url: "https://github.com/facebook/meta-wearables-dat-ios", exact: "1.0.1")
	],
	targets: [
		.target(name: "ListLensCore"),
		.target(
			name: "ListLensGlasses",
			dependencies: [
				"ListLensCore",
				.product(name: "MWDATCore", package: "meta-wearables-dat-ios", condition: .when(platforms: [.iOS])),
				.product(name: "MWDATCamera", package: "meta-wearables-dat-ios", condition: .when(platforms: [.iOS])),
				.product(name: "MWDATDisplay", package: "meta-wearables-dat-ios", condition: .when(platforms: [.iOS]))
			]
		),
		.executableTarget(name: "listlens-replay", dependencies: ["ListLensCore"]),
		.testTarget(name: "ListLensCoreTests", dependencies: ["ListLensCore"])
	]
)
