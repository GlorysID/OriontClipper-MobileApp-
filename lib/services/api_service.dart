import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/clip_item.dart';

/// Error terpadu dari backend OriontClipper.
class ApiError implements Exception {
  final String message;
  final int? statusCode;

  ApiError(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// Konfigurasi terpusat (singleton) untuk koneksi ke Python backend.
/// Nilai disimpan di SharedPreferences: `api_base_url` & `api_token`.
class ApiConfig {
  static const String defaultBaseUrl = 'http://127.0.0.1:8768';
  static const String kBaseUrl = 'api_base_url';
  static const String kToken = 'api_token';
  static const String kPreferredModel = 'pref_groq_model';

  static final ApiConfig instance = ApiConfig._();

  ApiConfig._();

  String baseUrl = defaultBaseUrl;
  String apiToken = '';
  String preferredModel = '';

  bool _loaded = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = _normalize(prefs.getString(kBaseUrl) ?? defaultBaseUrl);
    apiToken = prefs.getString(kToken) ?? '';
    preferredModel = prefs.getString(kPreferredModel) ?? '';
    _loaded = true;
  }

  Future<void> ensureLoaded() async {
    if (!_loaded) await load();
  }

  Future<void> saveBaseUrl(String value) async {
    baseUrl = _normalize(value.isEmpty ? defaultBaseUrl : value.trim());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kBaseUrl, baseUrl);
  }

  Future<void> saveToken(String value) async {
    apiToken = value.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kToken, apiToken);
  }

  Future<void> savePreferredModel(String modelId) async {
    preferredModel = modelId.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPreferredModel, preferredModel);
  }

  /// Pola "host:port" tanpa scheme (mis. `127.0.0.1:8768`, `localhost:8768`,
  /// `clipserver.local:8768`) yang harus diluruskan jadi http://.
  static final RegExp _hostPortOnly = RegExp(r'^[\w.\-]+(:\d+)?(/[^\s]*)?$');

  static String _normalize(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.isEmpty) return defaultBaseUrl;
    // UX: user sering mengetik host:port saja. Tanpa scheme, Uri.parseanggap
    // "127.0.0.1" sebagai scheme → semua request rusak. Tambahkan http://
    // hanya untuk nilai yang benar-benar tampak seperti host[:port] (tanpa
    // spasi) supaya input aneh tidak "dibetulkan" secara diam-diam.
    if (!u.contains('://') && !u.contains(' ') && _hostPortOnly.hasMatch(u)) {
      u = 'http://$u';
    }
    return u;
  }

  Uri uri(String path, {Map<String, String>? query}) {
    final u = Uri.parse('$baseUrl$path');
    return query == null || query.isEmpty ? u : u.replace(queryParameters: query);
  }

  /// Path media server (video/thumbnail) yang akan dibuka oleh video_player,
  /// Image.network, atau browser download — tidak bisa kirim header
  /// `X-Api-Token`, jadi token harus lewat query `?token=` (kontrak v1.1).
  static bool _isMediaPath(String url) => url.contains('/v1/media/');

  /// Tempel `?token=` (atau `&token=`) pada URL media. Idempoten: URL yang
  /// sudah punya parameter `token` tidak diubah lagi, karena clip.videoUrl
  /// bisa di-absolutize lebih dari sekali (setiap poll + saat load katalog).
  String _withMediaToken(String url) {
    final token = apiToken;
    if (token.isEmpty || !_isMediaPath(url)) return url;
    final parsed = Uri.tryParse(url);
    if (parsed == null) return url;
    if (parsed.queryParameters.containsKey('token')) return url;
    final qp = Map<String, String>.of(parsed.queryParameters)..['token'] = token;
    return parsed.replace(queryParameters: qp).toString();
  }

  /// Ubah path relatif server (mis. `/v1/media/1/clip_2.mp4`) menjadi URL
  /// absolut. Untuk URL media, token ikut ditempel sebagai query param.
  String absolute(String pathOrUrl) {
    final isAbsolute =
        pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://');
    final url = isAbsolute
        ? pathOrUrl
        : '$baseUrl${pathOrUrl.startsWith('/') ? pathOrUrl : '/$pathOrUrl'}';
    return _withMediaToken(url);
  }

  /// URL unduhan (Content-Disposition: attachment) untuk satu mp4 klip.
  /// [videoUrl] boleh absolut atau path relatif; token ditangani [absolute].
  String downloadUrl(String videoUrl) {
    final url = absolute(videoUrl);
    return url.contains('?') ? '$url&dl=1' : '$url?dl=1';
  }

  Map<String, String> get headers {
    return {
      'Content-Type': 'application/json',
      if (apiToken.isNotEmpty) 'X-Api-Token': apiToken,
    };
  }

  String get shortHostLabel {
    try {
      final u = Uri.parse(baseUrl);
      final port = u.hasPort ? ':${u.port}' : '';
      return '${u.host}$port';
    } catch (_) {
      return baseUrl;
    }
  }
}

class HealthInfo {
  final bool ok;
  final String version;
  final bool busy;
  final double uptimeS;

  HealthInfo({required this.ok, required this.version, required this.busy, required this.uptimeS});

  factory HealthInfo.fromJson(Map<String, dynamic> json) => HealthInfo(
        ok: json['ok'] == true,
        version: json['version']?.toString() ?? '?',
        busy: json['busy'] == true,
        uptimeS: _toDouble(json['uptime_s'], 0),
      );
}

class AiModelInfo {
  final String id;
  final String name;
  final String tag;
  final String desc;

  AiModelInfo({required this.id, required this.name, required this.tag, required this.desc});

  factory AiModelInfo.fromJson(Map<String, dynamic> json) => AiModelInfo(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? (json['id']?.toString() ?? ''),
        tag: json['tag']?.toString() ?? '',
        desc: json['desc']?.toString() ?? '',
      );
}

class ModelsResponse {
  final List<AiModelInfo> models;
  final String defaultModel;

  ModelsResponse({required this.models, required this.defaultModel});

  factory ModelsResponse.fromJson(Map<String, dynamic> json) => ModelsResponse(
        models: (json['models'] as List? ?? const [])
            .map((m) => AiModelInfo.fromJson((m is Map) ? m.cast<String, dynamic>() : const {}))
            .where((m) => m.id.isNotEmpty)
            .toList(),
        defaultModel: json['default']?.toString() ?? '',
      );
}

class JobStatus {
  final String jobId;
  final String status; // queued | running | done | failed
  final String stage;
  final double progress; // 0..1
  final List<ClipItem> clips;
  final String? error;

  JobStatus({
    required this.jobId,
    required this.status,
    required this.stage,
    required this.progress,
    required this.clips,
    this.error,
  });

  /// Status 'cancelled' ikut terminal: klien tidak boleh memutar progress
  /// selamanya untuk job yang user batalkan (item 14).
  bool get isTerminal =>
      status == 'done' || status == 'failed' || status == 'cancelled';

  factory JobStatus.fromJson(Map<String, dynamic> json) {
    final rawClips = (json['clips'] as List? ?? const []);
    final clips = rawClips
        .map((c) => ClipItem.fromJson((c is Map) ? c.cast<String, dynamic>() : const {}))
        .toList();
    return JobStatus(
      jobId: json['jobId']?.toString() ?? '',
      status: json['status']?.toString() ?? 'queued',
      stage: json['stage']?.toString() ?? '',
      progress: _toDouble(json['progress'], 0).clamp(0.0, 1.0),
      clips: clips,
      error: json['error']?.toString(),
    );
  }
}

class UploadResult {
  final String fileId;
  final String name;
  final int sizeBytes;

  UploadResult({required this.fileId, required this.name, required this.sizeBytes});

  factory UploadResult.fromJson(Map<String, dynamic> json) => UploadResult(
        fileId: json['fileId']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        sizeBytes: _toInt(json['sizeBytes'], 0),
      );
}

/// Klien typed untuk Python backend (kontrak /v1). Semua akses jaringan
/// aplikasi melewati layanan ini — tidak ada panggilan langsung ke Groq/oEmbed.
class ApiService {
  static final ApiService shared = ApiService._();

  /// Injeksi client HTTP untuk test (dipakai test/widget_test.dart & seam job tracker).
  /// Produksi tidak pernah memanggil ini → client default tetap http.Client().
  static void installTestClient(http.Client client) {
    shared._client = client;
  }

  static const Duration _defaultTimeout = Duration(seconds: 30);
  static const Duration _uploadTimeout = Duration(seconds: 120);

  ApiService._();

  http.Client _client = http.Client();

  ApiConfig get config => ApiConfig.instance;

  Future<void> _ensureReady() => config.ensureLoaded();

  Future<Map<String, dynamic>> _getJson(Uri uri, {Duration timeout = _defaultTimeout}) async {
    await _ensureReady();
    try {
      final res = await _client.get(uri, headers: config.headers).timeout(timeout);
      return _decode(res);
    } on http.ClientException catch (e) {
      throw ApiError('Tidak dapat menghubungi server: ${e.message}');
    } on TimeoutException {
      throw ApiError('Server tidak merespons (timeout ${timeout.inSeconds}s).');
    }
  }

  Future<Map<String, dynamic>> _sendJson(
    String method,
    Uri uri,
    Map<String, dynamic>? body, {
    Duration timeout = _defaultTimeout,
  }) async {
    await _ensureReady();
    final request = http.Request(method, uri);
    request.headers.addAll(config.headers);
    if (body != null) request.body = jsonEncode(body);
    try {
      // Lewat _client (bukan request.send()) supaya client injeksi-test dipakai.
      final streamed = await _client.send(request).timeout(timeout);
      final res = await http.Response.fromStream(streamed);
      return _decode(res);
    } on http.ClientException catch (e) {
      throw ApiError('Tidak dapat menghubungi server: ${e.message}');
    } on TimeoutException {
      throw ApiError('Server tidak merespons (timeout ${timeout.inSeconds}s).');
    }
  }

  Map<String, dynamic> _decode(http.Response res) {
    dynamic data;
    if (res.body.isNotEmpty) {
      try {
        data = jsonDecode(res.body);
      } catch (_) {
        data = null;
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (data is Map) return data.cast<String, dynamic>();
      return <String, dynamic>{};
    }
    final msg = data is Map
        ? (data['error']?.toString() ?? data['detail']?.toString() ?? res.body)
        : res.body;
    throw ApiError(
      msg.trim().isEmpty ? 'Server merespons ${res.statusCode} tanpa pesan.' : msg.trim(),
      statusCode: res.statusCode,
    );
  }

  Future<HealthInfo> health() async {
    final data = await _getJson(config.uri('/v1/health'), timeout: const Duration(seconds: 8));
    return HealthInfo.fromJson(data);
  }

  Future<ModelsResponse> models() async {
    final data = await _getJson(config.uri('/v1/models'));
    return ModelsResponse.fromJson(data);
  }

  /// Metadata judul/author untuk sebuah URL sumber (via server).
  Future<Map<String, String>?> metadata(String url) async {
    final data = await _getJson(config.uri('/v1/media/metadata', query: {'url': url}));
    final title = data['title']?.toString() ?? '';
    final author = data['author']?.toString() ?? '';
    if (title.isEmpty && author.isEmpty) return null;
    return {'title': title, 'author': author};
  }

  Future<String> createCurationJob({
    required String sourceType,
    String? url,
    String? fileId,
    required int durationSeconds,
    required int targetClipCount,
    required String templatePreset,
    required bool campaignActive,
    required String campaignRules,
    required String position,
    required String highlightColor,
    String? preferredModel,
    String? language,
  }) async {
    final body = <String, dynamic>{
      'source': {
        'type': sourceType,
        'url': url,
        'file_id': fileId,
      },
      'duration_seconds': durationSeconds,
      'target_clip_count': targetClipCount,
      'template_preset': templatePreset,
      'campaign': {
        'active': campaignActive,
        'rules_text': campaignRules,
      },
      'style': {
        'position': position,
        'highlight_color': highlightColor,
      },
      'preferred_model': preferredModel,
      'language': language,
    };
    final data = await _sendJson(
      'POST',
      config.uri('/v1/jobs/curation'),
      body,
      timeout: const Duration(seconds: 30),
    );
    final jobId = data['jobId']?.toString() ?? '';
    if (jobId.isEmpty) throw ApiError('Server tidak mengembalikan jobId yang valid.');
    return jobId;
  }

  /// Sekali cek status job (GET /v1/jobs/{id}) — timeout 30s.
  Future<JobStatus> pollJob(String jobId) async {
    final data = await _getJson(config.uri('/v1/jobs/$jobId'));
    final job = JobStatus.fromJson(data);
    _absolutizeClipUrls(job);
    return job;
  }

  /// Poll job dengan backoff 1s..3s sampai done/failed.
  /// [onUpdate] dipanggil setiap progress berubah untuk feedback UI.
  Future<JobStatus> runJob(
    String jobId, {
    void Function(JobStatus job)? onUpdate,
    Duration maxDuration = const Duration(minutes: 30),
  }) async {
    final deadline = DateTime.now().add(maxDuration);
    int delayMs = 1000;
    int consecutiveErrors = 0;

    while (true) {
      await Future.delayed(Duration(milliseconds: delayMs));
      JobStatus job;
      try {
        job = await pollJob(jobId);
        consecutiveErrors = 0;
      } on ApiError catch (e) {
        if (e.statusCode == 404) rethrow;
        consecutiveErrors++;
        if (consecutiveErrors >= 3) rethrow;
        delayMs = (delayMs + 500).clamp(1000, 3000);
        if (DateTime.now().isAfter(deadline)) {
          throw ApiError('Server berhenti merespons status job.');
        }
        continue;
      }
      onUpdate?.call(job);
      if (job.isTerminal) return job;
      delayMs = ((delayMs * 1.5).round()).clamp(1000, 3000);
      if (DateTime.now().isAfter(deadline)) {
        throw ApiError('Waktu tunggu job melebihi ${maxDuration.inMinutes} menit.');
      }
    }
  }

  Future<void> deleteJob(String jobId) async {
    await _sendJson('DELETE', config.uri('/v1/jobs/$jobId'), null);
  }

  /// Batalkan job yang masih berjalan (v1.1). 409 = sudah selesai/gagal.
  Future<void> cancelJob(String jobId) async {
    await _sendJson('POST', config.uri('/v1/jobs/$jobId/cancel'), null);
  }

  /// Upload bytes video via multipart (field "file") — timeout 120s.
  Future<UploadResult> uploadFile(List<int> bytes, String name) async {
    await _ensureReady();
    final request = http.MultipartRequest('POST', config.uri('/v1/media/upload'));
    if (config.apiToken.isNotEmpty) {
      request.headers['X-Api-Token'] = config.apiToken;
    }
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: name));
    try {
      final streamed = await request.send().timeout(_uploadTimeout);
      final res = await http.Response.fromStream(streamed);
      return UploadResult.fromJson(_decode(res));
    } on http.ClientException catch (e) {
      throw ApiError('Upload gagal: ${e.message}');
    } on TimeoutException {
      throw ApiError('Upload gagal: server tidak merespons (timeout ${_uploadTimeout.inSeconds}s).');
    }
  }

  Future<void> renderClip(String jobId, int index, {bool force = false}) async {
    final uri = config.uri('/v1/jobs/$jobId/clips/$index/render');
    await _sendJson('POST', uri, force ? <String, dynamic>{'force': true} : null);
  }

  /// Render semua klip satu job. [force] = true menembus gerbang compliance
  /// server (kontrak v1.1). Server membalas `{rendered:[...], skipped:[{index,
  /// reason}]}` — daftar skipped WAJIB diteruskan ke UI agar klip yang dilanggar
  /// tidak tampak "hilang diam-diam" (bug lama: discarded di :418-424).
  Future<RenderAllResult> renderAll(String jobId, {bool force = false}) async {
    final data = await _sendJson(
      'POST',
      config.uri('/v1/jobs/$jobId/render-all'),
      force ? <String, dynamic>{'force': true} : null,
    );
    return RenderAllResult.fromJson(data);
  }

  Future<Map<String, dynamic>> getCampaignPolicy() async {
    return _getJson(config.uri('/v1/campaign-policy'));
  }

  Future<void> putCampaignPolicy(bool isCustom, String rulesText) async {
    await _sendJson(
      'PUT',
      config.uri('/v1/campaign-policy'),
      {'isCustom': isCustom, 'rulesText': rulesText},
    );
  }

  // ── Cookies (v1.1: GET/POST/DELETE /v1/cookies) ──────────────────────────

  /// Status cookie di server. Jujur: hanya berisi apa yang server katakan.
  Future<CookieStatus> getCookies() async {
    final data = await _getJson(config.uri('/v1/cookies'), timeout: const Duration(seconds: 10));
    return CookieStatus.fromJson(data);
  }

  /// Unggah teks Netscape mentah (raw text, bukan JSON). 400 bila tidak valid.
  Future<void> postCookies(String text) async {
    await _ensureReady();
    final request = http.Request('POST', config.uri('/v1/cookies'));
    request.headers.addAll(config.headers);
    request.headers['Content-Type'] = 'text/plain; charset=utf-8';
    request.body = text;
    try {
      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 20));
      _decode(await http.Response.fromStream(streamed));
    } on http.ClientException catch (e) {
      throw ApiError('Tidak dapat menghubungi server: ${e.message}');
    } on TimeoutException {
      throw ApiError('Server tidak merespons saat menyimpan cookies.');
    }
  }

  Future<void> deleteCookies() async {
    await _sendJson('DELETE', config.uri('/v1/cookies'), null);
  }

  String clipVideoUrl(String jobId, int index) =>
      config.absolute('/v1/media/$jobId/clip_$index.mp4');

  /// Thumb server dikirim sebagai path relatif `/v1/media/{job}/thumb_{i}.jpg`.
  String clipThumbnailUrl(String jobId, int index) =>
      config.absolute('/v1/media/$jobId/thumb_$index.jpg');

  void _absolutizeClipUrls(JobStatus job) {
    final clips = job.clips;
    for (var i = 0; i < clips.length; i++) {
      final clip = clips[i];
      // KONTRAK v1.1 FINAL: server mengirim "index" 1-based → sudah masuk ke
      // clip.renderIndex lewat ClipItem.fromJson. Fallback posisi (i+1) hanya
      // pembelaan untuk server lama/rusak; endpoint clips/{index} & file
      // clip_{i}.mp4 memakai nilai ini.
      final index = clip.renderIndex ?? (i + 1);
      clip.renderIndex = index;

      final raw = clip.videoUrl;
      if (raw != null && raw.isNotEmpty) {
        clip.videoUrl = config.absolute(raw);
      } else if (clip.renderStatus == 'done') {
        clip.videoUrl = clipVideoUrl(job.jobId, index);
      }
      final rawThumb = clip.thumbnailUrl;
      if (rawThumb != null && rawThumb.isNotEmpty) {
        clip.thumbnailUrl = config.absolute(rawThumb);
      }
    }
  }
}

/// Hasil POST /v1/jobs/{id}/render-all.
class RenderAllResult {
  final List<int> rendered;
  final List<SkippedClip> skipped;

  RenderAllResult({required this.rendered, required this.skipped});

  factory RenderAllResult.fromJson(Map<String, dynamic> json) {
    final rendered = (json['rendered'] as List? ?? const [])
        .map((e) => _toInt(e, 0))
        .where((i) => i > 0)
        .toList();
    final skipped = <SkippedClip>[];
    for (final entry in (json['skipped'] as List? ?? const [])) {
      if (entry is! Map) {
        final idx = _toInt(entry, 0);
        if (idx > 0) skipped.add(SkippedClip(index: idx, reason: ''));
        continue;
      }
      final idx = _toInt(entry['index'] ?? entry['clipIndex'], 0);
      if (idx <= 0) continue;
      skipped.add(SkippedClip(
        index: idx,
        reason: (entry['reason'] ?? entry['error'] ?? '').toString(),
      ));
    }
    return RenderAllResult(rendered: rendered, skipped: skipped);
  }
}

class SkippedClip {
  final int index;
  final String reason;

  SkippedClip({required this.index, required this.reason});
}

/// Status cookie di server (GET /v1/cookies).
class CookieStatus {
  final bool hasCookies;
  final DateTime? updated;

  CookieStatus({required this.hasCookies, this.updated});

  factory CookieStatus.fromJson(Map<String, dynamic> json) => CookieStatus(
        hasCookies: json['hasCookies'] == true,
        updated: DateTime.tryParse(json['updated']?.toString() ?? ''),
      );

  String get updatedLabel {
    final u = updated;
    if (u == null) return 'belum pernah diperbarui';
    final local = u.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

/// Indeks 1-based klip di dalam job (untuk endpoint clips/{index} & file
/// clip_{i}.mp4). Sumber kebenaran berjenjang:
/// 1. `clip.renderIndex` — posisi klip dalam daftar balasan server (diisi
///    [ApiService._absolutizeClipUrls] saat delivery/poll, ikut dipersisten);
/// 2. peta `clip_job_map_v1` (index yang ikut tersimpan saat klip masuk);
/// 3. fallback warisan: suffix id / rank.
///
/// Peringkat (rank) sengaja tidak pernah dipakai lebih dulu: server boleh
/// mengirim klip dalam urutan berbeda atau memberi rank duplikat, dan index
/// yang salah me-render klip lain (bug off-by-one lama).
int clipIndexOf(ClipItem clip) {
  final direct = clip.renderIndex;
  if (direct != null && direct > 0) return direct;
  final stored = ClipJobMap.indexCacheFor(clip.id);
  if (stored != null && stored > 0) return stored;
  return ClipJobMap.legacyIndexFromId(clip);
}

/// Peta persisten clipId -> {jobId, index} (SharedPreferences `clip_job_map_v1`),
/// dipelihara main.dart saat klip hasil kurasi masuk katalog.
///
/// Format tersimpan: `{"clip_1": {"jobId": "7", "index": 1}}`.
/// Nilai lama berupa String jobId polos tetap didekode (index null → fallback
/// lihat [legacyIndexFromId]).
class ClipJobMap {
  static const String storageKey = 'clip_job_map_v1';

  /// Cache sinkron (dibaca clipIndexOf di jalur render/UI). Diisi ulang setiap
  /// load/putAll/removeClips/clearAll, dan sengaja boleh basi untuk request
  /// pertama sebelum prefs sempat terbaca — fallback meredamnya.
  static Map<String, ClipJobRef> _cache = <String, ClipJobRef>{};

  static Map<String, ClipJobRef> get cache => _cache;

  static Future<Map<String, ClipJobRef>> load() async {
    final prefs = await SharedPreferences.getInstance();
    _cache = _decode(prefs.getString(storageKey));
    return _cache;
  }

  static Map<String, ClipJobRef> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <String, ClipJobRef>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, ClipJobRef>{};
      final out = <String, ClipJobRef>{};
      decoded.forEach((k, v) {
        final id = k.toString();
        if (v is Map) {
          final jobId = v['jobId']?.toString() ?? '';
          if (jobId.isEmpty) return;
          out[id] = ClipJobRef(jobId, _toIntOrNull(v['index']));
        } else {
          final jobId = v?.toString() ?? '';
          if (jobId.isEmpty) return;
          out[id] = ClipJobRef(jobId, null); // warisan: hanya jobId
        }
      });
      return out;
    } catch (_) {
      return <String, ClipJobRef>{};
    }
  }

  /// Simpan jobId + posisi 1-based klip dalam batch.
  static Future<void> putAll(String jobId, List<ClipItem> clips) async {
    final map = await load();
    for (var i = 0; i < clips.length; i++) {
      final c = clips[i];
      map[c.id] = ClipJobRef(jobId, c.renderIndex ?? (i + 1));
    }
    await _save(map);
  }

  static Future<void> _save(Map<String, ClipJobRef> map) async {
    _cache = map;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      storageKey,
      jsonEncode(map.map(
        (k, v) => MapEntry(k, <String, dynamic>{'jobId': v.jobId, 'index': v.index}),
      )),
    );
  }

  static String? jobIdForSync(String clipId) => _cache[clipId]?.jobId;

  static int? indexCacheFor(String clipId) => _cache[clipId]?.index;

  static Future<String?> jobIdFor(String clipId) async {
    final ref = _cache[clipId] ?? (await load())[clipId];
    return ref?.jobId;
  }

  static Future<ClipJobRef?> refFor(String clipId) async {
    return _cache[clipId] ?? (await load())[clipId];
  }

  static Future<void> removeClips(List<String> clipIds) async {
    final map = await load();
    map.removeWhere((k, v) => clipIds.contains(k));
    await _save(map);
  }

  /// Bersihkan seluruh peta (dipakai "Hapus semua" di Reset data).
  static Future<void> clearAll() async {
    _cache = <String, ClipJobRef>{};
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
  }

  /// Hanya untuk test: buang cache in-memory agar tidak bocor ke test berikut.
  static void resetCacheForTest() {
    _cache = <String, ClipJobRef>{};
  }

  /// Fallback untuk klip lama (peta warisan tanpa index).
  ///
  /// RISIKO DICATAT: id klip dari server berbentuk `{jobId}_{position0based}`,
  /// jadi index = suffix + 1. Bila suffix tidak ada (klip lama/manual) kita
  /// jatuh ke rank — dan rank BISA duplikat atau tidak berurutan, sehingga
  /// index-nya bisa meleset satu. Hanya dipakai bila tak ada data lain yang
  /// lebih baik; bila terdeteksi duplikat, kembalikan 1 (klip pertama) daripada
  /// menebak index klip lain secara acak.
  static int legacyIndexFromId(ClipItem clip) {
    final suffix = int.tryParse(clip.id.split('_').last);
    if (suffix != null && suffix >= 0) return suffix + 1;
    if (clip.rank > 0) return clip.rank;
    return 1;
  }
}

/// Referensi job untuk satu klip: jobId server + indeks 1-based (null = warisan).
class ClipJobRef {
  final String jobId;
  final int? index;

  const ClipJobRef(this.jobId, this.index);

  Map<String, dynamic> toJson() => <String, dynamic>{'jobId': jobId, 'index': index};
}

int? _toIntOrNull(dynamic v) {
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '');
}

double _toDouble(dynamic v, double fallback) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? fallback;
}

int _toInt(dynamic v, int fallback) {
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? fallback;
}
