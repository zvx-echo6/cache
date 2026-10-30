/// Three-way merge of text, word by word: what changed on one side since the last sync is kept with what changed on the other.
/// Only when both sides changed the same words (or one changed words the other removed) is there a conflict, and then Cache
/// asks. Used by the Obsidian and Logseq folders and by notebook sync between devices.
library;

/// The merged text, or the parts that need a decision.
class MergeResult {
  const MergeResult(this.text, {this.conflicts = 0});

  /// The merged text; when there are conflicts, the text with the other side's words left as they were on this side.
  final String text;

  /// How many places both sides changed the same words.
  final int conflicts;

  bool get clean => conflicts == 0;
}

final RegExp _token = RegExp(r'\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]', unicode: true);

/// Words, runs of spaces and single marks, in order (joined they give the text back).
List<String> tokens(String s) => [for (final m in _token.allMatches(s)) m.group(0)!];

/// For each item of [a], the index of the same item in [b] on a longest common subsequence, or -1 (Myers' O(ND) diff).
List<int> lcsMap(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  final out = List<int>.filled(n, -1);
  // Common head and tail first: most edits are small.
  var head = 0;
  while (head < n && head < m && a[head] == b[head]) {
    out[head] = head;
    head++;
  }
  var tail = 0;
  while (tail < n - head && tail < m - head && a[n - 1 - tail] == b[m - 1 - tail]) {
    out[n - 1 - tail] = m - 1 - tail;
    tail++;
  }
  final aa = a.sublist(head, n - tail), bb = b.sublist(head, m - tail);
  final na = aa.length, nb = bb.length;
  if (na == 0 || nb == 0) return out;
  final max = na + nb;
  final v = <int, int>{1: 0};
  final trace = <Map<int, int>>[];
  var done = false;
  for (var d = 0; d <= max && !done; d++) {
    trace.add(Map.of(v));
    for (var k = -d; k <= d; k += 2) {
      var x = (k == -d || (k != d && (v[k - 1] ?? -1) < (v[k + 1] ?? -1))) ? (v[k + 1] ?? 0) : (v[k - 1] ?? 0) + 1;
      var y = x - k;
      while (x < na && y < nb && aa[x] == bb[y]) {
        x++;
        y++;
      }
      v[k] = x;
      if (x >= na && y >= nb) {
        done = true;
        break;
      }
    }
  }
  // Walk back through the trace, marking the diagonal (matching) steps.
  var x = na, y = nb;
  for (var d = trace.length - 1; d > 0 && (x > 0 || y > 0); d--) {
    final vd = trace[d];
    final k = x - y;
    final prevK = (k == -d || (k != d && (vd[k - 1] ?? -1) < (vd[k + 1] ?? -1))) ? k + 1 : k - 1;
    final prevX = vd[prevK] ?? 0;
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      x--;
      y--;
      out[head + x] = head + y;
    }
    x = prevX;
    y = prevY;
  }
  while (x > 0 && y > 0) {
    x--;
    y--;
    out[head + x] = head + y;
  }
  return out;
}

/// Merges [ours] and [theirs], both changed from [base]. Conflicting parts keep [ours] and are counted.
MergeResult merge3(String base, String ours, String theirs) {
  if (ours == theirs) return MergeResult(ours);
  if (ours == base) return MergeResult(theirs);
  if (theirs == base) return MergeResult(ours);
  var o = tokens(base), a = tokens(ours), b = tokens(theirs);
  if (o.length + a.length + b.length > 60000) {
    // Very long texts merge line by line (the word diff's cost grows with the square of the changes).
    List<String> lines(String s) => [for (final m in RegExp(r'[^\n]*\n|[^\n]+$').allMatches(s)) m.group(0)!];
    o = lines(base);
    a = lines(ours);
    b = lines(theirs);
  }
  final ma = lcsMap(o, a), mb = lcsMap(o, b);
  final out = StringBuffer();
  var conflicts = 0;
  var i = 0, ia = 0, ib = 0;
  bool same(List<String> x, List<String> y) {
    if (x.length != y.length) return false;
    for (var j = 0; j < x.length; j++) {
      if (x[j] != y[j]) return false;
    }
    return true;
  }

  void chunk(List<String> oc, List<String> ac, List<String> bc) {
    if (same(ac, oc)) {
      out.writeAll(bc);
    } else if (same(bc, oc) || same(ac, bc)) {
      out.writeAll(ac);
    } else {
      conflicts++;
      out.writeAll(ac);
    }
  }

  while (true) {
    var p = i;
    while (p < o.length && !(ma[p] >= ia && mb[p] >= ib)) {
      p++;
    }
    if (p >= o.length) {
      chunk(o.sublist(i), a.sublist(ia), b.sublist(ib));
      break;
    }
    chunk(o.sublist(i, p), a.sublist(ia, ma[p]), b.sublist(ib, mb[p]));
    out.write(o[p]);
    i = p + 1;
    ia = ma[p] + 1;
    ib = mb[p] + 1;
  }
  return MergeResult(out.toString(), conflicts: conflicts);
}
