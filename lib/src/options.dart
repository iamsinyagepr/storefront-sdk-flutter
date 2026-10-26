import 'dart:math' as math;

/// One choice in an option group, e.g. "Large (+R20)". Its [groups] open
/// once it is chosen (a side that comes with a large portion).
class OptionChoice {
  const OptionChoice(
      {required this.id,
      required this.label,
      this.priceCents = 0,
      this.groups = const []});

  final String id, label;

  /// Added to the product's display price; may be negative.
  final int priceCents;
  final List<OptionGroup> groups;
}

/// A product's option group with how many choices it needs ([min]) and
/// allows ([max]).
class OptionGroup {
  const OptionGroup(
      {required this.id,
      required this.label,
      this.min = 0,
      this.max = 1,
      this.choices = const []});

  final String id, label;
  final int min, max;
  final List<OptionChoice> choices;
  bool get required => min > 0;
  bool get single => max == 1;

  /// A product's groups from the tenant API's `addon_groups` (name,
  /// min_select, max_select, is_required, options[].price_delta_cents,
  /// child_group), or from the Studio preview's shape (label, min, max,
  /// choices[].price, groups). Inactive groups and unavailable options are
  /// left out.
  static List<OptionGroup> fromProduct(dynamic product) =>
      parse(product is Map ? product['addon_groups'] : null);

  static List<OptionGroup> parse(dynamic groups, [int depth = 0]) {
    if (groups is! List || depth > 6) return const [];
    int number(dynamic value) => value is num ? value.round() : 0;
    return [
      for (final group in groups.take(20))
        if (group is Map && group['is_active'] != false)
          OptionGroup(
            id: '${group['id']}',
            label: '${group['label'] ?? group['name'] ?? ''}',
            min: group.containsKey('min')
                ? number(group['min'])
                : math.max(number(group['min_select']),
                    group['is_required'] == true ? 1 : 0),
            max: math.max(
                1,
                number(group.containsKey('max')
                    ? group['max']
                    : group['max_select'])),
            choices: [
              for (final choice
                  in ((group['choices'] ?? group['options']) as List?)
                          ?.take(40) ??
                      const [])
                if (choice is Map && choice['is_available'] != false)
                  OptionChoice(
                    id: '${choice['id']}',
                    label: '${choice['label'] ?? choice['name'] ?? ''}',
                    priceCents:
                        number(choice['price'] ?? choice['price_delta_cents']),
                    groups: parse(
                        choice['groups'] ??
                            (choice['child_group'] is Map
                                ? [choice['child_group']]
                                : null),
                        depth + 1),
                  ),
            ],
          ),
    ];
  }
}

/// A product's groups as a page reads them (the `optionGroups` binding):
/// each group with its choices marked selected or disabled (a full
/// multi-choice group), and right after it the groups of each selected
/// choice, one [depth] deeper — the order a page lays them out in.
List<Map<String, dynamic>> optionGroupBindings(
    List<OptionGroup> groups, Map<String, List<String>> selected,
    [int depth = 0]) {
  final out = <Map<String, dynamic>>[];
  for (final group in groups) {
    final ids = selected[group.id] ?? const <String>[];
    out.add({
      'id': group.id,
      'label': group.label,
      'min': group.min,
      'max': group.max,
      'single': group.single,
      'required': group.required,
      'depth': depth,
      'selected_count': ids.length,
      'choices': [
        for (final choice in group.choices)
          {
            'id': choice.id,
            'label': choice.label,
            'price_cents': choice.priceCents,
            'selected': ids.contains(choice.id),
            'disabled': !ids.contains(choice.id) &&
                !group.single &&
                ids.length >= group.max,
          },
      ],
    });
    for (final choice in group.choices) {
      if (ids.contains(choice.id)) {
        out.addAll(optionGroupBindings(choice.groups, selected, depth + 1));
      }
    }
  }
  return out;
}

/// The group [id] among [groups], or among their choices' groups.
OptionGroup? findOptionGroup(List<OptionGroup> groups, String id) {
  for (final group in groups) {
    if (group.id == id) return group;
    for (final choice in group.choices) {
      final nested = findOptionGroup(choice.groups, id);
      if (nested != null) return nested;
    }
  }
  return null;
}

/// What a set of chosen option ids comes to.
class OptionSelection {
  const OptionSelection(
      {required this.valid,
      required this.labels,
      required this.priceCents,
      required this.selections});

  /// Every group has between min and max of its own choices.
  final bool valid;

  /// The chosen choices' labels, nested choices after their parent.
  final List<String> labels;

  /// What the choices add to one unit.
  final int priceCents;

  /// The order API's `selections`: [{addon_id, quantity, children}].
  final List<Map<String, dynamic>> selections;

  /// [selected] maps a group id to the chosen choice ids.
  static OptionSelection of(
      List<OptionGroup> groups, Map<String, List<String>> selected) {
    var valid = true, price = 0;
    final labels = <String>[];
    final selections = <Map<String, dynamic>>[];
    for (final group in groups) {
      final ids = selected[group.id] ?? const <String>[];
      if (ids.length < group.min ||
          ids.length > group.max ||
          ids.toSet().length != ids.length ||
          ids.any((id) => !group.choices.any((choice) => choice.id == id))) {
        valid = false;
      }
      for (final choice
          in group.choices.where((choice) => ids.contains(choice.id))) {
        final nested = of(choice.groups, selected);
        valid = valid && nested.valid;
        price += choice.priceCents + nested.priceCents;
        labels
          ..add(choice.label)
          ..addAll(nested.labels);
        selections.add({
          'addon_id': choice.id,
          'quantity': 1,
          'children': nested.selections
        });
      }
    }
    return OptionSelection(
        valid: valid,
        labels: labels,
        priceCents: price,
        selections: selections);
  }
}
