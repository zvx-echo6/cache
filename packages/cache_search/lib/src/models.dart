/// A source the core searches. Today a ZIM; a library (Qdrant collection) can be added later.
class SourceConfig {
  const SourceConfig.zim({required this.path, required this.indexDir})
      : kind = 'zim',
        settings = null;

  /// A library; [settings] is the library settings file's JSON (cache-library.json) or null to let the core guess.
  const SourceConfig.library({required this.path, required this.indexDir, this.settings}) : kind = 'library';

  final String kind;
  final String path;
  final String indexDir;
  final Map<String, dynamic>? settings;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'path': path,
        'index_dir': indexDir,
        if (settings != null) 'settings': settings,
      };
}

/// The cs_open / cs_set_sources config JSON for [sources]. [extra] adds the other sections of the config (user, live, places,
/// routing, video, layers, snippet_chars, ...): `places` (`{"packs": [".../places.sqlite"]}`, the map's search), `routing`
/// (`{"valhalla": {"tiles", "shim"}, "offroad": {"pack", "elevation"}}`) and `user` (`{"db_path"}`, saved places). A later
/// cs_set_sources without them keeps the earlier ones.
Map<String, dynamic> openConfigJson(List<SourceConfig> sources, {Map<String, dynamic>? extra}) => {
      'sources': [for (final s in sources) s.toJson()],
      if (extra != null) ...extra,
    };

/// One hit of cs_search.
class SearchHit {
  const SearchHit({
    required this.address,
    required this.title,
    required this.snippet,
    required this.sourceId,
    required this.sourceKind,
    required this.sourceTitle,
    this.page,
  });

  factory SearchHit.fromJson(Map<String, dynamic> j) => SearchHit(
        address: j['address'] as String,
        title: (j['title'] ?? '') as String,
        snippet: (j['snippet'] ?? '') as String,
        sourceId: (j['source_id'] ?? '') as String,
        sourceKind: (j['source_kind'] ?? '') as String,
        sourceTitle: (j['source_title'] ?? '') as String,
        page: j['page'] as int?,
      );

  final String address;
  final String title;
  final String snippet;
  final String sourceId;
  final String sourceKind;
  final String sourceTitle;
  final int? page;

  /// The shape cs_format takes.
  Map<String, dynamic> toFormatJson() => {'address': address, 'title': title, 'snippet': snippet};
}

class SearchResponse {
  const SearchResponse({required this.results, required this.totalEstimate, this.vectorSources = const [], this.keywordOnlySources = const []});

  factory SearchResponse.fromJson(Map<String, dynamic> j) => SearchResponse(
        results: [for (final r in (j['results'] as List? ?? const [])) SearchHit.fromJson((r as Map).cast<String, dynamic>())],
        totalEstimate: (j['total_estimate'] ?? 0) as int,
        vectorSources: ((j['vector_sources'] as List?) ?? const []).cast<String>(),
        keywordOnlySources: ((j['keyword_only_sources'] as List?) ?? const []).cast<String>(),
      );

  final List<SearchHit> results;
  final int totalEstimate;
  final List<String> vectorSources;
  final List<String> keywordOnlySources;
}

/// A query embedding made by the caller; the core uses it only for libraries embedded with [model].
class QueryVector {
  const QueryVector(this.model, this.vector);

  final String model;
  final List<double> vector;

  Map<String, dynamic> toJson() => {'model': model, 'vector': vector};
}

/// What cs_read returns. [author], [page] and [sourceType] are only set for libraries.
class ReadResult {
  const ReadResult({required this.address, required this.title, required this.text, required this.truncated, this.author, this.page, this.sourceType});

  factory ReadResult.fromJson(Map<String, dynamic> j) => ReadResult(
        address: j['address'] as String,
        title: (j['title'] ?? '') as String,
        text: (j['text'] ?? '') as String,
        truncated: (j['truncated'] ?? false) as bool,
        author: j['author'] as String?,
        page: j['page'] as int?,
        sourceType: j['source_type'] as String?,
      );

  final String address;
  final String title;
  final String text;
  final bool truncated;
  final String? author;
  final int? page;
  final String? sourceType;
}

class Suggestion {
  const Suggestion({required this.title, required this.address, required this.sourceId});

  factory Suggestion.fromJson(Map<String, dynamic> j) =>
      Suggestion(title: (j['title'] ?? '') as String, address: j['address'] as String, sourceId: (j['source_id'] ?? '') as String);

  final String title;
  final String address;
  final String sourceId;
}

/// One entry of cs_status. [id] is null for a source that could not be opened (see [error]).
class SourceStatus {
  const SourceStatus({
    required this.id,
    required this.kind,
    required this.path,
    required this.title,
    required this.indexed,
    required this.building,
    required this.stale,
    required this.opening,
    required this.updating,
    required this.docs,
    this.error,
  });

  factory SourceStatus.fromJson(Map<String, dynamic> j) {
    final e = j['error'];
    return SourceStatus(
      id: j['id'] as String?,
      kind: (j['kind'] ?? '') as String,
      path: (j['path'] ?? '') as String,
      title: (j['title'] ?? '') as String,
      indexed: (j['indexed'] ?? false) as bool,
      building: (j['building'] ?? false) as bool,
      stale: (j['stale'] ?? false) as bool,
      opening: (j['opening'] ?? false) as bool,
      updating: (j['updating'] ?? false) as bool,
      docs: (j['docs'] ?? 0) as int,
      error: e is Map ? CoreSourceError(e['code'] as String, (e['message'] ?? '') as String) : null,
    );
  }

  final String? id;
  final String kind;
  final String path;
  final String title;
  final bool indexed;
  final bool building;
  final bool stale;
  final bool opening;
  final bool updating;
  final int docs;
  final CoreSourceError? error;

  /// True when search can use this source right now.
  bool get searchable => id != null && indexed && !building && !opening && !updating && error == null;
}

class CoreSourceError {
  const CoreSourceError(this.code, this.message);

  final String code;
  final String message;
}

/// One number of the conversation's id map.
class ConversationId {
  const ConversationId({required this.n, required this.address, required this.title});

  factory ConversationId.fromJson(Map<String, dynamic> j) =>
      ConversationId(n: j['n'] as int, address: j['address'] as String, title: (j['title'] ?? '') as String);

  final int n;
  final String address;
  final String title;
}

/// What cs_format returns: the exact tool message and the id map so far.
class FormattedResults {
  const FormattedResults({required this.toolMessage, required this.ids});

  factory FormattedResults.fromJson(Map<String, dynamic> j) => FormattedResults(
        toolMessage: (j['tool_message'] ?? '') as String,
        ids: [for (final i in (j['ids'] as List? ?? const [])) ConversationId.fromJson((i as Map).cast<String, dynamic>())],
      );

  final String toolMessage;
  final List<ConversationId> ids;
}

/// What cs_tool returns: [content] is exactly the tool message the model sees; [ids] are the numbers this call gave.
class ToolOutput {
  const ToolOutput({required this.content, required this.ids});

  factory ToolOutput.fromJson(Map<String, dynamic> j) => ToolOutput(
        content: (j['content'] ?? '') as String,
        ids: [for (final i in (j['ids'] as List? ?? const [])) ConversationId.fromJson((i as Map).cast<String, dynamic>())],
      );

  final String content;
  final List<ConversationId> ids;
}

enum JobState { running, done, cancelled, failed }

class JobProgress {
  const JobProgress({required this.state, required this.done, required this.total, this.errorCode, this.errorMessage, this.bytes});

  factory JobProgress.fromJson(Map<String, dynamic> j) {
    final e = j['error'];
    return JobProgress(
      state: JobState.values.firstWhere((s) => s.name == j['state'], orElse: () => JobState.failed),
      done: (j['done'] ?? 0) as int,
      total: (j['total'] ?? 0) as int,
      errorCode: e is Map ? e['code'] as String? : null,
      errorMessage: e is Map ? e['message'] as String? : null,
      bytes: j['detail'] is Map ? ((j['detail'] as Map)['bytes'] as num?)?.toInt() : null,
    );
  }

  final JobState state;
  final int done;
  final int total;
  final String? errorCode;
  final String? errorMessage;

  /// Bytes written so far (layer downloads).
  final int? bytes;

  bool get isFinished => state != JobState.running;

  /// 0..1, or null while the total is not known yet.
  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
}
