import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  test('built-in kinds are checked by the module that owns them', () {
    expect(validContent('chat_msg', {'text': 'hi'}), isTrue);
    expect(validContent('chat_msg', {'text': 1}), isFalse);
    expect(validContent('vote', {'object': 'o', 'value': 2}), isFalse);
    expect(validContent('cal_rsvp', {'event': 'e', 'response': 'yes'}), isTrue);
    // Unknown core kinds stay accepted, for newer builds.
    expect(validContent('something_new', {'anything': true}), isTrue);
    final owners = <String, String>{};
    for (final m in builtinModules) {
      for (final kind in m.kinds.keys) {
        expect(owners[kind], isNull, reason: '$kind declared twice');
        owners[kind] = m.id;
      }
    }
    expect(owners['chat'], 'public_chats');
  });

  test(
    'plugin kinds are size-capped everywhere and checked where installed',
    () {
      expect(PluginKinds.pluginOf('x.wiki.page'), 'wiki');
      expect(PluginKinds.pluginOf('x.wiki.'), isNull);
      expect(PluginKinds.pluginOf('x.Wiki.page'), isNull);
      expect(PluginKinds.pluginOf('chat_msg'), isNull);
      final big = {'body': 'a' * (PluginKinds.maxPayloadBytes + 1)};
      expect(validContent('x.wiki.page', big), isFalse);
      expect(validContent('x.wiki.page', {'title': 'Home'}), isTrue);

      final registry = Registry();
      registry.addKind('wiki', 'x.wiki.page', (p) => p['title'] is String);
      expect(registry.accepts('x.wiki.page', {'title': 'Home'}), isTrue);
      expect(registry.accepts('x.wiki.page', {'body': 'no title'}), isFalse);
      expect(
        () => registry.addKind('wiki', 'x.blog.post', (_) => true),
        throwsArgumentError,
      );
      registry.removeOwner('wiki');
      expect(registry.accepts('x.wiki.page', {'body': 'no title'}), isTrue);
    },
  );

  test('request handlers and sections belong to their owner', () async {
    final registry = Registry();
    Future<Json> echo(String device, Json r) async => {'device': device};
    registry.handle('x', echo, owner: 'game', poolable: true);
    expect(await registry.handler('x')!('d', {}), {'device': 'd'});
    expect(registry.poolable('x'), isTrue);
    registry.unhandle('x', (_, _) async => {});
    expect(registry.handler('x'), isNotNull, reason: 'another handler');
    registry.addSection(
      const PluginSection(
        id: 'x.game.board',
        plugin: 'game',
        title: 'Game',
        icon: 'casino',
        surface: 'board',
      ),
    );
    expect(registry.sections.single.allows(ScopeKind.group), isTrue);
    registry.removeOwner('game');
    expect(registry.handler('x'), isNull);
    expect(registry.sections, isEmpty);
  });
}
