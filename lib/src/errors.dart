/// The tenant API's error envelope, shared by every route — see
/// `internal/server/response.go` in live-upskale-labs. [fields] is only ever
/// present on a 422 `validation_failed`. A [status] of 0 means the request
/// never reached the server.
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
