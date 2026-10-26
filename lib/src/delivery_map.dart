import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// A map to confirm where a delivery goes, for a store that prices delivery
/// by distance: the pin starts at [latitude], [longitude] (the customer's
/// location, or the store), a tap moves it, and the button hands the point
/// to [onConfirm] — typically [StorefrontCheckout.confirmDeliveryPoint].
///
/// OpenStreetMap tiles, credited on the map; no API key.
class StorefrontDeliveryMap extends StatefulWidget {
  const StorefrontDeliveryMap({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.onConfirm,
    this.confirmed = false,
    this.height = 240,
    this.buttonLabel = 'Confirm this location',
    this.accent,
    this.radius = 12,
  });

  final double latitude, longitude;
  final void Function(double latitude, double longitude) onConfirm;

  /// Whether the point shown is the one already confirmed.
  final bool confirmed;
  final double height;
  final String buttonLabel;
  final Color? accent;
  final double radius;

  @override
  State<StorefrontDeliveryMap> createState() => _StorefrontDeliveryMapState();
}

class _StorefrontDeliveryMapState extends State<StorefrontDeliveryMap> {
  late LatLng pin = LatLng(widget.latitude, widget.longitude);
  bool moved = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent ?? Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: SizedBox(
            height: widget.height,
            child: FlutterMap(
              options: MapOptions(
                initialCenter: pin,
                initialZoom: 16,
                onTap: (_, point) => setState(() {
                  pin = point;
                  moved = true;
                }),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'dev.upskalelabs.storefront',
                ),
                MarkerLayer(markers: [
                  Marker(
                    point: pin,
                    width: 40,
                    height: 40,
                    alignment: Alignment.topCenter,
                    child: Icon(Icons.location_on, size: 40, color: accent),
                  ),
                ]),
                // The tiles' credit, shortened rather than overflowing a narrow map.
                Align(
                  alignment: Alignment.bottomRight,
                  child: Container(
                    color: const Color(0xccffffff),
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: const Text('© OpenStreetMap contributors',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: Color(0xff333333))),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: accent),
          onPressed: () {
            widget.onConfirm(pin.latitude, pin.longitude);
            setState(() => moved = false);
          },
          icon: Icon(widget.confirmed && !moved ? Icons.check : Icons.location_on),
          label: Text(widget.confirmed && !moved ? 'Location confirmed' : widget.buttonLabel),
        ),
      ],
    );
  }
}
