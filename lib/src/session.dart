import 'package:flutter/foundation.dart';

import 'client.dart';
import 'models.dart';

/// Where a session token is kept between launches. The default keeps it in
/// memory only; an app can persist it (shared_preferences, secure storage)
/// by implementing this.
abstract class StorefrontTokenStore {
  Future<String?> read();
  Future<void> write(String? token);
}

class MemoryTokenStore implements StorefrontTokenStore {
  String? _token;
  @override
  Future<String?> read() async => _token;
  @override
  Future<void> write(String? token) async => _token = token;
}

/// The customer's session with the tenant API. Location search needs one, so
/// [ensure] starts a guest session when there is none; signing up later
/// upgrades that guest in place.
class StorefrontSession extends ChangeNotifier {
  StorefrontSession(this.api, {StorefrontTokenStore? store})
      : _store = store ?? MemoryTokenStore() {
    api.token = () => token;
  }

  final StorefrontApi api;
  final StorefrontTokenStore _store;
  String? token;
  Me? user;
  Future<String>? _starting;

  bool get signedIn => token != null && user?.isAnonymous == false;

  /// A session token, starting a guest session if needed. Concurrent callers
  /// share one request.
  Future<String> ensure() async {
    token ??= await _store.read();
    if (token != null) return token!;
    return _starting ??= api.guest().then((session) async {
      await _set(session);
      return session.token;
    }).whenComplete(() => _starting = null);
  }

  Future<void> signIn(String email, String password) async =>
      _set(await api.signIn(email: email, password: password));

  Future<void> signUp(String email, String password,
          {String? displayName}) async =>
      _set(await api.signUp(
          email: email, password: password, displayName: displayName));

  Future<void> signOut() async {
    token = null;
    user = null;
    await _store.write(null);
    notifyListeners();
  }

  Future<void> _set(SessionIssued session) async {
    token = session.token;
    user = session.user;
    await _store.write(token);
    notifyListeners();
  }
}
