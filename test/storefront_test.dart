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
      if (path == '/api/v1/orders')
        return json({
          'error': 'validation_failed',
          'message': 'Check the order',
          'fields': {'items': 'required'}
        }, 422);
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
}
