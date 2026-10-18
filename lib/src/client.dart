import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'errors.dart';
import 'models.dart';

/// The tenant API, called directly from the device — CORS and auth work the
/// same way as for the web storefront: the catalogue and store directory are
/// public, everything about a customer needs their session token.
class StorefrontApi {
  StorefrontApi(this.config,
      {http.Client? client,
      this.token,
      this.timeout = const Duration(seconds: 20)})
      : _client = client ?? http.Client();

  final StorefrontConfig config;
  final http.Client _client;
  final Duration timeout;

  /// The current session token, read on each authenticated call. Usually
  /// [StorefrontSession.token].
  String? Function()? token;

  static const _prefix = '/api/v1';

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final values = <String, dynamic>{};
    query?.forEach((key, value) {
      if (value == null) return;
      values[key] =
          value is Iterable ? [for (final item in value) '$item'] : '$value';
    });
    return Uri.parse(config.apiBaseUrl + _prefix + path)
        .replace(queryParameters: values.isEmpty ? null : values);
  }

  static String _segment(String value) => Uri.encodeComponent(value.trim());

  Future<dynamic> _request(String method, String path,
      {Map<String, dynamic>? query, Object? body, bool auth = false}) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    // Only where the route needs it: the catalogue is public.
    if (auth) {
      final value = token?.call();
      if (value != null && value.isNotEmpty)
        headers['Authorization'] = 'Bearer $value';
    }
    final request = http.Request(method, _uri(path, query))
      ..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    http.Response response;
    try {
      response = await http.Response.fromStream(
          await _client.send(request).timeout(timeout));
    } on TimeoutException {
      throw const StorefrontApiError(
          0, 'timeout', 'The store took too long to answer. Try again.');
    } catch (_) {
      throw const StorefrontApiError(
          0, 'offline', 'Could not reach the store. Check your connection.');
    }
    if (response.statusCode == 204) return null;
    dynamic parsed;
    try {
      parsed = response.body.isEmpty
          ? null
          : jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      parsed = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = parsed is Map ? parsed : const {};
      final fields = error['fields'];
      throw StorefrontApiError(
        response.statusCode,
        error['error'] is String ? error['error'] as String : 'unknown',
        error['message'] is String
            ? error['message'] as String
            : 'Something went wrong.',
        fields is Map
            ? fields.map((key, value) => MapEntry('$key', '$value'))
            : null,
      );
    }
    return parsed;
  }

  // --- catalogue (public) ---------------------------------------------------

  /// The store directory. Near [latitude]/[longitude] when given (the server
  /// widens the radius if nothing is close), otherwise by [city]; never both.
  Future<StorePage> stores({
    String? query,
    double? latitude,
    double? longitude,
    String? city,
    List<String>? cuisines,
    String? status = 'active',
    bool? isOpen,
    int? limit,
    String? cursor,
  }) async =>
      StorePage.fromJson(await _request('GET', '/stores', query: {
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
        if (latitude != null && longitude != null) ...{
          'latitude': latitude,
          'longitude': longitude
        },
        if (latitude == null && city != null && city.isNotEmpty) 'city': city,
        if (cuisines != null && cuisines.isNotEmpty) 'cuisine': cuisines,
        'status': status,
        'is_open': isOpen,
        'limit': limit,
        'cursor': cursor,
      }));

  /// By id or slug — one polymorphic route.
  Future<Store> store(String idOrSlug) async =>
      Store.fromJson(await _request('GET', '/stores/${_segment(idOrSlug)}'));

  /// The whole menu — categories, products and their option groups.
  Future<Menu> storeMenu(String idOrSlug) async => Menu.fromJson(
      await _request('GET', '/stores/${_segment(idOrSlug)}/menu'));

  Future<Page<Cuisine>> cuisines() async =>
      Page.fromJson(await _request('GET', '/cuisines'), Cuisine.fromJson);

  Future<DeliveryOptions> deliveryOptions(String idOrSlug) async =>
      DeliveryOptions.fromJson(await _request(
          'GET', '/stores/${_segment(idOrSlug)}/delivery-options'));

  // --- location (session required) -----------------------------------------

  /// Address suggestions as the customer types; biased towards a point when
  /// given. An unconfigured deployment answers with none.
  Future<List<PlacePrediction>> placesAutocomplete(String input,
      {double? latitude, double? longitude}) async {
    if (input.trim().isEmpty) return const [];
    final body =
        await _request('GET', '/places/autocomplete', auth: true, query: {
      'input': input.trim(),
      if (latitude != null && longitude != null) ...{
        'latitude': latitude,
        'longitude': longitude
      },
    });
    final data = body is Map ? body['data'] : null;
    return data is List
        ? [for (final item in data) PlacePrediction.fromJson(item)]
        : const [];
  }

  /// Resolves a prediction into a labelled point.
  Future<StorefrontLocation> placeDetails(String placeId) async =>
      StorefrontLocation.fromPlaceDetails(await _request(
          'GET', '/places/details',
          auth: true, query: {'place_id': placeId}));

  // --- sessions ---------------------------------------------------------------

  /// A session for a guest — no email or password.
  Future<SessionIssued> guest() async =>
      SessionIssued.fromJson(await _request('POST', '/auth/guest'));

  /// With a guest session attached, upgrades it in place; otherwise creates
  /// a new account.
  Future<SessionIssued> signUp(
          {required String email,
          required String password,
          String? displayName}) async =>
      SessionIssued.fromJson(
          await _request('POST', '/auth/sign-up', auth: true, body: {
        'email': email,
        'password': password,
        if (displayName != null) 'display_name': displayName,
      }));

  Future<SessionIssued> signIn(
          {required String email, required String password}) async =>
      SessionIssued.fromJson(await _request('POST', '/auth/sign-in',
          body: {'email': email, 'password': password}));

  Future<void> resendVerification() =>
      _request('POST', '/auth/resend-verification', auth: true);

  /// Answers the same whether or not the address exists.
  Future<void> requestPasswordReset(String email) =>
      _request('POST', '/auth/password/forgot', body: {'email': email});

  Future<SessionIssued> confirmPasswordReset(
          {required String token, required String newPassword}) async =>
      SessionIssued.fromJson(await _request('POST', '/auth/password/reset',
          body: {'token': token, 'new_password': newPassword}));

  // --- orders (session required) -------------------------------------------

  /// Prices a basket without placing it. Cheap, writes nothing; the server
  /// re-derives every figure when the order is placed.
  Future<OrderQuote> quoteOrder(Json body) async => OrderQuote.fromJson(
      await _request('POST', '/orders/quote', auth: true, body: body));

  Future<Order> createOrder(Json body) async =>
      Order.fromJson(await _request('POST', '/orders', auth: true, body: body));

  Future<Page<Order>> orders() async => Page.fromJson(
      await _request('GET', '/orders', auth: true), Order.fromJson);

  /// A UUID or an order number — one polymorphic route.
  Future<Order> order(String idOrNumber) async => Order.fromJson(
      await _request('GET', '/orders/${_segment(idOrNumber)}', auth: true));

  Future<Order> cancelOrder(String id) async => Order.fromJson(
      await _request('POST', '/orders/${_segment(id)}/cancel', auth: true));

  Future<Page<OrderEvent>> orderHistory(String id) async => Page.fromJson(
      await _request('GET', '/orders/${_segment(id)}/history', auth: true),
      OrderEvent.fromJson);

  // --- account (session required) ------------------------------------------

  Future<Me> me() async =>
      Me.fromJson(await _request('GET', '/me', auth: true));

  Future<Page<Address>> addresses() async => Page.fromJson(
      await _request('GET', '/addresses', auth: true), Address.fromJson);

  Future<Address> createAddress(Json body) async => Address.fromJson(
      await _request('POST', '/addresses', auth: true, body: body));

  /// Three-state PATCH: a key left out is left alone, an explicit null clears
  /// the field — never fill in absent keys.
  Future<Address> updateAddress(String id, Json patch) async =>
      Address.fromJson(await _request('PATCH', '/addresses/${_segment(id)}',
          auth: true, body: patch));

  Future<void> deleteAddress(String id) =>
      _request('DELETE', '/addresses/${_segment(id)}', auth: true);

  void close() => _client.close();
}
