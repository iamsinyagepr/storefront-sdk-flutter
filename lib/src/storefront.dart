import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import 'cart.dart';
import 'checkout.dart';
import 'client.dart';
import 'config.dart';
import 'errors.dart';
import 'models.dart';
import 'options.dart';
import 'session.dart';

enum StorefrontStatus { idle, loading, ready, error }

/// Why adding to the cart did not happen.
enum AddToCartResult { added, unavailable, needsOptions }

/// A storefront's whole customer flow: where the customer is, the stores
/// that serve them, the chosen store's menu, the options picked for a
/// product, the cart, checkout, the customer's orders and reviews, and
/// their account.
///
/// One per app, usually [Storefront.instance] after [Storefront.configure].
/// Without a configured API it still keeps a cart and option choices, so an
/// app can run on sample data.
class Storefront extends ChangeNotifier {
  Storefront({this.api, StorefrontTokenStore? tokens})
      : session = api == null ? null : StorefrontSession(api, store: tokens) {
    cart.addListener(notifyListeners);
    checkout.addListener(notifyListeners);
    session?.addListener(notifyListeners);
  }

  static Storefront? _instance;

  /// The app's storefront; unconnected until [configure] is called.
  static Storefront get instance => _instance ??= Storefront();

  /// Connects [instance] to a tenant API. Call once, before `runApp`.
  ///
  /// A single-store app passes its [storeId]: that store's menu starts
  /// loading at once, and the app can open straight on it — no location or
  /// store to choose ([pinnedStoreId]).
  static Storefront configure({
    required String apiBaseUrl,
    String? storeId,
    StorefrontTokenStore? tokens,
    http.Client? client,
  }) {
    _instance?.dispose();
    final storefront = _instance = Storefront(
      api: StorefrontApi(
          StorefrontConfig(apiBaseUrl: apiBaseUrl, storeId: storeId),
          client: client),
      tokens: tokens,
    );
    if (storeId != null && storeId.isNotEmpty) {
      // A failure shows as the menu's error (menuStatus, error), not as an
      // unhandled error at start-up; the menu page offers to try again.
      unawaited(storefront.selectStore(storeId).catchError((Object _) {}));
    } else {
      // The cities a location page offers when the device's location or a
      // search comes up empty; loadCities never throws.
      unawaited(storefront.loadCities());
    }
    return storefront;
  }

  /// The one store a single-store app is built for, or null.
  String? get pinnedStoreId {
    final id = api?.config.storeId;
    return id == null || id.isEmpty ? null : id;
  }

  final StorefrontApi? api;
  final StorefrontSession? session;
  final cart = StorefrontCart();
  final checkout = StorefrontCheckout();

  bool get connected => api != null;

  StorefrontLocation? location;
  List<Store> stores = const [];
  StorefrontStatus storesStatus = StorefrontStatus.idle;

  Store? store;
  Menu? menu;
  Page<Cuisine>? cuisines;
  DeliveryOptions? deliveryOptions;
  StorefrontStatus menuStatus = StorefrontStatus.idle;

  /// The last failure, for a page to show; cleared by the next request.
  String? error;

  int _storesRequest = 0, _menuRequest = 0;

  StorefrontApi get _api =>
      api ??
      (throw StateError(
          'Storefront.configure() was not called with an API URL.'));

  // --- location ---------------------------------------------------------------

  /// Address suggestions, near the current location when there is one.
  /// Starts a guest session, which the places routes need.
  Future<List<PlacePrediction>> searchAddresses(String input) async {
    if (input.trim().length < 3) return const [];
    await session!.ensure();
    return _api.placesAutocomplete(input,
        latitude: location?.latitude, longitude: location?.longitude);
  }

  /// The latest [searchPlaces] answer, for a page to list (`places`).
  List<PlacePrediction> places = const [];
  int _placesRequest = 0;

  /// [searchAddresses], kept in [places]: only the latest search's answer
  /// is kept, and under three characters there is nothing to suggest.
  Future<List<PlacePrediction>> searchPlaces(String input) async {
    final request = ++_placesRequest;
    final found = await searchAddresses(input);
    if (request == _placesRequest) {
      places = found;
      notifyListeners();
    }
    return found;
  }

  Future<StorefrontLocation> resolveAddress(String placeId) async {
    await session!.ensure();
    return _api.placeDetails(placeId);
  }

  void setLocation(StorefrontLocation? value) {
    location = value;
    notifyListeners();
  }

  /// The cities the business has stores in, once loaded ([loadCities]).
  List<StoreCity> cities = const [];

  /// Loads [cities]: the fallback when the customer's location can't be had,
  /// or their search finds nothing. Never throws; an empty list is empty.
  Future<List<StoreCity>> loadCities() async {
    try {
      cities = await _api.storeCities();
      notifyListeners();
    } catch (_) {
      // No cities is the same as none to offer.
    }
    return cities;
  }

  /// Chooses a city as the location: its stores are what [searchStores] finds.
  void chooseCity(StoreCity city) => setLocation(city.location);

  /// The device's own location, asked for (once, if it hasn't been), named
  /// ("Rosebank, Johannesburg") when the address can be looked up, and set as
  /// [location]. Throws [StorefrontLocationError] when it can't be had: the
  /// page then offers search and [cities].
  Future<StorefrontLocation> locateDevice({Duration timeLimit = const Duration(seconds: 12)}) async {
    locating = true;
    locationError = null;
    notifyListeners();
    try {
      return await _locateDevice(timeLimit);
    } on StorefrontLocationError catch (failure) {
      locationError = failure.message;
      rethrow;
    } finally {
      locating = false;
      notifyListeners();
    }
  }

  /// [locateDevice] is finding the device (`locating`), or why it couldn't
  /// (`locationError`), for a page to show.
  bool locating = false;
  String? locationError;

  Future<StorefrontLocation> _locateDevice(Duration timeLimit) async {
    final Position position;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const StorefrontLocationError(LocationProblem.servicesOff);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        throw const StorefrontLocationError(LocationProblem.denied);
      }
      if (permission == LocationPermission.deniedForever) {
        throw const StorefrontLocationError(LocationProblem.deniedForever);
      }
      position = await Geolocator.getCurrentPosition(
          locationSettings: LocationSettings(accuracy: LocationAccuracy.high, timeLimit: timeLimit));
    } on StorefrontLocationError {
      rethrow;
    } on TimeoutException {
      throw const StorefrontLocationError(LocationProblem.timeout);
    } on UnsupportedError {
      throw const StorefrontLocationError(LocationProblem.unsupported);
    } on MissingPluginException {
      throw const StorefrontLocationError(LocationProblem.unsupported);
    }
    var point = StorefrontLocation(
        label: 'Your location', latitude: position.latitude, longitude: position.longitude);
    try {
      await session!.ensure();
      final named = await _api.reverseGeocode(position.latitude, position.longitude);
      if (named.label.isNotEmpty) point = named;
    } catch (_) {
      // Unnamed is still a place to find stores near.
    }
    setLocation(point);
    return point;
  }

  // --- stores -----------------------------------------------------------------

  /// Stores near [location] (or all active stores without one), matching
  /// [query]. Only the latest search's answer is kept.
  Future<List<Store>> searchStores({String? query, int limit = 30}) async {
    final request = ++_storesRequest;
    storesStatus = StorefrontStatus.loading;
    error = null;
    notifyListeners();
    try {
      final page = await _api.stores(
          query: query,
          latitude: location?.latitude,
          longitude: location?.longitude,
          limit: limit);
      if (request == _storesRequest) {
        stores = page.data;
        storesStatus = StorefrontStatus.ready;
      }
    } catch (failure) {
      if (request == _storesRequest) {
        storesStatus = StorefrontStatus.error;
        error = _message(failure);
      }
      rethrow;
    } finally {
      if (request == _storesRequest) notifyListeners();
    }
    return stores;
  }

  /// Opens a store: its menu, cuisines and delivery options. The menu is
  /// required; the other two are optional and never hold it up.
  Future<void> selectStore(String idOrSlug) async {
    final request = ++_menuRequest;
    menuStatus = StorefrontStatus.loading;
    error = null;
    notifyListeners();
    try {
      final next = await _api.storeMenu(idOrSlug);
      final extras = await Future.wait([
        _optional(_api.cuisines),
        _optional(() => _api.deliveryOptions(next.store.id)),
      ]);
      if (request != _menuRequest) return;
      menu = next;
      store = next.store;
      cuisines = extras[0] as Page<Cuisine>?;
      deliveryOptions = extras[1] as DeliveryOptions?;
      menuStatus = StorefrontStatus.ready;
    } catch (failure) {
      if (request == _menuRequest) {
        menuStatus = StorefrontStatus.error;
        error = _message(failure);
      }
      rethrow;
    } finally {
      if (request == _menuRequest) notifyListeners();
    }
  }

  List<MenuProduct> get products => menu?.products ?? const [];

  // --- product options ----------------------------------------------------

  dynamic _optionsProductId;
  final Map<String, List<String>> _optionSelections = {};

  /// The choices made for [product] (a product's JSON); choosing for another
  /// product starts over.
  Map<String, List<String>> selectionsFor(dynamic product) =>
      product is Map && product['id'] == _optionsProductId
          ? Map.unmodifiable(_optionSelections)
          : const {};

  void choose(dynamic product, String groupId, List<String> choiceIds) {
    final id = product is Map ? product['id'] : null;
    if (id != _optionsProductId) {
      _optionSelections.clear();
      _optionsProductId = id;
    }
    _optionSelections[groupId] = choiceIds;
    notifyListeners();
  }

  /// Toggles [choice] in [group] the way a radio (single) or checkbox list
  /// (up to max) behaves.
  void toggle(dynamic product, OptionGroup group, OptionChoice choice) {
    final ids = selectionsFor(product)[group.id] ?? const <String>[];
    if (group.single) return choose(product, group.id, [choice.id]);
    if (ids.contains(choice.id))
      return choose(
          product, group.id, ids.where((id) => id != choice.id).toList());
    if (ids.length < group.max) choose(product, group.id, [...ids, choice.id]);
  }

  /// [toggle] by ids, as a page's ToggleOption sends them; the group can be
  /// a nested one (a selected choice's own).
  void toggleById(dynamic product, String groupId, String choiceId) {
    final group = findOptionGroup(OptionGroup.fromProduct(product), groupId);
    if (group == null) return;
    for (final choice in group.choices) {
      if (choice.id == choiceId) return toggle(product, group, choice);
    }
  }

  OptionSelection configuration(dynamic product) => OptionSelection.of(
      OptionGroup.fromProduct(product), selectionsFor(product));

  // --- cart -----------------------------------------------------------------

  /// Adds [product] with the options chosen for it.
  AddToCartResult addConfigured(Map<String, dynamic> product,
      {int quantity = 1}) {
    if (product['is_available'] == false) return AddToCartResult.unavailable;
    final selection = configuration(product);
    if (!selection.valid) return AddToCartResult.needsOptions;
    cart.add(product,
        quantity: quantity,
        unitCents:
            _cents(product['display_price_cents']) + selection.priceCents,
        choices: selection.labels,
        selections: selection.selections,
        storeId: store?.id ?? product['store_id'] as String?);
    return AddToCartResult.added;
  }

  /// Adds [product] as it is; a product with required options can't be.
  AddToCartResult add(Map<String, dynamic> product, {int quantity = 1}) {
    if (product['is_available'] == false) return AddToCartResult.unavailable;
    if (OptionGroup.fromProduct(product).any((group) => group.required))
      return AddToCartResult.needsOptions;
    cart.add(product,
        quantity: quantity,
        unitCents: _cents(product['display_price_cents']),
        storeId: store?.id ?? product['store_id'] as String?);
    return AddToCartResult.added;
  }

  // --- checkout ---------------------------------------------------------------

  OrderQuote? quote;
  StorefrontStatus quoteStatus = StorefrontStatus.idle;
  StorefrontStatus placeStatus = StorefrontStatus.idle;
  int _quoteRequest = 0;

  /// The validation problems from the last place attempt, by field.
  Map<String, String> fieldErrors = const {};

  String? get _cartStoreId => cart.storeId ?? store?.id;

  /// Prices the cart with the current [checkout] choices without placing
  /// it. Call again when the tip, payment method or delivery changes; only
  /// the latest answer is kept.
  Future<OrderQuote?> refreshQuote() async {
    final storeId = _cartStoreId;
    if (storeId == null || cart.isEmpty) {
      quote = null;
      quoteStatus = StorefrontStatus.idle;
      notifyListeners();
      return null;
    }
    final request = ++_quoteRequest;
    quoteStatus = StorefrontStatus.loading;
    notifyListeners();
    try {
      await session!.ensure();
      if (checkout.delivery) checkout.useLocation(location);
      final next =
          await _api.quoteOrder(checkout.quoteBody(storeId, cart.orderItems()));
      if (request == _quoteRequest) {
        quote = next;
        quoteStatus = StorefrontStatus.ready;
      }
      return next;
    } catch (failure) {
      if (request == _quoteRequest) {
        quoteStatus = StorefrontStatus.error;
        error = _message(failure);
      }
      return null;
    } finally {
      if (request == _quoteRequest) notifyListeners();
    }
  }

  /// Places the cart as an order. On success the cart empties and the order
  /// becomes [order], followed live; on a validation failure [fieldErrors]
  /// names the fields to fix and the error is rethrown.
  Future<Order> placeOrder() async {
    final storeId = _cartStoreId;
    if (storeId == null || cart.isEmpty)
      throw StateError('There is nothing in the cart to order.');
    placeStatus = StorefrontStatus.loading;
    error = null;
    fieldErrors = const {};
    notifyListeners();
    try {
      await session!.ensure();
      if (checkout.delivery) checkout.useLocation(location);
      final placed = await _api
          .createOrder(checkout.orderBody(storeId, cart.orderItems()));
      cart.clear();
      checkout.resetForNextOrder();
      quote = null;
      order = placed;
      review = null;
      orders = [placed, ...orders.where((item) => item.id != placed.id)];
      placeStatus = StorefrontStatus.ready;
      unawaited(followOrder(placed.id));
      return placed;
    } catch (failure) {
      placeStatus = StorefrontStatus.error;
      error = _message(failure);
      if (failure is StorefrontApiError)
        fieldErrors = failure.fields ?? const {};
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  // --- orders -----------------------------------------------------------------

  List<Order> orders = const [];
  StorefrontStatus ordersStatus = StorefrontStatus.idle;

  /// The order a tracking page shows, and its review once it has one.
  Order? order;
  OrderReview? review;

  /// Where the driver is, while one is on the way.
  StorefrontLocation? driverLocation;
  StreamSubscription<OrderLiveEvent>? _following;

  Future<List<Order>> loadOrders() async {
    ordersStatus = StorefrontStatus.loading;
    notifyListeners();
    try {
      await session!.ensure();
      orders = (await _api.orders()).data;
      ordersStatus = StorefrontStatus.ready;
    } catch (failure) {
      ordersStatus = StorefrontStatus.error;
      error = _message(failure);
    } finally {
      notifyListeners();
    }
    return orders;
  }

  /// Opens an order by id or order number, with its review when delivered.
  Future<Order> openOrder(String idOrNumber) async {
    await session!.ensure();
    final next = await _api.order(idOrNumber);
    if (order?.id != next.id) {
      review = null;
      driverLocation = null;
    }
    order = next;
    if (next.delivered) review = await _optional(() => _api.review(next.id));
    notifyListeners();
    return next;
  }

  /// Follows [orderId] live until the server ends the stream or another
  /// order is followed, updating [order], [orders] and [driverLocation].
  Future<void> followOrder(String orderId) async {
    await _following?.cancel();
    _following = null;
    if (!connected) return;
    await session!.ensure();
    _following = _api.orderEvents(orderId).listen((event) {
      if (event.type == 'status' && event.status != null) {
        final status = {'status': event.status};
        if (order?.id == orderId) order = order!.copyWith(status);
        orders = [
          for (final item in orders)
            item.id == orderId ? item.copyWith(status) : item
        ];
        if (event.status == 'delivered' || event.status == 'cancelled')
          driverLocation = null;
      } else if (event.type == 'driver_location' &&
          order?.id == orderId &&
          event.latitude != null &&
          event.longitude != null) {
        driverLocation = StorefrontLocation(
            label: order!.driverName ?? 'Driver',
            latitude: event.latitude!,
            longitude: event.longitude!);
      }
      notifyListeners();
    }, onError: (Object _) {}, cancelOnError: true);
  }

  Future<void> stopFollowing() async {
    await _following?.cancel();
    _following = null;
  }

  /// Cancels [orderId] (the open order by default) while it still can be.
  Future<Order> cancelOrder([String? orderId, String? reason]) async {
    final id = orderId ?? order?.id;
    if (id == null) throw StateError('No order is open.');
    await session!.ensure();
    final cancelled = await _api.cancelOrder(id, reason: reason);
    if (order?.id == id) order = cancelled;
    orders = [for (final item in orders) item.id == id ? cancelled : item];
    notifyListeners();
    return cancelled;
  }

  // --- reviews ----------------------------------------------------------------

  List<OrderReview> reviews = const [];

  /// Reviews the open order: delivered orders only, once. A pickup has no
  /// delivery rating, so one given for it is dropped.
  Future<OrderReview> submitReview(
      {int? foodRating,
      String? foodComment,
      int? deliveryRating,
      String? deliveryComment}) async {
    final current = order;
    if (current == null) throw StateError('No order is open.');
    final delivery = current.fulfilmentType == 'delivery';
    await session!.ensure();
    review = await _api.createReview(current.id,
        foodRating: foodRating,
        foodComment: foodComment,
        deliveryRating: delivery ? deliveryRating : null,
        deliveryComment: delivery ? deliveryComment : null);
    notifyListeners();
    return review!;
  }

  /// The chosen store's reviews, newest first.
  Future<List<OrderReview>> loadReviews({int limit = 20}) async {
    final id = store?.id;
    if (id == null) return const [];
    reviews = (await _api.storeReviews(id, limit: limit)).data;
    notifyListeners();
    return reviews;
  }

  // --- account ----------------------------------------------------------------

  List<Address> addresses = const [];

  Future<List<Address>> loadAddresses() async {
    await session!.ensure();
    addresses = (await _api.addresses()).data;
    notifyListeners();
    return addresses;
  }

  /// Creates an address, or with [id] patches one (three-state: only the
  /// keys in [body] change).
  Future<Address> saveAddress(Json body, {String? id}) async {
    await session!.ensure();
    final saved = id == null
        ? await _api.createAddress(body)
        : await _api.updateAddress(id, body);
    await loadAddresses();
    return saved;
  }

  Future<void> deleteAddress(String id) async {
    await session!.ensure();
    await _api.deleteAddress(id);
    if (checkout.addressId == id)
      checkout.update({'delivery_address_id': null});
    await loadAddresses();
  }

  /// Emails a confirmation to [newEmail]; the account changes once it is
  /// followed.
  Future<void> changeEmail(String newEmail) async {
    await session!.ensure();
    await _api.changeEmail(newEmail);
  }

  // --- bindings ---------------------------------------------------------------

  /// What Studio pages read, by the same names as the preview: the store,
  /// menu and directory once loaded, the cart and the open product's
  /// configuration always.
  Map<String, dynamic> bindings({dynamic product}) {
    final selection = configuration(product);
    final categories =
        menu?.categories.map((category) => category.json).toList();
    final presets = deliveryOptions?.presets;
    return {
      if (location != null) 'location': location!.toJson(),
      'places': [
        for (final place in places)
          {
            ...place.json,
            'label': place.secondaryText.isEmpty
                ? place.mainText
                : '${place.mainText}, ${place.secondaryText}',
          },
      ],
      'cities': [
        for (final city in cities) {...city.json, 'label': city.name},
      ],
      'locating': locating,
      'locationError': locationError,
      'storesLoading': storesStatus == StorefrontStatus.loading,
      'optionGroups': optionGroupBindings(
          OptionGroup.fromProduct(product), selectionsFor(product)),
      if (stores.isNotEmpty) 'stores': [for (final item in stores) item.json],
      if (store != null) 'store': store!.json,
      if (menu != null) ...{
        'menu': menu!.json,
        'categories': categories,
        'category': categories!.isEmpty ? null : categories.first,
        'products': [for (final item in products) item.json],
      },
      if (cuisines != null) ...{
        'cuisinesPage': {
          'data': [for (final item in cuisines!.data) item.json],
          'next_cursor': cuisines!.nextCursor
        },
        'cuisines': [for (final item in cuisines!.data) item.json],
      },
      if (deliveryOptions != null) ...{
        'deliveryOptions': deliveryOptions!.json,
        'deliveryPresets': presets,
        'deliveryPreset': presets!.isEmpty ? null : presets.first,
      },
      'cart': [for (final line in cart.lines) line.toJson()],
      'cartCount': cart.count,
      'cartTotal': cart.totalCents,
      'configuration': {
        'valid': selection.valid,
        'addon_price_cents': selection.priceCents
      },
      'checkout': checkout.toJson(),
      if (quote != null) 'quote': quote!.json,
      if (fieldErrors.isNotEmpty) 'checkoutErrors': fieldErrors,
      'orders': [for (final item in orders) item.json],
      if (order != null) ...{
        'order': order!.json,
        'orderItems': order!.items,
      },
      if (review != null) 'review': review!.json,
      if (driverLocation != null) 'driverLocation': driverLocation!.toJson(),
      if (reviews.isNotEmpty)
        'reviews': [for (final item in reviews) item.json],
      if (addresses.isNotEmpty)
        'addresses': [for (final item in addresses) item.json],
      if (session?.user != null) 'me': session!.user!.json,
    };
  }

  @override
  void dispose() {
    _following?.cancel();
    cart.dispose();
    checkout.dispose();
    session?.dispose();
    api?.close();
    super.dispose();
  }

  static int _cents(dynamic value) => value is num ? value.round() : 0;

  static Future<T?> _optional<T>(Future<T> Function() read) async {
    try {
      return await read().timeout(const Duration(seconds: 4));
    } catch (_) {
      return null;
    }
  }

  static String _message(Object failure) => failure is StorefrontApiError
      ? failure.message
      : failure is FormatException
          ? failure.message
          : 'Something went wrong.';
}
