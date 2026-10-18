import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cart.dart';
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
/// product, and the cart.
///
/// One per app, usually [Storefront.instance] after [Storefront.configure].
/// Without a configured API it still keeps a cart and option choices, so an
/// app can run on sample data.
class Storefront extends ChangeNotifier {
  Storefront({this.api, StorefrontTokenStore? tokens})
      : session = api == null ? null : StorefrontSession(api, store: tokens) {
    cart.addListener(notifyListeners);
    session?.addListener(notifyListeners);
  }

  static Storefront? _instance;

  /// The app's storefront; unconnected until [configure] is called.
  static Storefront get instance => _instance ??= Storefront();

  /// Connects [instance] to a tenant API. Call once, before `runApp`.
  static Storefront configure({
    required String apiBaseUrl,
    String? storeId,
    StorefrontTokenStore? tokens,
    http.Client? client,
  }) {
    _instance?.dispose();
    return _instance = Storefront(
      api: StorefrontApi(
          StorefrontConfig(apiBaseUrl: apiBaseUrl, storeId: storeId),
          client: client),
      tokens: tokens,
    );
  }

  final StorefrontApi? api;
  final StorefrontSession? session;
  final cart = StorefrontCart();

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

  Future<StorefrontLocation> resolveAddress(String placeId) async {
    await session!.ensure();
    return _api.placeDetails(placeId);
  }

  void setLocation(StorefrontLocation? value) {
    location = value;
    notifyListeners();
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
    };
  }

  @override
  void dispose() {
    cart.dispose();
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
