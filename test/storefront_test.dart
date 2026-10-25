import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:upskale_storefront/upskale_storefront.dart';

final _store = {
  'id': 'store-1',
  'name': 'Sunday Kitchen',
  'slug': 'sunday',
  'currency': 'ZAR',
  'is_open': true,
  'city': 'Johannesburg',
};
final _burger = {
  'id': 'burger',
  'name': 'Burger',
  'display_price_cents': 6900,
  'price_cents': 1,
  'is_available': true,
  'addon_groups': [
    {
      'id': 'portion',
      'name': 'Portion',
      'is_required': true,
      'min_select': 1,
      'max_select': 1,
      'options': [
        {'id': 'regular', 'name': 'Regular', 'price_delta_cents': 0},
        {
          'id': 'large',
          'name': 'Large',
          'price_delta_cents': 2000,
          'child_group': {
            'id': 'side',
            'name': 'Side',
            'min_select': 1,
            'max_select': 1,
            'options': [
              {'id': 'fries', 'name': 'Fries', 'price_delta_cents': 0},
              {'id': 'salad', 'name': 'Salad', 'price_delta_cents': 500},
            ],
          },
        },
      ],
    },
    {
      'id': 'extras',
      'name': 'Extras',
      'max_select': 2,
      'options': [
        {'id': 'cheese', 'name': 'Cheese', 'price_delta_cents': 800},
        {'id': 'sauce', 'name': 'Sauce', 'price_delta_cents': 500},
        {
          'id': 'gone',
          'name': 'Gone',
          'price_delta_cents': 100,
          'is_available': false
        },
      ],
    },
  ],
};
final _fries = {
  'id': 'fries',
  'name': 'Fries',
  'display_price_cents': 3500,
  'is_available': true,
  'addon_groups': []
};

/// A fake tenant API that records what it was asked.
MockClient _tenant(List<http.Request> calls) => MockClient((request) async {
      calls.add(request);
      final path = request.url.path;
      http.Response json(Object body, [int status = 200]) =>
          http.Response(jsonEncode(body), status,
              headers: {'content-type': 'application/json'});
      if (path == '/api/v1/stores')
        return json({
          'data': [_store],
          'next_cursor': null,
          'search': {'radius_km': 10, 'widened': false}
        });
      if (path == '/api/v1/stores/store-1/menu') {
        return json({
          'store': _store,
          'categories': [
            {
              'id': 'mains',
              'name': 'Mains',
              'products': [_burger]
            },
          ],
          'uncategorised': [
            _fries,
            {..._fries, 'id': 'hidden', 'is_available_online': false}
          ],
        });
      }
      if (path == '/api/v1/cuisines')
        return json({
          'data': [
            {'name': 'Burgers', 'store_count': 1}
          ],
          'next_cursor': null
        });
      if (path == '/api/v1/stores/store-1/delivery-options')
        return json({'mode': 'distance'});
      if (path == '/api/v1/auth/guest') {
        return json({
          'token': 'guest-token',
          'expires_at': '2030-01-01T00:00:00Z',
          'user': {'id': 'u1', 'is_anonymous': true}
        });
      }
      if (path == '/api/v1/places/autocomplete') {
        if (request.headers['Authorization'] != 'Bearer guest-token')
          return json({'error': 'unauthorized', 'message': 'Sign in'}, 401);
        return json({
          'data': [
            {
              'place_id': 'p1',
              'main_text': 'Sandton',
              'secondary_text': 'Johannesburg'
            }
          ]
        });
      }
      if (path == '/api/v1/places/details') {
        return json({
          'place_id': 'p1',
          'name': 'Sandton',
          'address': 'Sandton, Johannesburg',
          'latitude': -26.1,
          'longitude': 28.05
        });
      }
      if (path == '/api/v1/orders/quote') {
        final body = jsonDecode(request.body) as Map;
        final tip = body['tip_cents'] as int;
        return json({
          'currency': 'ZAR',
          'items_subtotal_cents': 6900,
          'charges': [
            if (body['payment_method'] == 'card')
              {'name': 'Card fee', 'amount_cents': 300}
          ],
          'delivery_fee_cents': 2500,
          'tip_cents': tip,
          'total_cents':
              6900 + 2500 + tip + (body['payment_method'] == 'card' ? 300 : 0),
        });
      }
      if (path == '/api/v1/orders' && request.method == 'POST') {
        final body = jsonDecode(request.body) as Map;
        if (body['customer_name'] == null)
          return json({
            'error': 'validation_failed',
            'message': 'Check the order',
            'fields': {'items': 'required'}
          }, 422);
        return json({
          'id': 'o1',
          'order_number': 'A100',
          'status': 'pending',
          'store_id': body['store_id'],
          'fulfilment_type': body['fulfilment_type'],
          'tip_cents': body['tip_cents'],
          'total_cents': 9400 + (body['tip_cents'] as int),
          'items': body['items'],
        }, 201);
      }
      if (path == '/api/v1/orders/o1/events')
        return http.Response(
            ': connected\n\n'
            'event: status\ndata: {"order_id":"o1","status":"confirmed"}\n\n'
            'event: driver_location\ndata: {"order_id":"o1","latitude":-26.2,"longitude":28.1}\n\n'
            'event: status\ndata: {"order_id":"o1","status":"delivered"}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'});
      if (path == '/api/v1/orders/o1/review' && request.method == 'POST') {
        final body = jsonDecode(request.body) as Map;
        return json({'id': 'r1', 'order_id': 'o1', ...body}, 201);
      }
      if (path == '/api/v1/stores/store-1/reviews')
        return json({
          'data': [
            {'id': 'r0', 'order_id': 'o0', 'food_rating': 5}
          ],
          'next_cursor': null
        });
      return json({'error': 'not_found', 'message': 'No route'}, 404);
    });

void main() {
  test('base URLs are normalised and unsafe ones refused', () {
    expect(normalizeApiBaseUrl(' https://shop.example.com/api/v1/ '),
        'https://shop.example.com');
    expect(
        normalizeApiBaseUrl('http://localhost:8080/'), 'http://localhost:8080');
    for (final bad in [
      'ftp://x.com',
      'https://user:pw@x.com',
      'https://x.com?a=1',
      'not a url'
    ]) {
      expect(() => normalizeApiBaseUrl(bad), throwsArgumentError, reason: bad);
    }
  });

  test(
      'location search starts a guest session, then stores are searched near the point',
      () async {
    final calls = <http.Request>[];
    final storefront = Storefront.configure(
        apiBaseUrl: 'https://shop.example.com', client: _tenant(calls));
    final predictions = await storefront.searchAddresses('Sand');
    expect(predictions.single.mainText, 'Sandton');
    expect(calls.where((call) => call.url.path == '/api/v1/auth/guest'),
        hasLength(1));
    storefront.setLocation(await storefront.resolveAddress('p1'));
    expect(storefront.location!.label, 'Sandton, Johannesburg');

    final stores = await storefront.searchStores(query: 'sunday');
    expect(stores.single.name, 'Sunday Kitchen');
    final search = calls
        .lastWhere((call) => call.url.path == '/api/v1/stores')
        .url
        .queryParameters;
    expect(search, containsPair('q', 'sunday'));
    expect(search, containsPair('latitude', '-26.1'));
    expect(search, containsPair('status', 'active'));
    // The catalogue is public: no token on it.
    expect(calls.last.headers.containsKey('Authorization'), isFalse);
  });

  test('opening a store loads its menu, and bindings use the preview names',
      () async {
    final storefront = Storefront.configure(
        apiBaseUrl: 'https://shop.example.com', client: _tenant([]));
    await storefront.selectStore('store-1');
    expect(storefront.menuStatus, StorefrontStatus.ready);
    expect(
        storefront.products.map((product) => product.id), ['burger', 'fries']);
    final bindings = storefront.bindings();
    expect((bindings['store'] as Map)['name'], 'Sunday Kitchen');
    expect((bindings['categories'] as List).single['name'], 'Mains');
    expect((bindings['cuisines'] as List).single['name'], 'Burgers');
    expect(bindings['cartCount'], 0);
  });

  test('options price nested choices and become order selections', () {
    final storefront = Storefront();
    final groups = OptionGroup.fromProduct(_burger);
    expect(groups.map((group) => group.label), ['Portion', 'Extras']);
    expect(groups[1].choices.map((choice) => choice.id), ['cheese', 'sauce'],
        reason: 'unavailable options are left out');
    expect(storefront.addConfigured(_burger), AddToCartResult.needsOptions);
    storefront.toggle(_burger, groups[0], groups[0].choices[1]);
    expect(storefront.configuration(_burger).valid, isFalse,
        reason: 'Large needs a side');
    storefront.choose(_burger, 'side', ['salad']);
    storefront.toggle(_burger, groups[1], groups[1].choices[0]);
    final selection = storefront.configuration(_burger);
    expect(selection.valid, isTrue);
    expect(selection.priceCents, 2000 + 500 + 800);
    expect(selection.labels, ['Large', 'Salad', 'Cheese']);
    expect(selection.selections.first, {
      'addon_id': 'large',
      'quantity': 1,
      'children': [
        {'addon_id': 'salad', 'quantity': 1, 'children': []}
      ],
    });

    expect(
        storefront.addConfigured(_burger, quantity: 2), AddToCartResult.added);
    expect(storefront.cart.totalCents, (6900 + 3300) * 2);
    expect(storefront.add(_burger), AddToCartResult.needsOptions);
    expect(storefront.add(_fries), AddToCartResult.added);
    expect(storefront.add({..._fries, 'is_available': false}),
        AddToCartResult.unavailable);
    expect(storefront.cart.count, 3);
    expect(storefront.cart.orderItems().first['product_id'], 'burger');
    storefront.cart.change(storefront.cart.lines.last.id, -1);
    expect(storefront.cart.count, 2);
    // Choosing for another product starts over.
    storefront.choose(_fries, 'x', ['y']);
    expect(storefront.selectionsFor(_burger), isEmpty);
  });

  test('the Studio preview option shape parses the same way', () {
    final groups = OptionGroup.parse([
      {
        'id': 'portion',
        'label': 'Choose',
        'min': 1,
        'max': 1,
        'choices': [
          {
            'id': 'large',
            'label': 'Large',
            'price': 2000,
            'groups': [
              {
                'id': 'side',
                'label': 'Side',
                'min': 1,
                'max': 1,
                'choices': [
                  {'id': 'fries', 'label': 'Fries', 'price': 0}
                ]
              },
            ]
          },
        ]
      },
    ]);
    expect(groups.single.required, isTrue);
    expect(groups.single.choices.single.groups.single.label, 'Side');
  });

  test(
      'checkout quotes and places the same body, tip and notes included, then follows the order',
      () async {
    final calls = <http.Request>[];
    final storefront = Storefront.configure(
        apiBaseUrl: 'https://shop.example.com', client: _tenant(calls));
    await storefront.selectStore('store-1');
    storefront.add(_fries);
    storefront.cart.setNotes(storefront.cart.lines.single.id, ' no salt ');
    storefront.checkout.update({
      'fulfilment': 'delivery',
      'payment_method': 'card',
      'tip_cents': 1500,
      'notes': 'Ring twice',
      'customer_name': 'Ama',
      'customer_phone': '+27820000000',
      'delivery_address_line1': '1 Main Road',
      'delivery_instructions': 'Blue gate',
    });

    final quote = await storefront.refreshQuote();
    expect(quote!.tipCents, 1500);
    expect(quote.charges.single['name'], 'Card fee');
    expect(quote.totalCents, 6900 + 2500 + 1500 + 300);
    expect(storefront.bindings()['quote'], containsPair('tip_cents', 1500));

    final order = await storefront.placeOrder();
    final quoted = jsonDecode(calls
        .firstWhere((call) => call.url.path == '/api/v1/orders/quote')
        .body) as Map;
    final placed = jsonDecode(calls
        .lastWhere((call) =>
            call.url.path == '/api/v1/orders' && call.method == 'POST')
        .body) as Map;
    // The quote prices exactly what is placed.
    for (final key in [
      'store_id',
      'fulfilment_type',
      'payment_method',
      'tip_cents',
      'items'
    ]) expect(placed[key], quoted[key], reason: key);
    expect(placed['items'].single['notes'], 'no salt');
    expect(placed['notes'], 'Ring twice');
    expect(placed['delivery_instructions'], 'Blue gate');
    expect(quoted.containsKey('customer_name'), isFalse);
    expect(order.tipCents, 1500);
    expect(storefront.cart.isEmpty, isTrue);
    expect(storefront.checkout.tipCents, 0, reason: 'tip is per order');
    expect(storefront.checkout.customerName, 'Ama', reason: 'details are kept');

    // Live events move the order along.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(storefront.order!.status, 'delivered');
    expect(storefront.orders.single.status, 'delivered');
    expect(
        calls
            .lastWhere((call) => call.url.path == '/api/v1/orders/o1/events')
            .headers['Authorization'],
        'Bearer guest-token');

    final review = await storefront.submitReview(
        foodRating: 5, foodComment: ' Lovely ', deliveryRating: 4);
    expect(review.foodRating, 5);
    expect(review.foodComment, 'Lovely');
    expect(review.deliveryRating, 4);
    expect((await storefront.loadReviews()).single.foodRating, 5);
    expect(storefront.bindings()['review'], containsPair('food_rating', 5));
  });

  test('event streams skip comments, unknown frames and torn data', () async {
    final events = await parseOrderEvents(Stream.value(
            utf8.encode(': ping\n\nevent: status\ndata: {"status":"ready"}\n\n'
                'event: other\ndata: {}\n\nevent: status\ndata: {broken\n\n')))
        .toList();
    expect(events.map((event) => event.status), ['ready']);
  });

  test(
      'a pickup tip is a percentage of the subtotal and pickups send no address',
      () {
    final checkout = StorefrontCheckout()
      ..update({
        'fulfilment': 'collection',
        'delivery_address_line1': '1 Main Road',
        'payment_method': 'bitcoin',
      })
      ..tipPercent(10, 6950);
    expect(checkout.fulfilment, 'pickup');
    expect(checkout.paymentMethod, isNull,
        reason: 'unknown methods are dropped');
    expect(checkout.tipCents, 695);
    final body = checkout.orderBody('s', const []);
    expect(body.containsKey('delivery_address_line1'), isFalse);
    expect(body['tip_cents'], 695);
  });

  test('API errors carry the envelope, including validation fields', () async {
    final api = StorefrontApi(
        StorefrontConfig(apiBaseUrl: 'https://shop.example.com'),
        client: _tenant([]));
    await expectLater(
      api.createOrder({}),
      throwsA(isA<StorefrontApiError>()
          .having((error) => error.status, 'status', 422)
          .having((error) => error.fields, 'fields', {'items': 'required'})),
    );
    final offline = StorefrontApi(
        StorefrontConfig(apiBaseUrl: 'https://shop.example.com'),
        client: MockClient((_) => throw Exception('down')));
    await expectLater(
        offline.cuisines(),
        throwsA(isA<StorefrontApiError>()
            .having((e) => e.error, 'error', 'offline')));
  });

  test('store cities and naming a point', () async {
    final calls = <http.Request>[];
    final api = StorefrontApi(
        StorefrontConfig(apiBaseUrl: 'https://shop.example.com'),
        token: () => 'guest-token',
        client: MockClient((request) async {
          calls.add(request);
          switch (request.url.path) {
            case '/api/v1/cities':
              return http.Response(
                  jsonEncode({
                    'data': [
                      {'name': 'Johannesburg', 'latitude': -26.15, 'longitude': 28.05, 'stores': 3},
                      {'name': 'Pretoria', 'latitude': -25.74, 'longitude': 28.19, 'stores': 1},
                    ]
                  }),
                  200);
            case '/api/v1/places/reverse':
              return http.Response(
                  jsonEncode({'label': 'Rosebank, Johannesburg', 'city': 'Johannesburg'}), 200);
          }
          return http.Response('{}', 404);
        }));
    final cities = await api.storeCities();
    expect(cities.map((c) => c.name), ['Johannesburg', 'Pretoria']);
    expect(cities.first.stores, 3);
    expect(cities.first.location.label, 'Johannesburg');
    expect(cities.first.location.latitude, -26.15);

    final point = await api.reverseGeocode(-26.1467, 28.0436);
    expect(point.label, 'Rosebank, Johannesburg');
    expect(point.latitude, -26.1467);
    final reverse = calls.last;
    expect(reverse.url.queryParameters, {'latitude': '-26.1467', 'longitude': '28.0436'});
    expect(reverse.headers['Authorization'], 'Bearer guest-token');
  });

  test('location problems read as sentences', () {
    for (final problem in LocationProblem.values) {
      expect(StorefrontLocationError(problem).message, isNotEmpty);
    }
  });

  test('a single-store app loads its store at once', () async {
    final calls = <http.Request>[];
    final storefront = Storefront.configure(
        apiBaseUrl: 'https://shop.example.com', storeId: 'store-1', client: _tenant(calls));
    expect(storefront.pinnedStoreId, 'store-1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls.any((request) => request.url.path == '/api/v1/stores/store-1/menu'), isTrue);
    expect(storefront.store?.id, 'store-1');
    // A store that won't load is the menu's error, not a crash.
    final missing = Storefront.configure(apiBaseUrl: 'https://shop.example.com', storeId: 'gone', client: _tenant([]));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(missing.menuStatus, StorefrontStatus.error);
    expect(Storefront.configure(apiBaseUrl: 'https://shop.example.com', client: _tenant([])).pinnedStoreId, isNull);
  });
}
