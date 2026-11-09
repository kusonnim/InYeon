import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/api/content_api.dart';
import 'package:itda_mobile/api/fixture_content_api.dart';
import 'package:itda_mobile/models/content.dart';

Map<String, dynamic> catalog() => jsonDecode(
  File('assets/fixtures/catalog.json').readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  test('shared fixtures parse without conflating workflow or notification state', () {
    final page = ContentPage.fromJson(catalog());
    expect(page.items.length, greaterThanOrEqualTo(5));
    expect(page.items.any((item) => item.recommendations.isEmpty), isTrue);
    expect(page.items.any((item) => item.analysis?.coverage == AnalysisCoverage.metadataOnly), isTrue);
    expect(page.items.any((item) => item.analysisStatus == AnalysisStatus.partial), isTrue);
    for (final item in page.items) {
      expect(item.createdAt.isUtc, isTrue);
      expect(item.recommendations.every((rec) => !rec.accepted), isTrue);
    }
  });

  test('stale edits fail while workflow updates preserve notification generation', () async {
    final api = FixtureContentApi(catalog());
    final original = (await api.listContents()).items.first;
    final changed = await api.updateContent(original.id,
      ContentPatch(expectedVersion: original.version, workflowStatus: WorkflowStatus.archived));
    expect(changed.version, original.version + 1);
    expect(changed.notification.generation, original.notification.generation);
    expect(changed.notification.visibility, original.notification.visibility);
    await expectLater(api.updateContent(original.id,
      ContentPatch(expectedVersion: original.version, workflowStatus: WorkflowStatus.completed)),
      throwsA(isA<ApiException>().having((error) => error.status, 'status', 409)));
  });
}
