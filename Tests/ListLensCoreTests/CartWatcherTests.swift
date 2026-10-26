import ListLensCore
import Testing

private func frame(_ time: Double, _ state: HandState, _ itemID: String? = nil, seen: String = "") -> FrameVerdict {
	FrameVerdict(time: time, state: state, seen: seen, itemID: itemID)
}

@Test func checksOffOnceTheItemHasLeftTheHand() {
	var watcher = CartWatcher()
	#expect(watcher.ingest(frame(5, .holding, "eggs", seen: "365 eggs")) == [.holding(itemID: "eggs", seen: "365 eggs")])
	#expect(watcher.ingest(frame(10, .intoCart, "eggs", seen: "365 eggs")) == [])
	#expect(watcher.ingest(frame(10.33, .empty)) == [.checkedOff(itemID: "eggs", seen: "365 eggs")])
}

@Test func aCartonHeldOpenOverTheBasketIsNotADrop() {
	var watcher = CartWatcher()
	_ = watcher.ingest(frame(7, .holding, "eggs"))
	#expect(watcher.ingest(frame(7.33, .intoCart, "eggs")) == [])
	#expect(watcher.ingest(frame(8.33, .holding, "eggs")) == [])
	#expect(watcher.ingest(frame(12.33, .intoCart, "eggs")) == [])
	#expect(watcher.ingest(frame(12.66, .empty)) == [.checkedOff(itemID: "eggs", seen: "")])
}

@Test func twoDropFramesConfirmEachOther() {
	var watcher = CartWatcher()
	#expect(watcher.ingest(frame(9, .intoCart, "spinach")) == [])
	#expect(watcher.ingest(frame(9.33, .intoCart, "spinach")) == [.checkedOff(itemID: "spinach", seen: "")])
	#expect(watcher.ingest(frame(9.66, .empty)) == [])
}

@Test func samplesFasterWhileSomethingIsHeldOrLanding() {
	var watcher = CartWatcher()
	#expect(watcher.nextInterval == 1)
	_ = watcher.ingest(frame(5, .holding, "eggs"))
	#expect(watcher.nextInterval < 1)
	_ = watcher.ingest(frame(6, .intoCart, "eggs"))
	#expect(watcher.nextInterval < 1)
	_ = watcher.ingest(frame(6.33, .empty))
	#expect(watcher.nextInterval == 1)
}

@Test func usesTheHeldItemWhenTheDropFrameMissesTheMatch() {
	var watcher = CartWatcher()
	_ = watcher.ingest(frame(4, .holding, "beef", seen: "365 ground beef"))
	_ = watcher.ingest(frame(9, .intoCart, nil))
	#expect(watcher.ingest(frame(9.33, .empty)) == [.checkedOff(itemID: "beef", seen: "365 ground beef")])
}

@Test func aLandingWithNoFollowUpExpires() {
	var watcher = CartWatcher()
	_ = watcher.ingest(frame(9, .intoCart, "spinach"))
	#expect(watcher.ingest(frame(20, .empty)) == [])
}

@Test func theSameDropChecksOffOnce() {
	var watcher = CartWatcher()
	_ = watcher.ingest(frame(10, .holding, "eggs"))
	_ = watcher.ingest(frame(11, .intoCart, "eggs"))
	#expect(watcher.ingest(frame(11.33, .intoCart, "eggs")).count == 1)
	#expect(watcher.ingest(frame(11.66, .intoCart, "eggs")) == [])
	#expect(watcher.ingest(frame(12, .empty)) == [])
}

@Test func forgetsAHeldItemAfterTheHandIsEmptyForAWhile() {
	var watcher = CartWatcher()
	_ = watcher.ingest(frame(1, .holding, "milk"))
	#expect(watcher.ingest(frame(5, .empty)) == [])
	#expect(watcher.ingest(frame(10, .empty)) == [.released])
	_ = watcher.ingest(frame(11, .intoCart, nil))
	#expect(watcher.ingest(frame(11.33, .empty)) == [])
}

@Test func anOffListItemInHandIsIgnored() {
	var watcher = CartWatcher()
	#expect(watcher.ingest(frame(1, .holding, nil, seen: "smartphone")) == [])
	_ = watcher.ingest(frame(2, .intoCart, nil, seen: "chips"))
	#expect(watcher.ingest(frame(2.33, .empty)) == [])
}

private func look(_ time: Double, _ state: HandState, _ itemID: String? = nil, basket: [String]) -> FrameVerdict {
	FrameVerdict(time: time, state: state, seen: "", itemID: itemID, inBasket: basket)
}

@Test func aHeldItemThatShowsUpInTheBasketIsCheckedOff() {
	var watcher = CartWatcher()
	_ = watcher.ingest(frame(9.66, .holding, "spinach", seen: "365 chopped spinach"))
	#expect(watcher.ingest(look(10.32, .empty, basket: ["spinach"])) == [.checkedOff(itemID: "spinach", seen: "365 chopped spinach")])
}

@Test func anItemStillInHandOverTheBasketIsNotCheckedOffByTheBasket() {
	var watcher = CartWatcher()
	_ = watcher.ingest(frame(7, .holding, "eggs"))
	#expect(watcher.ingest(look(7.33, .holding, "eggs", basket: ["eggs"])) == [])
}

@Test func twoBasketSightingsCheckOffWithoutSeeingTheHand() {
	var watcher = CartWatcher()
	#expect(watcher.ingest(look(24, .empty, basket: ["apples"])) == [])
	#expect(watcher.nextInterval < 1)
	#expect(watcher.ingest(look(24.33, .empty, basket: ["apples"])) == [.checkedOff(itemID: "apples", seen: "")])
}

@Test func basketSightingsFarApartDontConfirm() {
	var watcher = CartWatcher()
	_ = watcher.ingest(look(10, .empty, basket: ["apples"]))
	#expect(watcher.ingest(look(20, .empty, basket: ["apples"])) == [])
}
