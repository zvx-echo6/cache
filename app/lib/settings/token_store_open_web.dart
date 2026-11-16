import 'package:cache_search/cache_search.dart' show HttpTransport;

import '../video/token_store.dart';
import 'server_token_store.dart';

/// In a browser the keys are kept on Cache for Linux (its keystore), not in the browser.
final TokenStore _store = ServerTokenStore(HttpTransport());
TokenStore platformTokenStore() => _store;
