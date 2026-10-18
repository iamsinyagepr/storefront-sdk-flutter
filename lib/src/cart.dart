import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// One cart line: a product with its chosen options, as it was when added.
/// The unit price is a display figure only — the server re-derives every
/// price when the order is quoted or placed.
class CartLine {
  CartLine({
    required this.id,
    required this.product,
    required this.quantity,
    required this.unitCents,
    this.choices = const [],
    this.selections = const [],
  });

  final String id;

  /// The product's JSON as the menu sent it.
  final Map<String, dynamic> product;
  int quantity;
  final int unitCents;
  final List<String> choices;
  final List<Map<String, dynamic>> selections;

  String get productId => '${product['id']}';
  String get name => '${product['name'] ?? ''}';
  int get totalCents => unitCents * quantity;

  /// For bindings: what a page reads as `line.name`, `line.quantity`…
  Map<String, dynamic> toJson() => {
        'id': id,
        'product': product,
        'product_id': productId,
        'name': name,
        'quantity': quantity,
        'unit_cents': unitCents,
        'line_total_cents': totalCents,
        'choices': choices,
      };

  /// The order API's item: `{product_id, quantity, selections}`.
  Map<String, dynamic> toOrderItem() =>
      {'product_id': productId, 'quantity': quantity, 'selections': selections};
}

/// The customer's cart, kept on the device until the order is placed.
class StorefrontCart extends ChangeNotifier {
  final List<CartLine> _lines = [];
  var _next = 0;

  /// The store the cart belongs to; adding from another store starts over.
  String? storeId;

  List<CartLine> get lines => List.unmodifiable(_lines);
  bool get isEmpty => _lines.isEmpty;
  int get count => _lines.fold(0, (sum, line) => sum + line.quantity);
  int get totalCents => _lines.fold(0, (sum, line) => sum + line.totalCents);

  CartLine add(
    Map<String, dynamic> product, {
    int quantity = 1,
    required int unitCents,
    List<String> choices = const [],
    List<Map<String, dynamic>> selections = const [],
    String? storeId,
  }) {
    if (storeId != null && this.storeId != null && storeId != this.storeId)
      _lines.clear();
    this.storeId = storeId ?? this.storeId;
    final line = CartLine(
      id: 'line-${++_next}',
      product: product,
      quantity: quantity.clamp(1, 99),
      unitCents: unitCents,
      choices: choices,
      selections: selections,
    );
    _lines.add(line);
    notifyListeners();
    return line;
  }

  /// Changes a line's quantity by [delta]; at zero the line is removed.
  void change(String id, int delta) {
    for (final line in _lines) {
      if (line.id == id) line.quantity = math.min(99, line.quantity + delta);
    }
    _lines.removeWhere((line) => line.quantity <= 0);
    notifyListeners();
  }

  void remove(String id) {
    _lines.removeWhere((line) => line.id == id);
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }

  List<Map<String, dynamic>> orderItems() =>
      [for (final line in _lines) line.toOrderItem()];
}
