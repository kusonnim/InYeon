import 'dart:convert';
import 'dart:io';
import '../models/content.dart';
import 'content_api.dart';

/// Transport only. Inject a short-lived Supabase session; real auth UI is planned.
class HttpContentApi implements ContentApi {
  HttpContentApi({required this.baseUri, required this.accessToken, HttpClient? client})
      : _client = client ?? HttpClient();
  final Uri baseUri;
  final Future<String> Function() accessToken;
  final HttpClient _client;

  Future<Map<String, dynamic>> _request(String method, String path, {Map<String, dynamic>? body}) async {
    final token = await accessToken();
    if (token.isEmpty) throw const ApiException(401, 'unauthorized', 'A user session is required.');
    final request = await _client.openUrl(method, baseUri.resolve(path));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.contentType = ContentType.json;
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final decoded = jsonDecode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException.fromJson(response.statusCode, decoded);
    }
    return decoded;
  }

  @override
  Future<ContentPage> listContents({String? cursor}) async =>
      ContentPage.fromJson(await _request('GET', '/v1/contents${cursor == null ? '' : '?cursor=${Uri.encodeQueryComponent(cursor)}'}'));
  @override
  Future<ContentItem> getContent(String id) async =>
      ContentItem.fromJson(await _request('GET', '/v1/contents/${Uri.encodeComponent(id)}'));
  @override
  Future<ContentItem> updateContent(String id, ContentPatch patch) async =>
      ContentItem.fromJson(await _request('PATCH', '/v1/contents/${Uri.encodeComponent(id)}', body: patch.toJson()));

  void close() => _client.close();
}
