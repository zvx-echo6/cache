import 'package:cache/platform/web_wake_lock.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBackend implements WakeLockBackend {
  int requests = 0;
  int releases = 0;
  int listeners = 0;
  bool refuse = false;
  void Function()? _visible;

  @override
  Future<Object> request() async {
    requests++;
    if (refuse) throw StateError('NotAllowedError');
    return Object();
  }

  @override
  Future<void> release(Object sentinel) async => releases++;

  @override
  void Function() onVisible(void Function() callback) {
    listeners++;
    _visible = callback;
    return () {
      listeners--;
      _visible = null;
    };
  }

  /// The tab coming back to the front.
  void show() => _visible?.call();
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('on requests the lock once, and asking again while on does not ask twice', () async {
    final b = FakeBackend();
    final w = WebWakeLock(b);
    await w.set(true);
    await w.set(true);
    expect(b.requests, 1);
    expect(w.held, isTrue);
  });

  test('off releases the lock and drops the visibility listener', () async {
    final b = FakeBackend();
    final w = WebWakeLock(b);
    await w.set(true);
    await w.set(false);
    expect(b.releases, 1);
    expect(b.listeners, 0);
    expect(w.held, isFalse);
  });

  test('the tab coming back while on asks again', () async {
    final b = FakeBackend();
    final w = WebWakeLock(b);
    await w.set(true);
    b.show();
    await settle();
    expect(b.requests, 2);
  });

  test('the tab coming back while off does not ask', () async {
    final b = FakeBackend();
    final w = WebWakeLock(b);
    await w.set(true);
    await w.set(false);
    b.show();
    await settle();
    expect(b.requests, 1);
  });

  test('a refused request does not throw, and is not held', () async {
    final b = FakeBackend()..refuse = true;
    final w = WebWakeLock(b);
    await w.set(true);
    expect(w.held, isFalse);
    b.refuse = false;
    b.show();
    await settle();
    expect(w.held, isTrue);
  });

  test('no backend (API missing) does nothing quietly', () async {
    final w = WebWakeLock(null);
    await w.set(true);
    await w.set(false);
    expect(w.held, isFalse);
  });

  test('turned off while the request is still pending releases it when it lands', () async {
    final b = FakeBackend();
    final w = WebWakeLock(b);
    final on = w.set(true);
    await w.set(false);
    await on;
    expect(b.releases, 1);
    expect(w.held, isFalse);
  });
}
