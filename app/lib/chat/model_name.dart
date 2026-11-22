/// Turns llama.cpp's model description (for example "gemma4 E2B Q4_K - Medium") into a name for
/// people (for example "Gemma 4 E2B · Q4_K_M"). Anything it cannot read is shown as it came.
///
/// The quantisation comes from the model's metadata (general.file_type), which the description carries. When the file has
/// none, llama.cpp guesses it from the tensors and adds "(guessed)"; then the label in [fileName] is used if it has one.
String prettyModelName(String description, {String? fileName}) {
  final p = prettyModelParts(description, fileName: fileName);
  if (p == null) return '';
  return p.label == null ? p.name : '${p.name} · ${p.label}';
}

/// The two parts [prettyModelName] joins: the model's plain name ("Gemma 4 E2B") and its quantisation label ("Q4_K_M"; null when the
/// description and the file name have none). Null for an empty description. A description that cannot be read is the name, as it came.
({String name, String? label})? prettyModelParts(String description, {String? fileName}) {
  final desc = description.trim();
  if (desc.isEmpty) return null;
  final guessed = desc.endsWith('(guessed)');
  final tokens = desc.replaceFirst(RegExp(r'\s*\(guessed\)$'), '').split(RegExp(r'\s+'));
  final quantAt = tokens.indexWhere((t) => RegExp(r'^(I?Q\d|TQ\d|BF16$|F16$|F32$|MXFP|NVFP)', caseSensitive: false).hasMatch(t));

  final nameTokens = quantAt < 0 ? tokens : tokens.sublist(0, quantAt);
  if (nameTokens.isEmpty) return (name: desc, label: null);
  final name = <String>[];
  for (var i = 0; i < nameTokens.length; i++) {
    name.add(i == 0 ? _arch(nameTokens[i]) : nameTokens[i]);
  }

  final fromFile = (guessed || quantAt < 0) && fileName != null ? quantFromFileName(fileName) : null;
  if (fromFile != null) return (name: name.join(' '), label: fromFile);
  if (quantAt < 0) return (name: name.join(' '), label: null);
  return (name: name.join(' '), label: _ftypeLabel(tokens.sublist(quantAt)));
}

/// llama.cpp's file type names (llama_model_ftype_name) as the labels quantised files carry: "Q4_K - Medium" -> "Q4_K_M",
/// "IQ4_XS - 4.25 bpw" -> "IQ4_XS". Two names do not follow the pattern: plain Q2_K is called "Q2_K - Medium", and IQ3_M is
/// called "IQ3_S mix".
String _ftypeLabel(List<String> tokens) {
  final quant = tokens.first;
  final rest = tokens.skip(1).where((t) => t != '-').toList();
  final next = rest.isEmpty ? '' : rest.first.toLowerCase();
  if (quant.toUpperCase() == 'Q2_K' && next == 'medium') return 'Q2_K';
  if (quant.toUpperCase() == 'IQ3_S' && next == 'mix') return 'IQ3_M';
  if (quant.toUpperCase() == 'MXFP4' && next == 'moe') return 'MXFP4_MOE';
  // Other suffixes ("4.25 bpw", "ternary") are dropped.
  final size = const {'small': 'S', 'medium': 'M', 'large': 'L'}[next];
  return size == null ? quant : '${quant}_$size';
}

/// What a model is called on screen: the name and label of [prettyModelParts], except that a model that is not on Cache's recommended
/// list ([recommended] false) takes the name the file itself carries ([generalName], the GGUF's `general.name`), because llama.cpp's
/// size guess in the description can be wrong ("llama 256M" for a 135M model). The quantisation label is unchanged. A recommended
/// model, a missing or empty [generalName], or an empty description leave [prettyModelParts]'s answer as it is.
({String name, String? label})? modelNameParts(String description, {String? fileName, String? generalName, bool recommended = false}) {
  final p = prettyModelParts(description, fileName: fileName);
  if (p == null || recommended) return p;
  final g = _tidyName(generalName);
  return g == null ? p : (name: g, label: p.label);
}

/// A model's own name with its white space collapsed and cut at [_maxNameLength]; null when nothing is left.
String? _tidyName(String? s) {
  if (s == null) return null;
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return null;
  return t.length <= _maxNameLength ? t : t.substring(0, _maxNameLength).trimRight();
}

const int _maxNameLength = 120;

/// The quantisation label in a model's file name, for example "UD-Q2_K_XL" in "gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf",
/// "IQ4_XS" in "gemma-4-E2B-it-IQ4_XS.gguf" or "Q4_K_M" in "llama-2-7b-chat.Q4_K_M.gguf"; null when it has none. The name
/// is split at "-" and "."; the last part that is a quantisation type wins, with Unsloth's "UD-" (dynamic) kept in front.
String? quantFromFileName(String fileName) {
  final stem = fileName.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.gguf$', caseSensitive: false), '');
  final parts = stem.split(RegExp(r'[-.]'));
  final type = RegExp(r'^(I?Q\d(_[A-Z0-9]+)*|TQ\d_\d|BF16|F16|FP16|F32|MXFP4(_MOE)?)$', caseSensitive: false);
  for (var i = parts.length - 1; i >= 0; i--) {
    if (!type.hasMatch(parts[i])) continue;
    var q = parts[i].toUpperCase();
    if (q == 'FP16') q = 'F16';
    return i > 0 && parts[i - 1].toUpperCase() == 'UD' ? 'UD-$q' : q;
  }
  return null;
}

/// "gemma4" -> "Gemma 4", "llama" -> "Llama", "qwen3" -> "Qwen 3".
String _arch(String s) {
  final m = RegExp(r'^([A-Za-z]+)(\d+(?:\.\d+)?)?$').firstMatch(s);
  if (m == null) return s;
  final word = m.group(1)!;
  final cap = '${word[0].toUpperCase()}${word.substring(1)}';
  final num = m.group(2);
  return num == null ? cap : '$cap $num';
}
