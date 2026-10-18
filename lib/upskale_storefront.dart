/// The part of a Flutter storefront that stays centrally maintained: the
/// tenant API client, the guest session, location and store search, the menu
/// and the cart. Generated Upskale Studio apps depend on this package and
/// keep only their own pages and components.
///
/// ```dart
/// void main() {
///   Storefront.configure(apiBaseUrl: 'https://shop.upskalelabs.dev');
///   runApp(const MyApp());
/// }
/// ```
library;

export 'src/cart.dart';
export 'src/client.dart';
export 'src/config.dart';
export 'src/errors.dart';
export 'src/models.dart';
export 'src/options.dart';
export 'src/session.dart';
export 'src/storefront.dart';
