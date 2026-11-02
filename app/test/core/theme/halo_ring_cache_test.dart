import 'package:aseman/src/core/theme/halo_ring_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HaloRingCache.clear(persist: true);
  });

  test('same person and agent keep one bound gradient each', () async {
    await HaloRingCache.restore();
    final person = HaloRingCache.person('acct-1');
    final agent = HaloRingCache.agent('bot-9');

    final firstPerson = HaloRingCache.colorsFor(person);
    final firstAgent = HaloRingCache.colorsFor(agent);
    expect(firstPerson, isNotEmpty);
    expect(firstAgent, isNotEmpty);
    expect(
      firstPerson.map((c) => c.toARGB32()).toList(),
      isNot(equals(firstAgent.map((c) => c.toARGB32()).toList())),
    );

    // Same identity always yields the same stops in-session.
    expect(
      HaloRingCache.colorsFor(person).map((c) => c.toARGB32()),
      firstPerson.map((c) => c.toARGB32()),
    );
    expect(
      HaloRingCache.colorsFor(agent).map((c) => c.toARGB32()),
      firstAgent.map((c) => c.toARGB32()),
    );

    await HaloRingCache.flush();

    // Survives a cold restore from the device cache.
    await HaloRingCache.clear();
    await HaloRingCache.restore();
    expect(
      HaloRingCache.colorsFor(person).map((c) => c.toARGB32()),
      firstPerson.map((c) => c.toARGB32()),
    );
    expect(
      HaloRingCache.colorsFor(agent).map((c) => c.toARGB32()),
      firstAgent.map((c) => c.toARGB32()),
    );
  });

  test('person and agent keys do not collide on the same raw id', () {
    final person = HaloRingCache.colorsFor(HaloRingCache.person('same'));
    final agent = HaloRingCache.colorsFor(HaloRingCache.agent('same'));
    // Distinct keys — may or may not share a palette bank slot, but bindings
    // are stored separately.
    expect(HaloRingCache.has(HaloRingCache.person('same')), isTrue);
    expect(HaloRingCache.has(HaloRingCache.agent('same')), isTrue);
    expect(person, isA<List<Color>>());
    expect(agent, isA<List<Color>>());
  });
}
