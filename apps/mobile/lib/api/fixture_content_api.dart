import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/content.dart';
import 'content_api.dart';

/// Explicit synthetic data adapter; state lasts only for this instance.
class FixtureContentApi implements ContentApi {
  FixtureContentApi(this._catalog);
  final Map<String, dynamic> _catalog;

  static Future<FixtureContentApi> load() async => FixtureContentApi(
    jsonDecode(await rootBundle.loadString('assets/fixtures/catalog.json')) as Map<String, dynamic>,
  );

  List<Map<String, dynamic>> get _items =>
      (_catalog['items'] as List<dynamic>).cast<Map<String, dynamic>>();

  Map<String, dynamic> _find(String id) => _items.firstWhere(
    (item) => item['id'] == id,
    orElse: () => throw const ApiException(404, 'not_found', 'Content not found.'),
  );

  @override
  Future<ContentPage> listContents({String? cursor}) async {
    if (cursor != null) throw const ApiException(400, 'invalid_cursor', 'Fixture catalog has one page.');
    return ContentPage.fromJson(_catalog);
  }

  @override
  Future<ContentItem> getContent(String id) async => ContentItem.fromJson(_find(id));

  @override
  Future<ContentItem> updateContent(String id, ContentPatch patch) async {
    final item = _find(id);
    if (item['version'] != patch.expectedVersion) {
      throw const ApiException(409, 'version_conflict', 'Reload before applying your edit.');
    }
    final fields = patch.toJson()..remove('expected_version');
    item.addAll(fields);
    item['version'] = (item['version'] as int) + 1;
    item['updated_at'] = DateTime.now().toUtc().toIso8601String();
    return ContentItem.fromJson(item);
  }
}
