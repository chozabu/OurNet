import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/recovery_phrase.dart';
import 'package:ournet_core/ournet_core.dart';

const phrase = 'correct horse battery staple';

void main() {
  testWidgets('a clear root is sealed before first use, then unlocks', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final node = Node(await LocalIdentity.create(label: 'PC'), Store());
    final clear = await tester.runAsync(
      () async => (await node.identity.root!.extractPublicKey()).bytes,
    );
    SimpleKeyPair? unlocked;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              closed = false;
              unlocked = await unlockRoot(context, node);
              closed = true;
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    // Argon2id runs in a real isolate, outside the test's fake clock.
    Future<void> submit(String label) async {
      await tester.tap(find.widgetWithText(FilledButton, label));
      for (var i = 0; i < 100 && !closed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        if (find.textContaining('not right').evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Set a recovery phrase'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'too short');
    await tester.enterText(fields.at(1), 'too short');
    await tester.tap(find.widgetWithText(FilledButton, 'Set phrase'));
    await tester.pumpAndSettle();
    expect(
      find.text('Use a recovery phrase of at least 12 characters'),
      findsOneWidget,
    );
    await tester.enterText(fields.at(0), phrase);
    await tester.enterText(fields.at(1), '$phrase!');
    await tester.tap(find.widgetWithText(FilledButton, 'Set phrase'));
    await tester.pumpAndSettle();
    expect(find.text('The two phrases do not match'), findsOneWidget);
    expect(node.identity.root, isNotNull);

    await tester.enterText(fields.at(1), phrase);
    await submit('Set phrase');
    expect(closed, isTrue);
    expect(node.identity.root, isNull);
    expect(node.identity.sealedRoot, isNotNull);
    final saved = await tester.runAsync(
      () => const FlutterSecureStorage().readAll(),
    );
    final vault = jsonDecode(saved!.values.single) as Map;
    expect(vault['root'], isNull);
    expect(vault['sealedRoot'], node.identity.sealedRoot!.toJson());
    final returned = await tester.runAsync(
      () async => (await unlocked!.extractPublicKey()).bytes,
    );
    expect(returned, clear);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Recovery phrase'), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'correct horse battery');
    await submit('Unlock');
    expect(find.textContaining('not right'), findsOneWidget);
    expect(closed, isFalse);
    await tester.enterText(find.byType(TextField), phrase);
    await submit('Unlock');
    expect(closed, isTrue);
    final reopened = await tester.runAsync(
      () async => (await unlocked!.extractPublicKey()).bytes,
    );
    expect(reopened, clear);
    await node.close();
  });

  testWidgets('cancelling returns no root and changes nothing', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final node = Node(await LocalIdentity.create(), Store());
    Object? result = 'pending';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await unlockRoot(context, node),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(node.identity.root, isNotNull);
    expect(node.identity.sealedRoot, isNull);
    await node.close();
  });
}
