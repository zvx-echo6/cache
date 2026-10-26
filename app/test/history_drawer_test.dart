import 'package:cache/chat/chat_controller.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/history/date_groups.dart';
import 'package:cache/screens/history_drawer.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation conv(int id, String title, DateTime updated, {bool pinned = false}) => Conversation(
      id: id,
      title: title,
      titleSource: TitleSource.question,
      created: updated,
      updated: updated,
      pinned: pinned,
      model: '',
    );

void main() {
  // Monday 26 October 2026, 14:00.
  final now = DateTime(2026, 10, 26, 14);

  group('grouping', () {
    test('pinned, today, yesterday, previous 7 days, then months', () {
      final groups = groupConversations([
        conv(1, 'today early', DateTime(2026, 10, 26, 0, 5)),
        conv(2, 'today late', DateTime(2026, 10, 26, 13)),
        conv(3, 'yesterday', DateTime(2026, 10, 25, 23, 59)),
        conv(4, 'six days', DateTime(2026, 10, 20, 8)),
        conv(5, 'seven days', DateTime(2026, 10, 19, 8)),
        conv(6, 'eight days', DateTime(2026, 10, 18, 23)),
        conv(7, 'september', DateTime(2026, 9, 30, 12)),
        conv(8, 'last year', DateTime(2025, 12, 3, 12)),
        conv(9, 'pinned old', DateTime(2026, 1, 3), pinned: true),
        conv(10, 'also september', DateTime(2026, 9, 2, 12)),
      ], now);
      expect([for (final g in groups) g.label], [
        'Pinned', 'Today', 'Yesterday', 'Previous 7 days', 'October', 'September', 'December 2025',
      ]);
      expect([for (final c in groups[1].items) c.title], ['today late', 'today early']);
      expect([for (final c in groups[3].items) c.title], ['six days', 'seven days']);
      expect([for (final c in groups[4].items) c.title], ['eight days']);
      expect([for (final c in groups[5].items) c.title], ['september', 'also september']);
    });

    test('empty groups are left out', () {
      expect(groupConversations(const [], now), isEmpty);
      final g = groupConversations([conv(1, 'a', DateTime(2026, 10, 26, 9))], now);
      expect([for (final x in g) x.label], ['Today']);
    });
  });

  group('drawer', () {
    late ConversationStore store;
    late ChatController chat;
    late DateTime clock;

    int seed(String title, DateTime at, {String text = 'question text'}) {
      clock = at;
      final c = store.create(title: title);
      store.addMessage(c.id, role: 'user', content: text, message: {'role': 'user', 'content': text});
      return c.id;
    }

    Future<void> openDrawer(WidgetTester tester, {List<String>? shared}) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: Scaffold(
          drawer: HistoryDrawer(
            chat: chat,
            now: () => now,
            share: (title, md) async => shared?.add('$title\n$md'),
          ),
          body: const SizedBox(),
        ),
      ));
      tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
      await tester.pumpAndSettle();
    }

    setUp(() {
      clock = now;
      store = ConversationStore.memory(now: () => clock);
      chat = ChatController(tools: const [])..attachStore(store);
    });
    tearDown(() => store.close());

    testWidgets('shows New chat, search, pinned and date groups in order', (tester) async {
      seed('Water from a stream', DateTime(2026, 10, 26, 9));
      seed('Snake bite', DateTime(2026, 10, 25, 20));
      seed('Old fire notes', DateTime(2026, 9, 3));
      final pinned = seed('Radio frequencies', DateTime(2026, 8, 1));
      store.setPinned(pinned, true);
      await openDrawer(tester);

      expect(find.text('New chat'), findsOneWidget);
      expect(find.text('Search chats'), findsOneWidget);
      final labels = ['Pinned', 'Today', 'Yesterday', 'September'];
      final ys = [for (final l in labels) tester.getTopLeft(find.text(l)).dy];
      expect(ys, [...ys]..sort());
      expect(find.text('Previous 7 days'), findsNothing);
      expect(find.text('Radio frequencies'), findsOneWidget);
    });

    testWidgets('empty list says so', (tester) async {
      await openDrawer(tester);
      expect(find.text('No chats yet'), findsOneWidget);
    });

    testWidgets('search lists matching chats with a snippet and clears', (tester) async {
      seed('Water from a stream', DateTime(2026, 10, 26, 9), text: 'How do I filter muddy water?');
      seed('Snake bite', DateTime(2026, 10, 25, 20), text: 'What to do after a bite?');
      await openDrawer(tester);

      await tester.enterText(find.byType(TextField), 'muddy');
      await tester.pumpAndSettle();
      expect(find.text('Water from a stream'), findsOneWidget);
      expect(find.text('Snake bite'), findsNothing);
      expect(find.textContaining('muddy'), findsWidgets);
      expect(find.text('Today'), findsNothing); // search results are not grouped

      await tester.enterText(find.byType(TextField), 'nothingmatches');
      await tester.pumpAndSettle();
      expect(find.text('No chats match'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('Snake bite'), findsOneWidget);
    });

    testWidgets('tap opens the chat and closes the drawer; New chat clears', (tester) async {
      final id = seed('Snake bite', DateTime(2026, 10, 26, 8), text: 'bite?');
      await openDrawer(tester);
      await tester.tap(find.text('Snake bite'));
      await tester.pumpAndSettle();
      expect(chat.activeId, id);
      expect(chat.messages.single.text, 'bite?');
      expect(find.text('New chat'), findsNothing); // drawer closed

      tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();
      expect(chat.activeId, isNull);
      expect(chat.messages, isEmpty);
    });

    testWidgets('long press: pin, rename, share and delete with undo', (tester) async {
      final id = seed('Snake bite', DateTime(2026, 10, 26, 8), text: 'bite?');
      final shared = <String>[];
      await openDrawer(tester, shared: shared);

      // Pin
      await tester.longPress(find.text('Snake bite'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();
      expect(store.get(id)!.pinned, isTrue);
      expect(find.text('Pinned'), findsOneWidget);

      // Rename
      await tester.longPress(find.text('Snake bite'));
      await tester.pumpAndSettle();
      expect(find.text('Unpin'), findsOneWidget);
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'Bites and stings');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(store.get(id)!.title, 'Bites and stings');
      expect(find.text('Bites and stings'), findsOneWidget);

      // Share
      await tester.longPress(find.text('Bites and stings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share as Markdown'));
      await tester.pumpAndSettle();
      expect(shared.single, startsWith('Bites and stings\n# Bites and stings'));

      // Delete, then undo
      await tester.longPress(find.text('Bites and stings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(store.list(), isEmpty);
      expect(find.text('Chat deleted'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(store.list().length, 1);
    });

    testWidgets('delete without undo removes the chat for good', (tester) async {
      final id = seed('Snake bite', DateTime(2026, 10, 26, 8), text: 'bite?');
      await openDrawer(tester);
      await tester.longPress(find.text('Snake bite'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10)); // the snack bar times out
      await tester.pumpAndSettle();
      expect(store.messages(id), isEmpty);
    });
  });
}
