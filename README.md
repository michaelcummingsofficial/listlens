# ListLens

Put something in your cart, and it's checked off your list.

ListLens is an open-source iOS engine for Meta Ray-Ban Display glasses. It watches the glasses camera while you shop. Meta's models recognize what's in your hand, and when it lands in your cart or basket, the matching item is checked off your list. The glasses display shows what matched, so you never reach for your phone.

## How it works

1. The glasses stream their camera to the iPhone through the [Meta Wearables Device Access Toolkit](https://wearables.developer.meta.com/docs/develop/).
2. Muse Spark identifies the item in your hand and matches it to your list, before it reaches the cart.
3. When the item goes into the cart, it's checked off and the glasses display confirms it.
4. A short video clip goes back to Muse Spark to confirm the item and count how many went in. Anything wrong is undone.

Lists come from a list source. ListLens ships with a simple local list, and any app can plug in its own.

## Status

ListLens is being built for the [Meta Global AI Developer Hackathon](https://cerebralvalley.ai/e/meta-ai-developer-hackathon), October 26 to November 4, 2026. Everything in this repository was written during the event.

## License

[MIT](LICENSE)
