import 'conversation_store.dart';

/// A heading of the conversation list and what is under it.
class ConversationGroup {
  const ConversationGroup(this.label, this.items);

  final String label;
  final List<Conversation> items;
}

const List<String> _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// Pinned first, then Today, Yesterday, Previous 7 days, and older conversations by month (the year is
/// added for a month in an earlier year). Inside a group the most recently changed comes first.
List<ConversationGroup> groupConversations(List<Conversation> all, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = DateTime(now.year, now.month, now.day - 1);
  final weekStart = DateTime(now.year, now.month, now.day - 7);
  final sorted = [...all]..sort((a, b) => b.updated.compareTo(a.updated));

  final pinned = <Conversation>[];
  final todayList = <Conversation>[];
  final yesterdayList = <Conversation>[];
  final week = <Conversation>[];
  final months = <String, List<Conversation>>{};
  for (final c in sorted) {
    final u = c.updated;
    if (c.pinned) {
      pinned.add(c);
    } else if (!u.isBefore(today)) {
      todayList.add(c);
    } else if (!u.isBefore(yesterday)) {
      yesterdayList.add(c);
    } else if (!u.isBefore(weekStart)) {
      week.add(c);
    } else {
      final label = u.year == now.year ? _months[u.month - 1] : '${_months[u.month - 1]} ${u.year}';
      months.putIfAbsent(label, () => []).add(c);
    }
  }
  return [
    if (pinned.isNotEmpty) ConversationGroup('Pinned', pinned),
    if (todayList.isNotEmpty) ConversationGroup('Today', todayList),
    if (yesterdayList.isNotEmpty) ConversationGroup('Yesterday', yesterdayList),
    if (week.isNotEmpty) ConversationGroup('Previous 7 days', week),
    for (final e in months.entries) ConversationGroup(e.key, e.value),
  ];
}
