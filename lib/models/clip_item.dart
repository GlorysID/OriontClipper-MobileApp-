class ClipItem {
  final String id;
  String hook;
  final String topic;
  final String duration;
  final String timestamp;
  final int score;
  final String caption;
  String preset;
  final String sourceTitle;
  String script;
  final String complianceStatus; // 'COMPLIANT', 'REVIEW', 'NONE'
  final String complianceNote;
  String highlightColor; // Hex string e.g. '#ffe600'
  String position; // 'upper_center', 'top', 'center', 'lower'
  bool isRendered;
  final DateTime createdAt;

  // ─── Field kontrak backend /v1 (additive) ────────────────────────────────
  double? start; // detik mulai klip di video sumber
  double? end; // detik selesai klip di video sumber
  int rank; // urutan 1-based dari server
  String reason; // alasan kurasi AI kenapa momen ini dipilih
  String bgmMood; // suasana musik latar anjuran
  List<String> riskFlags; // daftar risiko compliance dari server
  List<String> campaignNotes; // catatan campaign dari server
  String? sourceUrl; // URL sumber asli klip
  String? videoUrl; // URL absolut mp4 hasil render server
  String? thumbnailUrl; // URL absolut jpg thumbnail hasil render (v1.1, bisa null)
  String renderStatus; // none|queued|rendering|done|failed

  /// Indeks 1-based klip di dalam job server. Sumber utama: field "index" dari
  /// balasan (kontrak v1.1 FINAL — dikirim untuk semua klip); fallback: posisi
  /// dalam daftar balasan (lihat ApiService._absolutizeClipUrls). Dipakai untuk
  /// endpoint clips/{index}/render — bukan rank, karena rank bisa duplikat.
  int? renderIndex;

  /// false = klip tanpa video (sumber tipe topic/test) → tidak bisa dirender.
  /// Default true agar klip contoh/lama tetap berperilaku seperti sebelumnya.
  bool renderable;

  ClipItem({
    required this.id,
    required this.hook,
    required this.topic,
    required this.duration,
    this.timestamp = '00:00 - 00:45',
    required this.score,
    required this.caption,
    required this.preset,
    this.sourceTitle = 'Sumber Video',
    this.script = '',
    this.complianceStatus = 'COMPLIANT',
    this.complianceNote = 'Sesuai dengan panduan konten viral',
    this.highlightColor = '#ffe600',
    this.position = 'upper_center',
    this.isRendered = false,
    DateTime? createdAt,
    this.start,
    this.end,
    this.rank = 0,
    this.reason = '',
    this.bgmMood = '',
    List<String>? riskFlags,
    List<String>? campaignNotes,
    this.sourceUrl,
    this.videoUrl,
    this.thumbnailUrl,
    this.renderStatus = 'none',
    this.renderIndex,
    this.renderable = true,
  })  : createdAt = createdAt ?? DateTime.now(),
        riskFlags = riskFlags ?? const [],
        campaignNotes = campaignNotes ?? const [];

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'hook': hook,
      'topic': topic,
      'duration': duration,
      'timestamp': timestamp,
      'score': score,
      'caption': caption,
      'preset': preset,
      'sourceTitle': sourceTitle,
      'script': script,
      'complianceStatus': complianceStatus,
      'complianceNote': complianceNote,
      'highlightColor': highlightColor,
      'position': position,
      'isRendered': isRendered,
      'createdAt': createdAt.toIso8601String(),
      'start': start,
      'end': end,
      'rank': rank,
      'reason': reason,
      'bgmMood': bgmMood,
      'riskFlags': riskFlags,
      'campaignNotes': campaignNotes,
      'sourceUrl': sourceUrl,
      'videoUrl': videoUrl,
      'thumbnailUrl': thumbnailUrl,
      'renderStatus': renderStatus,
      'renderIndex': renderIndex,
      'renderable': renderable,
    };
  }

  factory ClipItem.fromJson(Map<String, dynamic> json) {
    return ClipItem(
      id: json['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      hook: json['hook']?.toString() ?? 'Viral Hook Moment',
      topic: json['topic']?.toString() ?? 'Pembahasan Utama',
      duration: json['duration']?.toString() ?? '00:45',
      timestamp: json['timestamp']?.toString() ?? '00:00 - 00:45',
      score: (json['score'] is int)
          ? json['score'] as int
          : int.tryParse(json['score']?.toString() ?? '') ?? 95,
      caption: json['caption']?.toString() ?? '#fyp #shorts #viral #indonesia',
      preset: json['preset']?.toString() ?? 'CAPCUT EDITORIAL',
      sourceTitle: json['sourceTitle']?.toString() ?? 'Sumber Video',
      script: json['script']?.toString() ?? '',
      complianceStatus: json['complianceStatus']?.toString() ?? 'COMPLIANT',
      complianceNote: json['complianceNote']?.toString() ?? 'Sesuai dengan panduan konten viral',
      highlightColor: json['highlightColor']?.toString() ?? '#ffe600',
      position: json['position']?.toString() ?? 'upper_center',
      isRendered: json['isRendered'] == true,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      start: _toDoubleOrNull(json['start']),
      end: _toDoubleOrNull(json['end']),
      rank: _toIntOrNull(json['rank']) ?? 0,
      reason: json['reason']?.toString() ?? '',
      bgmMood: json['bgmMood']?.toString() ?? '',
      riskFlags: _toStringList(json['riskFlags']),
      campaignNotes: _toStringList(json['campaignNotes']),
      sourceUrl: json['sourceUrl']?.toString(),
      videoUrl: json['videoUrl']?.toString(),
      thumbnailUrl: json['thumbnailUrl']?.toString(),
      renderStatus: json['renderStatus']?.toString() ?? 'none',
      // KONTRAK v1.1 FINAL: server mengirim "index" 1-based di SETIAP klip
      // (reguler & topic; job lama di-backfill saat load). Index server adalah
      // sumber kebenaran utama; 'renderIndex' di JSON lokal hanya warisan nilai
      // yang diposisi-kan saat delivery (tetap dibaca untuk data lama).
      renderIndex: _toIntOrNull(json['index']) ?? _toIntOrNull(json['renderIndex']),
      // Field baru: bila server belum mengirimnya, anggap bisa dirender.
      renderable: json['renderable'] != false,
    );
  }

  ClipItem copyWith({
    String? hook,
    String? script,
    String? preset,
    String? highlightColor,
    String? position,
    bool? isRendered,
    double? start,
    double? end,
    int? rank,
    String? reason,
    String? bgmMood,
    List<String>? riskFlags,
    List<String>? campaignNotes,
    String? sourceUrl,
    String? videoUrl,
    String? renderStatus,
    String? thumbnailUrl,
    int? renderIndex,
    bool? renderable,
  }) {
    return ClipItem(
      id: id,
      hook: hook ?? this.hook,
      topic: topic,
      duration: duration,
      timestamp: timestamp,
      score: score,
      caption: caption,
      preset: preset ?? this.preset,
      sourceTitle: sourceTitle,
      script: script ?? this.script,
      complianceStatus: complianceStatus,
      complianceNote: complianceNote,
      highlightColor: highlightColor ?? this.highlightColor,
      position: position ?? this.position,
      isRendered: isRendered ?? this.isRendered,
      createdAt: createdAt,
      start: start ?? this.start,
      end: end ?? this.end,
      rank: rank ?? this.rank,
      reason: reason ?? this.reason,
      bgmMood: bgmMood ?? this.bgmMood,
      riskFlags: riskFlags ?? this.riskFlags,
      campaignNotes: campaignNotes ?? this.campaignNotes,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      videoUrl: videoUrl ?? this.videoUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      renderStatus: renderStatus ?? this.renderStatus,
      renderIndex: renderIndex ?? this.renderIndex,
      renderable: renderable ?? this.renderable,
    );
  }
}

double? _toDoubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

int? _toIntOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

List<String> _toStringList(dynamic v) {
  if (v is List) {
    return v.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList();
  }
  return const [];
}
