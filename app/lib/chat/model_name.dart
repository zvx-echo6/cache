/// Turns llama.cpp's model description (for example "gemma4 E2B Q4_K - Medium") into a name for
/// people (for example "Gemma 4 E2B · Q4_K_M"). Anything it cannot read is shown as it came.
String prettyModelName(String description) {
  final desc = description.trim();
  if (desc.isEmpty) return '';
  final tokens = desc.split(RegExp(r'\s+'));
  final quantAt = tokens.indexWhere((t) => RegExp(r'^(I?Q\d|BF16$|F16$|F32$|MXFP)', caseSensitive: false).hasMatch(t));

  final nameTokens = quantAt < 0 ? tokens : tokens.sublist(0, quantAt);
  if (nameTokens.isEmpty) return desc;
  final name = <String>[];
  for (var i = 0; i < nameTokens.length; i++) {
    name.add(i == 0 ? _arch(nameTokens[i]) : nameTokens[i]);
  }

  if (quantAt < 0) return name.join(' ');
  var quant = tokens[quantAt];
  // "Q4_K - Medium" -> "Q4_K_M"; other suffixes ("- 4.25 bpw") are dropped.
  final rest = tokens.sublist(quantAt + 1).where((t) => t != '-').toList();
  if (rest.isNotEmpty) {
    final size = const {'small': 'S', 'medium': 'M', 'large': 'L'}[rest.first.toLowerCase()];
    if (size != null) quant = '${quant}_$size';
  }
  return '${name.join(' ')} · $quant';
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
