import '../models/content.dart';

abstract interface class ContentApi {
  Future<ContentPage> listContents({String? cursor});
  Future<ContentItem> getContent(String id);
  Future<ContentItem> updateContent(String id, ContentPatch patch);
}

class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message, {
    this.requestId,
    this.currentVersion,
    this.currentGeneration,
    this.currentRevision,
  });
  final int status;
  final String code;
  final String message;
  final String? requestId;
  final int? currentVersion;
  final int? currentGeneration;
  final int? currentRevision;

  factory ApiException.fromJson(int status, Map<String, dynamic> json) {
    final error = json['error'] as Map<String, dynamic>;
    return ApiException(
      status, error['code'] as String, error['message'] as String,
      requestId: error['request_id'] as String?,
      currentVersion: error['current_version'] as int?,
      currentGeneration: error['current_generation'] as int?,
      currentRevision: error['current_revision'] as int?,
    );
  }
  @override
  String toString() => 'ApiException($status, $code): $message';
}
