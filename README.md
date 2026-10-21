# upskale_storefront

The Flutter counterpart of [`@sinyagepr/storefront-sdk`](../storefront-sdk):
the part of a customer storefront that stays centrally maintained.

- `StorefrontApi` is the tenant API client (`live-upskale-labs`), covering:
  - the store directory, menus, cuisines and delivery options;
  - Places address search and details;
  - guest, sign-up, sign-in and password-reset sessions;
  - orders, quotes, cancelling, order history and live order events;
  - reviews of an order, and a store's reviews;
  - the account, addresses, email change and push device tokens.
- `Storefront` holds the customer flow:
  - where the customer is and the stores near them;
  - the chosen store's menu;
  - the options picked for a product, and the cart (with a note per line);
  - checkout (`StorefrontCheckout`): delivery or pickup, address and
    instructions, delivery preset, payment method, tip and order notes;
  - the quote, placing the order, and following it live;
  - the customer's orders, reviews and saved addresses.

  `bindings()` exposes all of it under the same names Upskale Studio pages
  read (`stores`, `store`, `menu`, `products`, `cart`, `cartTotal`,
  `configuration`, `checkout`, `quote`, `orders`, `order`, `review`…).
- `OptionGroup` / `OptionSelection` price a product's options, nested ones
  included, and turn them into the order API's `selections`.

Upskale Studio's generated Flutter apps depend on this package. Studio
generates only the pages, components and the widgets that draw this
package's state.

## Using it

```dart
import 'package:upskale_storefront/upskale_storefront.dart';

void main() {
  Storefront.configure(apiBaseUrl: 'https://shop.upskalelabs.dev');
  runApp(const MyApp());
}

// Anywhere:
final storefront = Storefront.instance;
storefront.setLocation(await storefront.resolveAddress(placeId));
await storefront.searchStores(query: 'pizza');
await storefront.selectStore(storefront.stores.first.id);
storefront.addConfigured(product.json, quantity: 2);

// Checkout: the quote and the order are built from the same choices, so
// the total shown is the total charged.
storefront.checkout.update({
  'customer_name': 'Ama',
  'customer_phone': '+27820000000',
  'fulfilment': 'delivery',
  'delivery_address_line1': '1 Main Road',
  'payment_method': 'card',
});
storefront.checkout.tipPercent(10, storefront.cart.totalCents);
final quote = await storefront.refreshQuote();
final order = await storefront.placeOrder(); // then followed live
await storefront.submitReview(foodRating: 5); // once it is delivered
```

`Storefront` is a `ChangeNotifier`, so you can listen to it with
`ListenableBuilder` or `InheritedNotifier`.

The catalogue and store directory are public. Places search, orders and the
account need a session token. `Storefront.searchAddresses` starts a guest
session automatically, and signing up later upgrades that guest in place.
Tokens are kept in memory unless you pass your own `StorefrontTokenStore`.

These conventions match the rest of the stack:
- **Money:** integer cents everywhere (`*_cents`).
- **Prices:** cart prices are only for display. The server re-derives every
  total when an order is quoted or placed.
- **PATCH bodies:** `updateAddress` passes your map through untouched. A key
  you leave out is left alone, and an explicit `null` clears the field.

## Developing

```sh
flutter pub get
flutter analyze
flutter test
```
