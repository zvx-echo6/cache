import 'package:cache/actions/action_registry.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> def(String id, {Map<String, dynamic>? fields, List<String> required = const [], String effect = 'change', String? module, Map<String, dynamic> extra = const {}}) => {
      'id': id,
      'module': module ?? id.split('.').first,
      'title': 'Do it',
      'description': 'Does it.',
      'effect': effect,
      'fields': fields ?? <String, dynamic>{},
      'required': required,
      ...extra,
    };

Future<Map<String, dynamic>> ok(Map<String, dynamic> f) async => {'fine': true};

String? reasonFor(Map<String, dynamic> d, {String module = 'garden'}) {
  final r = ActionRegistry().publish(module, [d], {'${d['id']}': ok});
  return r.isEmpty ? null : r.single.reason;
}

void main() {
  test('a good definition is installed', () {
    final reg = ActionRegistry();
    final r = reg.publish('garden', [
      def('garden.water', fields: {
        'bed': {'type': 'string', 'maxLength': 40, 'enum': ['north', 'south'], 'description': 'Which bed'},
        'litres': {'type': 'number', 'minimum': 0, 'maximum': 50},
        'times': {'type': 'integer', 'minimum': 1},
        'when': {'type': 'date'},
        'at': {'type': 'time'},
        'for': {'type': 'duration'},
        'where': {'type': 'place'},
        'done': {'type': 'boolean'},
      }, required: ['bed']),
    ], {'garden.water': ok});
    expect(r, isEmpty);
    expect(reg.definitions.single['id'], 'garden.water');
    expect(reg.definition('garden.water'), isNotNull);
  });

  test('broken definitions are rejected with a reason', () {
    expect(reasonFor(def('Garden.Water', module: 'garden')), contains('lowercase'));
    expect(reasonFor(def('garden')), contains('<module>.<verb>'));
    expect(reasonFor(def('garden.${'x' * 48}')), contains('48'));
    expect(reasonFor(def('garden.water', module: 'yard')), contains('prefix'));
    expect(reasonFor(def('yard.water'), module: 'garden'), contains('belongs to module yard'));
    expect(reasonFor({...def('garden.water'), 'title': 'x' * 41}), contains('title'));
    expect(reasonFor({...def('garden.water'), 'description': 'x' * 121}), contains('description'));
    expect(reasonFor({...def('garden.water'), 'title': ''}), contains('title is missing'));
    expect(reasonFor(def('garden.water', effect: 'delete')), contains('effect'));
    expect(reasonFor(def('garden.water', fields: {for (var i = 0; i < 11; i++) 'f$i': {'type': 'string'}})), contains('more than 10'));
    expect(reasonFor(def('garden.water', fields: {'Bed': {'type': 'string'}})), contains('field name'));
    expect(reasonFor(def('garden.water', fields: {'bed': {'type': 'colour'}})), contains('unknown type'));
    expect(reasonFor(def('garden.water', fields: {'bed': {'type': 'boolean', 'maxLength': 3}})), contains('does not apply'));
    expect(reasonFor(def('garden.water', fields: {'bed': {'type': 'string', 'enum': []}})), contains('enum'));
    expect(reasonFor(def('garden.water', fields: {'bed': {'type': 'string', 'maxLength': 0}})), contains('maxLength'));
    expect(reasonFor(def('garden.water', fields: {'n': {'type': 'integer', 'minimum': 1.5}})), contains('whole numbers'));
    expect(reasonFor(def('garden.water', fields: {'n': {'type': 'number', 'minimum': 5, 'maximum': 1}})), contains('above'));
    expect(reasonFor(def('garden.water', fields: {'n': {'type': 'number', 'description': 'x' * 81}})), contains('description'));
    expect(reasonFor(def('garden.water', required: ['bed'])), contains('does not exist'));
    expect(reasonFor(def('garden.water', extra: {'icon': 'x'})), contains('unknown key'));
  });

  test('a bad definition does not stop the module\'s others', () {
    final reg = ActionRegistry();
    final r = reg.publish('garden', [def('garden.water'), def('garden.BAD'), def('garden.weed')], {'garden.water': ok, 'garden.weed': ok, 'garden.BAD': ok});
    expect(r.single.id, 'garden.BAD');
    expect([for (final d in reg.definitions) d['id']], ['garden.water', 'garden.weed']);
  });

  test('ids are unique across modules and need a handler', () {
    final reg = ActionRegistry()..publish('garden', [def('garden.water')], {'garden.water': ok});
    expect(reg.publish('garden', [def('garden.water'), def('garden.water')], {'garden.water': ok}).single.reason, contains('already'));
    expect(reg.publish('yard', [def('yard.mow')], {}).single.reason, contains('no handler'));
  });

  test('publishing again replaces the module, in module order', () {
    final reg = ActionRegistry()
      ..publish('a', [def('a.one')], {'a.one': ok})
      ..publish('b', [def('b.one')], {'b.one': ok})
      ..publish('a', [def('a.two')], {'a.two': ok});
    expect([for (final d in reg.definitions) d['id']], ['a.two', 'b.one']);
  });

  test('run gives the contract\'s results', () async {
    final reg = ActionRegistry()
      ..publish('a', [def('a.one'), def('a.two')], {
        'a.one': ok,
        'a.two': (_) async => throw const ActionFailure('full', 'The list is full.'),
      });
    expect(await reg.run('a.one', {}, confirmId: 'c1'), {'ok': true, 'status': 'done', 'confirm_id': 'c1', 'action': 'a.one', 'result': {'fine': true}});
    expect(await reg.run('a.two', {}, confirmId: 'c2'), {
      'ok': false,
      'status': 'failed',
      'confirm_id': 'c2',
      'action': 'a.two',
      'error': {'type': 'full', 'detail': 'The list is full.'},
    });
    expect((await reg.run('a.nope', {}))['error'], {'type': 'unknown_action', 'detail': 'This action is not installed.'});
  });
}
