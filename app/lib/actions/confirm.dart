import 'dart:convert';

/// How the outcome of a confirm card goes into the conversation. The contract's form is a `tool` message for `act` with the
/// original call's tool_call_id; the other is a host event: a `system` message with the same JSON. Gemma 4's template renders the
/// first as a `<|turn>tool` turn when a text reply comes between (it is not a tool response there), so the choice is the core
/// side's, made before captures start.
enum ActOutcomeForm { toolMessage, hostEvent }

const ActOutcomeForm kActOutcomeForm = ActOutcomeForm.toolMessage;

enum ConfirmState {
  /// Waiting for a tap.
  open,

  /// Tapped; the action is running.
  running,
  done,
  declined,
  failed,

  /// Still open when the chat was closed: dropped without an outcome.
  dropped,
}

/// One confirm card: a `change` call the core answered with `needs_confirmation`.
class ConfirmCard {
  ConfirmCard({
    required this.confirmId,
    required this.toolCallId,
    required this.action,
    required this.title,
    required this.summary,
    required this.fields,
    this.state = ConfirmState.open,
    this.error,
  });

  final String confirmId;
  final String toolCallId;
  final String action;
  final String title;

  /// The fields as they will be used, in the core's order (places resolved to what the user will recognise).
  final List<MapEntry<String, String>> summary;

  /// The call's fields as the model wrote them, resolved again on the tap.
  final Map<String, dynamic> fields;
  ConfirmState state;

  /// The error detail of a failed run.
  String? error;

  bool get resolved => state == ConfirmState.done || state == ConfirmState.declined || state == ConfirmState.failed;

  /// The card for an `act` tool result, or null when it is not a `needs_confirmation`.
  static ConfirmCard? fromResult(String toolCallId, Map<String, dynamic> args, String content) {
    final j = _json(content);
    if (j == null || j['ok'] != true || j['status'] != 'needs_confirmation') return null;
    final id = j['confirm_id'], action = j['action'];
    if (id is! String || id.isEmpty || action is! String) return null;
    final summary = j['summary'] is Map ? (j['summary'] as Map) : const {};
    final fields = args['fields'];
    return ConfirmCard(
      confirmId: id,
      toolCallId: toolCallId,
      action: action,
      title: j['title'] is String ? j['title'] as String : action,
      summary: [for (final e in summary.entries) MapEntry('${e.key}', e.value is String ? e.value as String : jsonEncode(e.value))],
      fields: fields is Map ? fields.cast<String, dynamic>() : const {},
    );
  }

  /// Takes an outcome result (done, declined or failed) for this card.
  bool apply(Map<String, dynamic> outcome) {
    if (outcome['confirm_id'] != confirmId) return false;
    switch (outcome['status']) {
      case 'done':
        state = ConfirmState.done;
      case 'declined':
        state = ConfirmState.declined;
      case 'failed':
        state = ConfirmState.failed;
        final e = outcome['error'];
        error = e is Map && e['detail'] is String ? e['detail'] as String : null;
      default:
        return false;
    }
    return true;
  }

  Map<String, dynamic> declined() => {'ok': true, 'status': 'declined', 'confirm_id': confirmId, 'action': action};

  /// The message that carries [outcome] into the conversation.
  Map<String, dynamic> outcomeMessage(Map<String, dynamic> outcome, {ActOutcomeForm form = kActOutcomeForm}) => switch (form) {
        ActOutcomeForm.toolMessage => {'role': 'tool', 'tool_call_id': toolCallId, 'content': jsonEncode(outcome)},
        ActOutcomeForm.hostEvent => {'role': 'system', 'content': jsonEncode(outcome)},
      };
}

Map<String, dynamic>? _json(Object? content) {
  if (content is! String || !content.trimLeft().startsWith('{')) return null;
  try {
    final v = jsonDecode(content);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// The cards of a stored transcript (OpenAI style messages, in order) with their outcomes, by the index of the tool message that
/// asked for each. A card with no outcome was open when the chat was closed and is dropped.
Map<int, ConfirmCard> cardsInTranscript(List<Map<String, dynamic>> messages) {
  final calls = <String, Map<String, dynamic>>{};
  final cards = <int, ConfirmCard>{};
  final byConfirm = <String, ConfirmCard>{};
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    if (m['role'] == 'assistant' && m['tool_calls'] is List) {
      for (final c in m['tool_calls'] as List) {
        final f = c is Map ? c['function'] : null;
        if (f is Map && f['name'] == 'act') calls['${c['id'] ?? ''}'] = _json(f['arguments']) ?? const {};
      }
      continue;
    }
    final j = _json(m['content']);
    if (j == null) continue;
    if (m['role'] == 'tool') {
      final callId = '${m['tool_call_id'] ?? ''}';
      final card = calls.containsKey(callId) ? ConfirmCard.fromResult(callId, calls[callId]!, m['content'] as String) : null;
      if (card != null) {
        cards[i] = card;
        byConfirm[card.confirmId] = card;
        continue;
      }
    }
    if (m['role'] == 'tool' || m['role'] == 'system') {
      final card = byConfirm[j['confirm_id']];
      if (card != null && !card.resolved && j['action'] == card.action) card.apply(j);
    }
  }
  for (final c in cards.values) {
    if (!c.resolved) c.state = ConfirmState.dropped;
  }
  return cards;
}
