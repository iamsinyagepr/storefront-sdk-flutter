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

  /// Allowed until the kitchen starts; afterwards the API answers 409.
  Future<Order> cancelOrder(String id, {String? reason}) async =>
      Order.fromJson(await _request('POST', '/orders/${_segment(id)}/cancel',
          auth: true, body: reason == null ? null : {'reason': reason}));

  Future<Page<OrderEvent>> orderHistory(String id) async => Page.fromJson(
      await _request('GET', '/orders/${_segment(id)}/history', auth: true),
      OrderEvent.fromJson);

  /// Live updates for one order — `event: status` when it moves and
  /// `event: driver_location` while it is on its way. Bearer-authenticated
  /// like every other route, so it is read as a stream rather than through a
  /// browser-style EventSource. Ends when the server closes the connection;
  /// cancel the subscription to stop listening.
  Stream<OrderLiveEvent> orderEvents(String id) async* {
    final request = http.Request('GET', _uri('/orders/${_segment(id)}/events'))
      ..headers['Accept'] = 'text/event-stream';
    final value = token?.call();
    if (value != null && value.isNotEmpty)
      request.headers['Authorization'] = 'Bearer $value';
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw const StorefrontApiError(
          0, 'timeout', 'The store took too long to answer. Try again.');
    } catch (_) {
      throw const StorefrontApiError(
          0, 'offline', 'Could not reach the store. Check your connection.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StorefrontApiError(response.statusCode, 'events_failed',
          'Live updates are unavailable for this order.');
    }
    yield* parseOrderEvents(response.stream);
  }

  // --- reviews ---------------------------------------------------------------

  /// Reviews a delivered order, once. Ratings are 1–5; a pickup order has no
  /// delivery rating.
  Future<OrderReview> createReview(String orderId,
          {int? foodRating,
          String? foodComment,
          int? deliveryRating,
          String? deliveryComment}) async =>
      OrderReview.fromJson(await _request(
          'POST', '/orders/${_segment(orderId)}/review',
          auth: true,
          body: {
            if (foodRating != null) 'food_rating': foodRating,
            if (foodComment != null && foodComment.trim().isNotEmpty)
              'food_comment': foodComment.trim(),
            if (deliveryRating != null) 'delivery_rating': deliveryRating,
            if (deliveryComment != null && deliveryComment.trim().isNotEmpty)
              'delivery_comment': deliveryComment.trim(),
          }));

  /// The review left on an order; a 404 when there is none yet.
  Future<OrderReview> review(String orderId) async => OrderReview.fromJson(
      await _request('GET', '/orders/${_segment(orderId)}/review', auth: true));

  /// A store's reviews, newest first. Public.
  Future<Page<OrderReview>> storeReviews(String storeId,
          {int? limit, String? cursor}) async =>
      Page.fromJson(
          await _request('GET', '/stores/${_segment(storeId)}/reviews',
              query: {'limit': limit, 'cursor': cursor}),
          OrderReview.fromJson);

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

  /// Emails a confirmation link to [newEmail]; nothing changes until it is
  /// followed.
  Future<void> changeEmail(String newEmail) =>
      _request('POST', '/auth/email/change',
          auth: true, body: {'new_email': newEmail.trim()});

  /// Registers this device for order push notifications (FCM token).
  Future<void> registerDeviceToken(String deviceToken,
          {required String platform}) =>
      _request('POST', '/me/device-tokens',
          auth: true, body: {'token': deviceToken, 'platform': platform});

  /// Unsubscribes this device, e.g. on sign-out.
  Future<void> deleteDeviceToken(String deviceToken) =>
      _request('DELETE', '/me/device-tokens',
          auth: true, body: {'token': deviceToken});

  void close() => _client.close();
}

/// Parses a server-sent-event stream into order events. Comment lines
/// (`: ping`) keep the connection alive and are skipped, as are frames this
/// version does not know.
Stream<OrderLiveEvent> parseOrderEvents(Stream<List<int>> bytes) async* {
  var type = 'message';
  final data = StringBuffer();
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        try {
          final json = jsonDecode(data.toString());
          if (json is Map<String, dynamic> &&
              (type == 'status' || type == 'driver_location'))
            yield OrderLiveEvent(type, json);
        } on FormatException {
          // A torn frame; the next one is complete.
        }
      }
      type = 'message';
      data.clear();
    } else if (line.startsWith(':')) {
      continue;
    } else if (line.startsWith('event:')) {
      type = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      if (data.isNotEmpty) data.write('\n');
      data.write(line.substring(5).trimLeft());
    }
  }
}
