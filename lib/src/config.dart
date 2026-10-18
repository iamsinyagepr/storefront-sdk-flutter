/// The only environment coupling this package has: which tenant API to call.
class StorefrontConfig {
  StorefrontConfig({required String apiBaseUrl, this.storeId})
      : apiBaseUrl = normalizeApiBaseUrl(apiBaseUrl);

  /// The tenant API's origin, e.g. `https://shop.upskalelabs.dev` — without
  /// the `/api/v1` prefix, which the client adds.
  final String apiBaseUrl;

  /// A single-store app's own store id or slug, when it has one.
  final String? storeId;
}

/// An HTTP(S) base URL without credentials, query or fragment, and without a
/// trailing `/api/v1` or slash — the same rule as the TypeScript SDK.
String normalizeApiBaseUrl(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw ArgumentError.value(input, 'apiBaseUrl',
        'Use an HTTP(S) tenant API URL without credentials or query parameters');
  }
  return uri
      .toString()
      .replaceFirst(RegExp(r'/api/v1/?$'), '')
      .replaceFirst(RegExp(r'/$'), '');
}
