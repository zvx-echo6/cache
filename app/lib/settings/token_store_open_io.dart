import '../video/token_store.dart';

/// Where this platform keeps keys and tokens: the phone's secure storage.
TokenStore platformTokenStore() => const SecureTokenStore();
