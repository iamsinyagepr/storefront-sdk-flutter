# upskale_storefront

The Flutter counterpart of [`@sinyagepr/storefront-sdk`](../storefront-sdk):
the part of a customer storefront that stays centrally maintained.

- `StorefrontApi` is the tenant API client (`live-upskale-labs`), covering:
  - the store directory, menus, cuisines and delivery options;
  - Places address search and details;
  - guest, sign-up, sign-in and password-reset sessions;
  - orders, quotes and order history;
  - the account and addresses.
- `Storefront` holds the customer flow:
  - where the customer is and the stores near them;
  - the chosen store's menu;
  - the options picked for a product, and the cart.

  `bindings()` exposes all of it under the same names Upskale Studio pages
  read (`stores`, `store`, `menu`, `products`, `cart`, `cartTotal`,
  `configuration`…).
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
