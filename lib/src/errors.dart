/// The tenant API's error envelope, shared by every route — see
/// `internal/server/response.go` in live-upskale-labs. [fields] is only ever
/// present on a 422 `validation_failed`. A [status] of 0 means the request
/// never reached the server.
/// Why the device's location couldn't be had: the customer said no (or
/// "never ask again"), location is switched off, or it took too long. The
/// location page offers search and the business's cities instead.
enum LocationProblem { denied, deniedForever, servicesOff, timeout, unsupported }

class StorefrontLocationError implements Exception {
  const StorefrontLocationError(this.problem);

  final LocationProblem problem;

  /// A sentence to show the customer.
  String get message => switch (problem) {
        LocationProblem.denied => 'Location permission was not given.',
        LocationProblem.deniedForever =>
          'Location is blocked for this app. Allow it in settings, or search below.',
        LocationProblem.servicesOff => 'Location is switched off on this device.',
        LocationProblem.timeout => 'Your location took too long to find.',
        LocationProblem.unsupported => 'This device can\'t share its location.',
      };

  @override
  String toString() => message;
}

class StorefrontApiError implements Exception {
  const StorefrontApiError(this.status, this.error, this.message,
      [this.fields]);

  final int status;
  final String error;
  final String message;
  final Map<String, String>? fields;

  @override
  String toString() => message;
}
