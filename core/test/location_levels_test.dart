import 'dart:math' as math;
import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  const t = 1700000000000;
  const hour = 3600000;

  group('ApproxGrid', () {
    test('every fix in a cell becomes the same centre', () {
      final rng = math.Random(7);
      final cell = ApproxGrid.cellOf(51.5, -0.12);
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        // Points spread over the cell: the centre must not move with them.
        final lat =
            -90 +
            (cell.row + .02 + rng.nextDouble() * .96) * ApproxGrid.latStep;
        final step = ApproxGrid.lngStep(cell.row);
        final lng = -180 + (cell.col + .02 + rng.nextDouble() * .96) * step;
        expect(ApproxGrid.cellOf(lat, lng), cell);
        final snapped = ApproxGrid.snap(
          Fix(lat: lat, lng: lng, at: t, accuracy: 5, heading: 90, speed: 2),
          cell,
        );
        seen.add('${snapped.lat},${snapped.lng},${snapped.accuracy}');
        expect(snapped.heading, isNull);
        expect(snapped.speed, isNull);
        expect(snapped.at, t);
      }
      expect(seen, hasLength(1));
    });

    test('cells are a few kilometres across, and the accuracy covers them', () {
      for (final (lat, lng) in [
        (51.5, -0.12),
        (0.0, 0.0),
        (-33.9, 151.2),
        (64.1, -21.9),
        (78.2, 15.6),
      ]) {
        final fix = Fix(lat: lat, lng: lng, at: t, accuracy: 8);
        final snapped = ApproxGrid.snap(fix, ApproxGrid.cellOf(lat, lng));
        final moved = fix.distanceTo(snapped.lat, snapped.lng);
        expect(moved, lessThanOrEqualTo(snapped.accuracy!), reason: '$lat');
        expect(snapped.accuracy, inInclusiveRange(3000, 6000), reason: '$lat');
        // Through the wire form and back, unchanged.
        final back = Fix.parse(snapped.toJson(), now: t)!;
        expect(back.lat, closeTo(snapped.lat, 1e-6));
        expect(back.lng, closeTo(snapped.lng, 1e-6));
      }
    });

    test('works at the edges of the map', () {
      for (final (lat, lng) in [(90.0, 180.0), (-90.0, -180.0), (0.0, 180.0)]) {
        final cell = ApproxGrid.cellOf(lat, lng);
        final snapped = ApproxGrid.snap(Fix(lat: lat, lng: lng, at: t), cell);
        expect(Fix.parse(snapped.toJson(), now: t), isNotNull);
      }
    });

    test('a position near the last cell stays in it', () {
      final cell = ApproxGrid.cellOf(51.5, -0.12);
      final top = -90 + (cell.row + 1) * ApproxGrid.latStep;
      // 100 m past the northern edge: still shown in the old cell.
      final just = Fix(lat: top + 100 / 111195, lng: -0.12, at: t);
      expect(ApproxGrid.cellOf(just.lat, just.lng), isNot(cell));
      expect(ApproxGrid.place(just, previous: cell), cell);
      expect(ApproxGrid.place(just), isNot(cell));
      // A kilometre past it: moved on.
      final far = Fix(lat: top + 1000 / 111195, lng: -0.12, at: t);
      expect(ApproxGrid.place(far, previous: cell), isNot(cell));
    });
  });

  group('LocationChoice', () {
    test('a temporary level runs out back to the one before', () {
      const choice = LocationChoice(
        LocationLevel.precise,
        until: t + hour,
        then: LocationLevel.approximate,
      );
      expect(choice.at(t), LocationLevel.precise);
      expect(choice.temporaryAt(t), isTrue);
      expect(choice.at(t + hour), LocationLevel.approximate);
      expect(choice.temporaryAt(t + hour), isFalse);
      expect(
        LocationChoice.parse(choice.toJson())!.at(t + hour),
        LocationLevel.approximate,
      );
    });

    test('rejects malformed values', () {
      for (final bad in [
        null,
        'precise',
        {'level': 'exact'},
        {'level': 'off', 'until': 'soon'},
        {'level': 'off', 'until': t, 'then': 'later'},
      ]) {
        expect(LocationChoice.parse(bad), isNull, reason: '$bad');
      }
      expect(LocationChoice.parse({'level': 'off'})!.at(t), LocationLevel.off);
    });
  });

  group('NoteState levels', () {
    late Node a;
    late NoteState state;
    setUp(() async {
      a = Node(await LocalIdentity.create(label: 'Pixel'), Store());
      state = NoteState(a);
    });
    tearDown(() => a.close());

    test(
      'friends from before keep precise; later ones are approximate',
      () async {
        expect(state.locationLevel('old', t), LocationLevel.precise);
        await state.startLocationLevels(['old'], t);
        expect(state.locationLevelsStarted, isTrue);
        expect(state.locationLevel('old', t), LocationLevel.precise);
        expect(state.locationLevel('new', t), LocationLevel.approximate);
        // Only once: a second run changes nothing.
        await state.setLocationLevel('old', LocationLevel.off, now: t);
        await state.startLocationLevels(['old', 'other'], t);
        expect(state.locationLevel('old', t), LocationLevel.off);
        expect(state.locationLevel('other', t), LocationLevel.approximate);
      },
    );

    test('levels are kept, synced state only, and read back', () async {
      await state.startLocationLevels([], t);
      await state.setLocationLevel('f', LocationLevel.precise, now: t);
      final again = NoteState(a);
      await again.refresh();
      expect(again.locationLevel('f', t), LocationLevel.precise);
      final objects = a.store.objects(kind: 'note_self');
      expect(objects, isNotEmpty);
      // Readable by this person's devices only.
      expect(objects.every((o) => o.audience.single == a.person), isTrue);
    });

    test('precise for an hour returns to the level before', () async {
      await state.startLocationLevels([], t);
      await state.setLocationLevel('f', LocationLevel.off, now: t);
      await state.setLocationLevel(
        'f',
        LocationLevel.precise,
        until: t + hour,
        now: t,
      );
      expect(state.locationLevel('f', t + 1), LocationLevel.precise);
      expect(state.locationLevel('f', t + hour), LocationLevel.off);
      // Extending it keeps the level it returns to, not the temporary one.
      await state.setLocationLevel(
        'f',
        LocationLevel.precise,
        until: t + 2 * hour,
        now: t + 10,
      );
      expect(state.locationLevel('f', t + hour), LocationLevel.precise);
      expect(state.locationLevel('f', t + 2 * hour), LocationLevel.off);
      // After it ran out, a new choice replaces it.
      await state.setLocationLevel(
        'f',
        LocationLevel.approximate,
        now: t + 3 * hour,
      );
      expect(state.locationLevel('f', t + 9 * hour), LocationLevel.approximate);
    });
  });
}
