import 'package:flutter/foundation.dart';

import 'models.dart';

/// Everything the customer decides at checkout other than the cart itself:
/// who they are, delivery or pickup, where to, how they will pay, a tip and
/// notes. Turned into the body of `POST /orders/quote` and `POST /orders`
/// by the same code, so the quote prices exactly what will be placed.
///
/// Holds no prices: the server derives every amount except the tip, which
/// is the one figure the customer chooses.
class StorefrontCheckout extends ChangeNotifier {
  static const fulfilments = ['delivery', 'pickup'];
  static const paymentMethods = ['cash', 'card', 'mobile_money', 'wallet'];

  String fulfilment = 'delivery';
  String? paymentMethod;
  int tipCents = 0;
  String? notes;

  String customerName = '';
  String customerPhone = '';
  String? customerEmail;

  /// A saved address; when set the server expands it and the inline
  /// fields below are not sent.
  String? addressId;
  String? addressLine1, addressLine2, city, region, postalCode;
  double? latitude, longitude;
  String? deliveryInstructions;

  /// One of the store's named places, priced by the store instead of by
  /// distance (`GET /stores/{id}/delivery-options`).
  String? deliveryPresetId;

  bool get delivery => fulfilment == 'delivery';

  /// Applies [changes] by field name (`tip_cents`, `notes`, …), the names a
  /// Studio form or a JSON body uses. Unknown names are ignored.
  void update(Map<String, dynamic> changes) {
    String? text(dynamic value) {
      final string = value?.toString().trim();
      return string == null || string.isEmpty ? null : string;
    }

    changes.forEach((key, value) {
      switch (key) {
        case 'fulfilment':
        case 'fulfilment_type':
          // The Studio preview calls a pickup "collection".
          final next = value == 'collection' ? 'pickup' : '$value';
          if (fulfilments.contains(next)) fulfilment = next;
        case 'payment_method':
          final next = text(value);
          paymentMethod =
              next != null && paymentMethods.contains(next) ? next : null;
        case 'tip_cents':
          tipCents = value is num ? value.round().clamp(0, 100000000) : 0;
        case 'notes':
          notes = text(value);
        case 'customer_name':
          customerName = text(value) ?? '';
        case 'customer_phone':
          customerPhone = text(value) ?? '';
        case 'customer_email':
          customerEmail = text(value);
        case 'delivery_address_id':
          addressId = text(value);
        case 'delivery_address_line1':
          addressLine1 = text(value);
        case 'delivery_address_line2':
          addressLine2 = text(value);
        case 'delivery_city':
          city = text(value);
        case 'delivery_region':
          region = text(value);
        case 'delivery_postal_code':
          postalCode = text(value);
        case 'delivery_latitude':
          latitude = value is num ? value.toDouble() : null;
        case 'delivery_longitude':
          longitude = value is num ? value.toDouble() : null;
        case 'delivery_instructions':
          deliveryInstructions = text(value);
        case 'delivery_preset_id':
          deliveryPresetId = text(value);
      }
    });
    notifyListeners();
  }

  /// A tip of [percent] of [subtotalCents], rounded to the cent.
  void tipPercent(int percent, int subtotalCents) =>
      update({'tip_cents': (subtotalCents * percent / 100).round()});

  /// Fills the delivery point from a resolved location when nothing more
  /// specific was given.
  void useLocation(StorefrontLocation? location) {
    if (location == null) return;
    latitude ??= location.latitude;
    longitude ??= location.longitude;
    addressLine1 ??= location.label;
    notifyListeners();
  }

  /// What a quote needs: pricing inputs only.
  Json quoteBody(String storeId, List<Json> items) => {
        'store_id': storeId,
        'fulfilment_type': fulfilment,
        if (paymentMethod != null) 'payment_method': paymentMethod,
        if (delivery) ...{
          if (latitude != null && longitude != null) ...{
            'delivery_latitude': latitude,
            'delivery_longitude': longitude,
          },
          if (deliveryPresetId != null) 'delivery_preset_id': deliveryPresetId,
        },
        'tip_cents': tipCents,
        'items': items,
      };

  /// The order itself: [quoteBody] plus who it is for and where it goes.
  Json orderBody(String storeId, List<Json> items) => {
        ...quoteBody(storeId, items),
        'customer_name': customerName,
        'customer_phone': customerPhone,
        if (customerEmail != null) 'customer_email': customerEmail,
        if (notes != null) 'notes': notes,
        if (delivery) ...{
          if (addressId != null)
            'delivery_address_id': addressId
          else ...{
            if (addressLine1 != null) 'delivery_address_line1': addressLine1,
            if (addressLine2 != null) 'delivery_address_line2': addressLine2,
            if (city != null) 'delivery_city': city,
            if (region != null) 'delivery_region': region,
            if (postalCode != null) 'delivery_postal_code': postalCode,
          },
          if (deliveryInstructions != null)
            'delivery_instructions': deliveryInstructions,
        },
      };

  /// What Studio pages read as `checkout.*`.
  Json toJson() => {
        'fulfilment': fulfilment,
        'payment_method': paymentMethod,
        'tip_cents': tipCents,
        'notes': notes,
        'customer_name': customerName,
        'customer_phone': customerPhone,
        'customer_email': customerEmail,
        'delivery_address_id': addressId,
        'delivery_address_line1': addressLine1,
        'delivery_address_line2': addressLine2,
        'delivery_instructions': deliveryInstructions,
        'delivery_preset_id': deliveryPresetId,
      };

  /// After an order is placed: the per-order choices start over, who the
  /// customer is and where they live are kept for next time.
  void resetForNextOrder() {
    tipCents = 0;
    notes = null;
    deliveryInstructions = null;
    notifyListeners();
  }
}
