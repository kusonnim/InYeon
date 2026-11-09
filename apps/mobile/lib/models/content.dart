/// Client representation of contracts/openapi.yaml. Never redefine state semantics locally.
enum InputType { text, url, image, document }
enum AnalysisStatus { pending, processing, completed, partial, failed }
enum WorkflowStatus { pending, completed, archived }
enum RecommendationKind { action, information, resource }
enum AnalysisCoverage { fullText, partialText, metadataOnly, unsupported }
enum NotificationVisibility { active, dismissed }

T parseEnum<T extends Enum>(List<T> values, String value) =>
    values.firstWhere((element) => element.name == value);

class Analysis {
  const Analysis({required this.id, required this.contentId, required this.coverage,
    required this.summary, required this.limitations, required this.createdAt});
  final String id;
  final String contentId;
  final AnalysisCoverage coverage;
  final String? summary;
  final List<String> limitations;
  final DateTime createdAt;
  factory Analysis.fromJson(Map<String, dynamic> json) => Analysis(
    id: json['id'] as String,
    contentId: json['content_id'] as String,
    coverage: switch (json['coverage']) {
      'full_text' => AnalysisCoverage.fullText,
      'partial_text' => AnalysisCoverage.partialText,
      'metadata_only' => AnalysisCoverage.metadataOnly,
      'unsupported' => AnalysisCoverage.unsupported,
      _ => throw const FormatException('Unknown analysis coverage'),
    },
    summary: json['summary'] as String?,
    limitations: List<String>.from(json['limitations'] as List<dynamic>),
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}

class Recommendation {
  const Recommendation({required this.id, required this.contentId, required this.kind,
    required this.text, required this.sourceUrl, required this.userText,
    required this.accepted, required this.version, required this.createdAt, required this.updatedAt});
  final String id;
  final String contentId;
  final RecommendationKind kind;
  final String text;
  final String? sourceUrl;
  final String? userText;
  final bool accepted;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;
  factory Recommendation.fromJson(Map<String, dynamic> json) => Recommendation(
    id: json['id'] as String, contentId: json['content_id'] as String,
    kind: parseEnum(RecommendationKind.values, json['kind'] as String),
    text: json['text'] as String, sourceUrl: json['source_url'] as String?,
    userText: json['user_text'] as String?, accepted: json['accepted'] as bool,
    version: json['version'] as int,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );
}

class NotificationState {
  const NotificationState({required this.contentId, required this.visibility,
    required this.generation, required this.revision, required this.updatedAt});
  final String contentId;
  final NotificationVisibility visibility;
  final int generation;
  final int revision;
  final DateTime updatedAt;
  factory NotificationState.fromJson(Map<String, dynamic> json) => NotificationState(
    contentId: json['content_id'] as String,
    visibility: parseEnum(NotificationVisibility.values, json['visibility'] as String),
    generation: json['generation'] as int,
    revision: json['revision'] as int,
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );
}

class ContentItem {
  const ContentItem({required this.id, required this.userId, required this.inputType,
    required this.sourceText, required this.sourceUrl, required this.assetIds,
    required this.title, required this.userNote, required this.analysisStatus,
    required this.workflowStatus, required this.version, required this.createdAt,
    required this.updatedAt, required this.analysis, required this.recommendations,
    required this.notification});
  final String id;
  final String userId;
  final InputType inputType;
  final String? sourceText;
  final String? sourceUrl;
  final List<String> assetIds;
  final String? title;
  final String? userNote;
  final AnalysisStatus analysisStatus;
  final WorkflowStatus workflowStatus;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Analysis? analysis;
  final List<Recommendation> recommendations;
  final NotificationState notification;
  factory ContentItem.fromJson(Map<String, dynamic> json) => ContentItem(
    id: json['id'] as String, userId: json['user_id'] as String,
    inputType: parseEnum(InputType.values, json['input_type'] as String), sourceText: json['source_text'] as String?,
    sourceUrl: json['source_url'] as String?, assetIds: List<String>.from(json['asset_ids'] as List<dynamic>),
    title: json['title'] as String?, userNote: json['user_note'] as String?,
    analysisStatus: parseEnum(AnalysisStatus.values, json['analysis_status'] as String),
    workflowStatus: parseEnum(WorkflowStatus.values, json['workflow_status'] as String),
    version: json['version'] as int,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    analysis: json['analysis'] == null ? null : Analysis.fromJson(json['analysis'] as Map<String, dynamic>),
    recommendations: (json['recommendations'] as List<dynamic>).map((item) =>
        Recommendation.fromJson(item as Map<String, dynamic>)).toList(growable: false),
    notification: NotificationState.fromJson(json['notification'] as Map<String, dynamic>),
  );
}

class ContentPage {
  const ContentPage({required this.items, required this.nextCursor});
  final List<ContentItem> items;
  final String? nextCursor;
  factory ContentPage.fromJson(Map<String, dynamic> json) => ContentPage(
    items: (json['items'] as List<dynamic>).map((item) =>
        ContentItem.fromJson(item as Map<String, dynamic>)).toList(growable: false),
    nextCursor: json['next_cursor'] as String?,
  );
}

class ContentPatch {
  const ContentPatch({
    required this.expectedVersion,
    this.title,
    this.userNote,
    this.workflowStatus,
    this.clearTitle = false,
    this.clearUserNote = false,
  }) : assert(!clearTitle || title == null),
       assert(!clearUserNote || userNote == null);
  final int expectedVersion;
  final String? title;
  final String? userNote;
  final WorkflowStatus? workflowStatus;
  final bool clearTitle;
  final bool clearUserNote;
  Map<String, dynamic> toJson() => {
    'expected_version': expectedVersion,
    if (title != null || clearTitle) 'title': clearTitle ? null : title,
    if (userNote != null || clearUserNote) 'user_note': clearUserNote ? null : userNote,
    if (workflowStatus != null) 'workflow_status': workflowStatus!.name,
  };
}
