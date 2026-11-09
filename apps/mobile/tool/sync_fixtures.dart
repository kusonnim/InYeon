import 'dart:io';

/// Run from apps/mobile. Canonical fixture source belongs to contracts/.
void main(List<String> arguments) {
  final source = File('../../contracts/examples/catalog.json');
  final target = File('assets/fixtures/catalog.json');
  if (!source.existsSync()) {
    stderr.writeln('Run from apps/mobile; shared catalog.json was not found.');
    exitCode = 1;
    return;
  }
  final expected = source.readAsBytesSync();
  if (arguments.contains('--check')) {
    final actual = target.existsSync() ? target.readAsBytesSync() : <int>[];
    if (actual.length != expected.length ||
        List.generate(expected.length, (i) => i).any((i) => actual[i] != expected[i])) {
      stderr.writeln('Bundled fixture is stale. Run dart run tool/sync_fixtures.dart.');
      exitCode = 1;
    }
    return;
  }
  target.parent.createSync(recursive: true);
  target.writeAsBytesSync(expected);
}
