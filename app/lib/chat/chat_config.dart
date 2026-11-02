/// Whether chat requests ask the model to think before answering. Off by default: on a phone,
/// thinking makes answers much slower. One constant so it can become a setting later.
const bool kEnableThinking = false;

/// The most tokens one model request may generate (the eval's max_tokens, 2048). It guards against a reply that runs away; the
/// longest eval reply was 835 tokens. The engine stops at this count and the answer is what was generated.
const int kMaxTokens = 2048;
