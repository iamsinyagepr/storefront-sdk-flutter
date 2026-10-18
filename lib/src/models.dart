/// Response shapes for the customer-facing tenant API (`live-upskale-labs`).
///
/// Each model wraps the JSON the server sent ([json]) and adds typed getters,
/// so an app can bind any field by name — including ones this package does
/// not know about yet — while Dart code gets types. Field names follow the Go
/// structs' `json` tags, as in the TypeScript SDK's `types.ts`.
///
/// Money is always integer cents (`*_cents`), never a double.
library;

typedef Json = Map<String, dynamic>;

Json _object(dynamic value, String what) {
  if (value is Map) return value.cast<String, dynamic>();
  throw FormatException('The $what response is invalid.');
}

String _string(Json json, String key, String what) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('The $what response has no $key.');
}

int _cents(dynamic value) => value is num ? value.round() : 0;
double? _double(dynamic value) => value is num ? value.toDouble() : null;
List<Json> _objects(dynamic value) => value is List
    ? [
        for (final item in value)
          if (item is Map) item.cast<String, dynamic>()
      ]
    : const [];

/// A cursor page — the envelope every list endpoint answers with.
class Page<T> {
  Page(this.data, this.nextCursor);

  factory Page.fromJson(dynamic json, T Function(dynamic item) item) {
    final body = _object(json, 'page');
    final data = body['data'];
    if (data is! List)
      throw const FormatException('The page response has no data.');
    return Page([for (final value in data) item(value)],
        body['next_cursor'] as String?);
  }

  final List<T> data;
  final String? nextCursor;
}

/// `GET /stores` near a point also says how far it looked.
class StorePage extends Page<Store> {
  StorePage(super.data, super.nextCursor,
      {this.radiusKm, this.widened = false});

  factory StorePage.fromJson(dynamic json) {
    final page = Page.fromJson(json, Store.fromJson);
    final search = (json as Map)['search'];
    return StorePage(page.data, page.nextCursor,
        radiusKm: search is Map ? _double(search['radius_km']) : null,
        widened: search is Map && search['widened'] == true);
  }

  final double? radiusKm;
  final bool widened;
}

class Store {
  Store(this.json) {
    _string(json, 'id', 'store');
    _string(json, 'name', 'store');
  }
  factory Store.fromJson(dynamic json) => Store(_object(json, 'store'));

  final Json json;
  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String? get slug => json['slug'] as String?;
  String? get description => json['description'] as String?;
  String? get city => json['city'] as String?;
  String? get logoUrl => json['logo_url'] as String?;
  String? get bannerUrl => json['banner_url'] as String?;
  double? get latitude => _double(json['latitude']);
  double? get longitude => _double(json['longitude']);
  bool get isOpen => json['is_open'] == true;

  /// ISO 4217; ZAR when the server sent something else.
  String get currency {
    final value = json['currency'];
    return value is String && RegExp(r'^[A-Z]{3}$').hasMatch(value)
        ? value
        : 'ZAR';
  }

  int get deliveryFeeCents => _cents(json['delivery_fee_cents']);
  int get minOrderCents => _cents(json['min_order_cents']);
  bool get acceptsDelivery => json['accepts_delivery'] == true;
  bool get acceptsCollect => json['accepts_collect'] == true;
}

class MenuProduct {
  MenuProduct(this.json) {
    _string(json, 'id', 'product');
    _string(json, 'name', 'product');
  }
  factory MenuProduct.fromJson(dynamic json) =>
      MenuProduct(_object(json, 'product'));

  final Json json;
  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String? get description => json['description'] as String?;
  String? get imageUrl => json['image_url'] as String?;
  String? get categoryId => json['category_id'] as String?;

  /// What the customer pays — never sum `price_cents`, the vendor's own price.
  int get displayPriceCents => _cents(json['display_price_cents']);
  bool get isAvailable => json['is_available'] != false;
  bool get isAvailableOnline => json['is_available_online'] != false;
  List<Json> get addonGroups => _objects(json['addon_groups']);
}

class MenuCategory {
  MenuCategory(this.json) {
    _string(json, 'id', 'category');
  }
  factory MenuCategory.fromJson(dynamic json) =>
      MenuCategory(_object(json, 'category'));

  final Json json;
  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? '';
  List<MenuProduct> get products =>
      [for (final item in _objects(json['products'])) MenuProduct(item)];
}

/// `GET /stores/{id}/menu`: the whole catalogue in one call. Never fan this
/// out per category or product — the server already nests what a product
/// page needs.
class Menu {
  Menu(this.json) : store = Store.fromJson(json['store']) {
    if (json['categories'] is! List) {
      throw const FormatException('The menu response is invalid.');
    }
  }
  factory Menu.fromJson(dynamic json) => Menu(_object(json, 'menu'));

  final Json json;
  final Store store;
  List<MenuCategory> get categories =>
      [for (final item in _objects(json['categories'])) MenuCategory(item)];
  List<MenuProduct> get uncategorised =>
      [for (final item in _objects(json['uncategorised'])) MenuProduct(item)];

  /// Every product a customer can order online, categorised first.
  List<MenuProduct> get products => [
        for (final category in categories) ...category.products,
        ...uncategorised,
      ].where((product) => product.isAvailableOnline).toList();
}

class Cuisine {
  Cuisine(this.json);
  factory Cuisine.fromJson(dynamic json) => Cuisine(_object(json, 'cuisine'));

  final Json json;
  String get name => json['name'] as String? ?? '';
  int get storeCount => _cents(json['store_count']);
}

/// `GET /stores/{id}/delivery-options`: a preset picker or a typed address.
class DeliveryOptions {
  DeliveryOptions(this.json);
  factory DeliveryOptions.fromJson(dynamic json) =>
      DeliveryOptions(_object(json, 'delivery options'));

  final Json json;
  String get mode => json['mode'] as String? ?? 'distance';
  List<Json> get presets => _objects(json['presets']);
}

/// One `GET /places/autocomplete` result.
class PlacePrediction {
  PlacePrediction(this.json);
  factory PlacePrediction.fromJson(dynamic json) =>
      PlacePrediction(_object(json, 'place'));

  final Json json;
  String get placeId => json['place_id'] as String? ?? '';
  String get mainText => json['main_text'] as String? ?? '';
  String get secondaryText => json['secondary_text'] as String? ?? '';
}

/// A point a customer is ordering to: from a resolved place, a map pin or a
/// preset.
class StorefrontLocation {
  const StorefrontLocation(
      {required this.label, required this.latitude, required this.longitude});

  /// `GET /places/details`.
  factory StorefrontLocation.fromPlaceDetails(dynamic json) {
    final body = _object(json, 'place');
    final latitude = _double(body['latitude']),
        longitude = _double(body['longitude']);
    if (latitude == null || longitude == null) {
      throw const FormatException('This address has no coordinates.');
    }
    final address = body['address'] as String? ?? '';
    return StorefrontLocation(
        label: address.isNotEmpty ? address : body['name'] as String? ?? '',
        latitude: latitude,
        longitude: longitude);
  }

  final String label;
  final double latitude, longitude;

  Json toJson() =>
      {'label': label, 'latitude': latitude, 'longitude': longitude};
}

class Me {
  Me(this.json);
  factory Me.fromJson(dynamic json) => Me(_object(json, 'account'));

  final Json json;
  String get id => json['id'] as String? ?? '';
  String? get email => json['email'] as String?;
  String? get displayName => json['display_name'] as String?;
  bool get isAnonymous => json['is_anonymous'] == true;
}

/// What every endpoint that mints a session answers with: guest, sign-up,
/// sign-in and a successful password reset.
class SessionIssued {
  SessionIssued(this.json)
      : token = _string(json, 'token', 'session'),
        user = Me.fromJson(json['user']);
  factory SessionIssued.fromJson(dynamic json) =>
      SessionIssued(_object(json, 'session'));

  final Json json;
  final String token;
  final Me user;
}

class Order {
  Order(this.json) {
    _string(json, 'id', 'order');
  }
  factory Order.fromJson(dynamic json) => Order(_object(json, 'order'));

  final Json json;
  String get id => json['id'] as String;
  String get orderNumber => json['order_number'] as String? ?? id;
  String get status => json['status'] as String? ?? 'pending';
  int get totalCents => _cents(json['total_cents']);
  List<Json> get items => _objects(json['items']);
}

class OrderEvent {
  OrderEvent(this.json);
  factory OrderEvent.fromJson(dynamic json) =>
      OrderEvent(_object(json, 'order event'));

  final Json json;
  String get status => json['status'] as String? ?? '';
  String? get note => json['note'] as String?;
}

class Address {
  Address(this.json);
  factory Address.fromJson(dynamic json) => Address(_object(json, 'address'));

  final Json json;
  String get id => json['id'] as String? ?? '';
  String get line1 => json['line1'] as String? ?? '';
  String? get label => json['label'] as String?;
  bool get isDefault => json['is_default'] == true;
}

/// `POST /orders/quote`: a preview of what the basket costs, re-derived by
/// the server when the order is placed.
class OrderQuote {
  OrderQuote(this.json);
  factory OrderQuote.fromJson(dynamic json) =>
      OrderQuote(_object(json, 'quote'));

  final Json json;
  int get itemsSubtotalCents => _cents(json['items_subtotal_cents']);
  int get deliveryFeeCents => _cents(json['delivery_fee_cents']);
  int get totalCents => _cents(json['total_cents']);
}
