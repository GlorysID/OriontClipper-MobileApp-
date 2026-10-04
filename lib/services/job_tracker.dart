import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/clip_item.dart';
import 'api_service.dart';

/// Satu-satunya sumber kebenaran untuk job kurasi yang SEDANG berjalan.
///
/// Kenapa perlu singleton: sebelumnya loop polling hidup sebagai Future lokal
/// di dalam _StudioScreenState. Begitu user pindah tab (Studio di-dispose) atau
/// halaman browser di-reload, loop mati dan UI "lupa" job-nya — padahal server
/// masih memproses. JobTracker menahan state di luar widget tree dan
/// mempersistenkannya ke SharedPreferences (`active_job_v1`) supaya progress
/// tetap ada & bisa disambung ulang dari titik masuk mana pun.
class JobTracker extends ChangeNotifier {
  JobTracker._();

  static final JobTracker instance = JobTracker._();

  static const String storageKey = 'active_job_v1';

  /// id klip batch terakhir (`List<String>` di prefs) — dipakai Studio untuk
  /// menampilkan "Batch terakhir" setelah reload walau [lastDeliveryClips]
  /// hanya hidup di memori.
  static const String lastBatchKey = 'last_batch_v1';

  /// Kadens polling (bisa dikecilkan oleh test agar tidak menunggu 1 detik).
  int initialDelayMs = 1000;
  int maxDelayMs = 3000;
  Duration pollDeadline = const Duration(minutes: 30);

  /// Job yang tersimpan tapi tidak pernah di-update selama ini dianggap basi
  /// (browser ditutup, server sudah restart, dsb) → jangan poll selamanya.
  static const Duration staleAfter = Duration(hours: 6);

  // ── State job aktif ───────────────────────────────────────────────────────
  String? jobId;
  String sourceInputText = '';
  String status = 'idle'; // idle | queued | running | done | failed | detached
  String stage = '';
  double progress = 0.0;
  DateTime? startedAt;

  /// Watchdog melepas diri: server masih mengerjakan tapi batas waktu klien
  /// habis. Job TIDAK dinyatakan gagal — `active_job_v1` tetap disimpan agar
  /// boot berikutnya menyambung polling dengan deadline segar.
  bool isDetached = false;

  /// true bila [stage] saat ini adalah teks penanda detached (bukan stage
  /// server), supaya resumePolling bisa menggantinya tanpa menimpa stage asli.
  bool detachedStage = false;

  /// Hasil pengiriman terakhir (tetap ada sampai job berikutnya start) agar
  /// Studio bisa menampilkan klip batch terakhir walau sudah selesai.
  String? lastDeliveryJobId;
  List<ClipItem> lastDeliveryClips = const [];

  /// true setelah user menekan "Batalkan" (POST /v1/jobs/{id}/cancel terkirim).
  /// Sengaja client TIDAK langsung menghapus state: polling diteruskan sampai
  /// server mengonfirmasi, supaya UI tidak mengklaim "dibatalkan" padahal
  /// server masih mengerjakan (janji jujur item 14).
  bool cancelRequested = false;

  /// Pesan kegagalan terakhir yang sudah ditampilkan ke user (untuk snackbar).
  String? lastFailureMessage;

  /// Dipanggil shell saat job selesai (insert klip + ClipJobMap + snackbar).
  void Function(String jobId, List<ClipItem> clips)? onCompleted;

  /// Dipanggil shell saat job gagal / hilang dari server.
  void Function(String message)? onFailed;

  /// Dipanggil shell saat SERVER mengonfirmasi job dibatalkan (status
  /// 'cancelled') — optimistis: UI menahan kartu progress sampai kabar ini.
  void Function(String jobId)? onCancelled;

  /// Dipanggil shell saat watchdog melepas pemantauan (deadline tercapai tapi
  /// server masih mengerjakan) — pesan jujur, bukan kegagalan.
  void Function(String message)? onDetached;

  /// Dipanggil setelah SATU tick polling berhasil (GET /v1/jobs/{id} sukses).
  /// Dipakai Studio untuk menyegarkan health pill dengan murah (item 9a):
  /// selama job jalan kita sudah terhubung, begitu server mati pill ikut tahu.
  void Function()? onPolled;

  /// Job masih tersimpan dan perlu disambung saat boot — termasuk yang tadi
  /// melepas diri (detached), karena janji kita: pantau lagi setelah dibuka.
  bool get needsResume => jobId != null && (isBusy || isDetached);

  bool _polling = false;
  bool get isPolling => _polling;

  bool get isBusy =>
      jobId != null && (status == 'queued' || status == 'running');

  /// Copy jujur: yang survive dari menutup halaman adalah state di SERVER dan
  /// `active_job_v1` (pantau disambung saat dibuka kembali), BUKAN loop poll
  /// ini. Jangan janjikan "proses lanjut di latar" setelah browser ditutup.
  String get busyLabel =>
      'Memproses... proses tetap berjalan di server (buka kembali halaman untuk melanjutkan pemantauan)';

  /// Teks ringkas untuk kartu progress Studio.
  String get progressLabel {
    final s = stage.trim();
    if (s.isNotEmpty) return s;
    if (status == 'queued') return 'Mengantri di server...';
    if (status == 'running') return 'Sedang memproses di server...';
    if (status == 'detached') return 'Masih diproses server — buka kembali untuk pantau';
    return '';
  }

  int get percentLabel => (progress * 100).clamp(0, 100).toInt();

  // ── Siklus hidup ─────────────────────────────────────────────────────────

  /// Baca record persisten (tanpa mulai polling).
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await prefs.remove(storageKey);
        return;
      }
      final id = decoded['jobId']?.toString() ?? '';
      final st = decoded['status']?.toString() ?? 'running';
      final updated = DateTime.tryParse(decoded['updatedAt']?.toString() ?? '') ??
          DateTime.tryParse(decoded['startedAt']?.toString() ?? '');
      if (id.isEmpty) {
        await prefs.remove(storageKey);
        return;
      }
      // Terminal atau terlalu basi → jangan disambung, bersihkan diam-diam.
      // 'detached' sengaja TIDAK terminal: itu janji kita ke user bahwa job
      // akan dipantau ulang saat aplikasi dibuka kembali.
      final terminal = st == 'done' || st == 'failed';
      final detached = decoded['watchdog']?.toString() == 'detached';
      final stale = !detached &&
          (updated == null || DateTime.now().difference(updated) > staleAfter);
      if (terminal || stale) {
        await prefs.remove(storageKey);
        return;
      }
      jobId = id;
      sourceInputText = decoded['sourceInputText']?.toString() ?? '';
      status = st;
      stage = decoded['stage']?.toString() ?? '';
      progress = (decoded['progress'] is num)
          ? (decoded['progress'] as num).toDouble().clamp(0.0, 1.0)
          : 0.0;
      startedAt = DateTime.tryParse(decoded['startedAt']?.toString() ?? '');
      if (detached) {
        isDetached = true;
        detachedStage = true;
        // Status 'detached' dipertahankan apa adanya di UI (kartu progress +
        // tombol Pantau ulang), tapi boot tetap menyambung polling dengan
        // deadline baru lewat _rearmAfterRestore().
      }
      if (decoded['cancelRequested'] == true) {
        cancelRequested = true;
        // Jangan menimpa pesan watchdog detached dengan 'membatalkan...'.
        if (!detached) stage = 'membatalkan...';
      }
      _notify();
    } catch (_) {
      await prefs.remove(storageKey);
    }
  }

  /// Mulai job baru di sisi klien: simpan state lalu mulai polling.
  Future<void> start(String newJobId, {String sourceInput = ''}) async {
    jobId = newJobId;
    sourceInputText = sourceInput;
    status = 'queued';
    stage = 'Mengantri di server...';
    progress = 0.05;
    startedAt = DateTime.now();
    lastFailureMessage = null;
    cancelRequested = false;
    await _persist();
    _notify();
    unawaited(resumePolling());
  }

  /// User menekan "Batalkan". Tembak POST /v1/jobs/{id}/cancel dan tandai
  /// permintaan, TAPI jangan buang state dulu — [resumePolling] yang akan
  /// membersihkan UI begitu server menjawab cancelled (atau menjelaskan
  /// 409 = terlanjur selesai).
  ///
  /// Mengembalikan pesan error (null = permintaan diterima). 409 bukan
  /// kegagalan fatal: job toh akan terminal pada tick berikutnya.
  Future<String?> requestCancel() async {
    final id = jobId;
    if (id == null || id.isEmpty) return 'Tidak ada job aktif untuk dibatalkan.';
    cancelRequested = true;
    stage = 'membatalkan...';
    await _persist();
    _notify();
    try {
      await ApiService.shared.cancelJob(id);
      return null;
    } on ApiError catch (e) {
      if (e.statusCode == 409) {
        // Sudah selesai di server — biarkan polling mengambil hasilnya.
        return 'Job sudah selesai di server — tidak bisa dibatalkan.';
      }
      cancelRequested = false;
      _notify();
      return e.message;
    }
  }

  /// Sambung polling job aktif (dipanggil saat boot bila `active_job_v1` belum
  /// selesai, dan oleh [start]). Aman dipanggil berkali-kali: hanya satu loop
  /// per job. Memanggil ini saat watchdog sedang detached = "Pantau ulang"
  /// (deadline disegarkan, state detached dibuang).
  Future<void> resumePolling() async {
    final id = jobId;
    if (id == null) return;
    if (_polling) return;
    if (isDetached) {
      isDetached = false;
      if (status == 'detached') status = 'running';
      stage = 'Menyambung pemantauan...';
      await _persist();
      _notify();
    }
    _polling = true;
    try {
      await _pollLoop(id);
    } finally {
      _polling = false;
    }
  }

  /// Berhenti mengikuti job aktif (dipakai saat shell memutuskan job sudah
  /// tidak bisa dipulihkan, mis. state basi yang sengaja dibersihkan).
  Future<void> abandon() async {
    await _clearActive();
    lastFailureMessage = null;
    _notify();
  }

  Future<void> _pollLoop(String id) async {
    final deadline = DateTime.now().add(pollDeadline);
    var delayMs = initialDelayMs;
    var consecutiveErrors = 0;

    while (true) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      if (jobId != id) return; // diganti / dibatalkan

      JobStatus job;
      try {
        job = await ApiService.shared.pollJob(id);
        consecutiveErrors = 0;
      } on ApiError catch (e) {
        if (e.statusCode == 404) {
          // Server menghapus job yang dibatalkan → 404 setelah permintaan
          // batal adalah KONFIRMASI, bukan kegagalan kurasi.
          if (cancelRequested) {
            await _confirmCancelled(id);
            return;
          }
          await _fail(id, 'Job tidak ditemukan di server (server mungkin baru restart). Jalankan ulang kurasi di Studio.');
          return;
        }
        consecutiveErrors++;
        delayMs = (delayMs + 500).clamp(initialDelayMs, maxDelayMs);
        if (DateTime.now().isAfter(deadline)) {
          // Batas waktu habis: jangan nyatakan gagal, lepas saja (lihat _detach).
          await _detach(id, e.message);
          return;
        }
        if (consecutiveErrors >= 3) {
          await _fail(id, e.message);
          return;
        }
        continue;
      } catch (e) {
        await _fail(id, e.toString().replaceAll('Exception: ', ''));
        return;
      }

      if (jobId != id) return;

      // Tick sukses → beri tahu shell (health pill ikut segar, item 9a).
      onPolled?.call();

      // Item 14: pembatalan yang DIKONFIRMASI server. Server v1.1 (kontrak
      // beku) membalas 'cancelled', atau 'failed', atau 'done' tanpa klip
      // setelah cancel — ketiganya berarti batal selama user memang menekan
      // Batalkan. 'done' YANG ADA KLIP-nya tetap dikirim sebagai hasil.
      if (job.status == 'cancelled') {
        await _confirmCancelled(id);
        return;
      }
      if (cancelRequested &&
          (job.status == 'failed' || (job.status == 'done' && job.clips.isEmpty))) {
        await _confirmCancelled(id);
        return;
      }

      final hasAdvance = job.progress > progress;
      progress = hasAdvance ? job.progress : progress;
      if (job.stage.trim().isNotEmpty) stage = job.stage;
      status = job.status;
      await _persist();
      _notify();

      if (job.status == 'done') {
        if (job.clips.isEmpty) {
          await _fail(id, 'Server selesai kurasi tapi tidak menghasilkan klip apa pun.');
          return;
        }
        await _complete(id, job.clips);
        return;
      }
      if (job.status == 'failed') {
        final msg = (job.error?.trim().isNotEmpty ?? false)
            ? job.error!.trim()
            : (stage.trim().isNotEmpty ? stage.trim() : 'Kurasi gagal di server.');
        await _fail(id, msg);
        return;
      }

      // Progress masih jalan → klien sengaja melepas pemantauan, BUKAN
      // menyatakan gagal (30 menit adalah batas SABAR kita, bukan batas
      // kerja server). `active_job_v1` ditinggal supaya boot berikutnya
      // menyambung dengan deadline baru dan user tidak perlu kurasi ulang.
      delayMs = ((delayMs * 1.5).round()).clamp(initialDelayMs, maxDelayMs);
      if (DateTime.now().isAfter(deadline)) {
        await _detach(id, 'Masih diproses server — buka kembali untuk pantau');
        return;
      }
    }
  }

  /// Lepas pemantauan tanpa menyatakan job gagal.
  Future<void> _detach(String id, String message) async {
    if (jobId != id) return;
    isDetached = true;
    detachedStage = true;
    status = 'detached';
    stage = message;
    await _persist();
    _notify();
    onDetached?.call(message);
  }

  /// Konfirmasi pembatalan dari server: bersihkan state aktif, laporkan ke
  /// shell. Tidak ada klaim gagal & tidak ada klip yang dianggap hasil.
  Future<void> _confirmCancelled(String id) async {
    cancelRequested = false;
    await _clearActive();
    _notify();
    onCancelled?.call(id);
  }

  Future<void> _complete(String id, List<ClipItem> clips) async {
    lastDeliveryJobId = id;
    lastDeliveryClips = List<ClipItem>.unmodifiable(clips);
    // Simpan HANYA id klip batch terakhir (kontrak item 12: prefs 'last_batch_v1').
    // Katalog penuh tetap hidup di `saved_clips_v1` milik shell; Studio tidak
    // boleh merender seluruh library, jadi cukup id untuk memulihkan batch
    // yang sama setelah reload.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      lastBatchKey,
      clips.map((c) => c.id).toList(growable: false),
    );
    await _clearActive();
    _notify();
    onCompleted?.call(id, clips);
  }

  /// Pemulihan setelah reload: [lastDeliveryClips] adalah state memori, jadi
  /// shell memanggil ini dengan katalog tersimpan untuk menyusun ulang batch
  /// terakhir dari id yang di-persisten.
  void restoreLastBatch(List<ClipItem> savedClips) {
    if (lastDeliveryClips.isNotEmpty) return;
    final ids = _lastBatchIds;
    if (ids == null || ids.isEmpty) return;
    final byId = <String, ClipItem>{
      for (final c in savedClips) c.id: c,
    };
    final clips = <ClipItem>[
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
    if (clips.isEmpty) return;
    lastDeliveryClips = List<ClipItem>.unmodifiable(clips);
    lastDeliveryJobId ??= ClipJobMap.jobIdForSync(clips.first.id);
  }

  List<String>? _lastBatchIds;

  /// Baca id batch terakhir dari prefs (dipanggil shell saat boot).
  Future<void> loadLastBatchIds() async {
    final prefs = await SharedPreferences.getInstance();
    _lastBatchIds = prefs.getStringList(lastBatchKey);
  }

  Future<void> _fail(String id, String message) async {
    lastFailureMessage = message;
    await _clearActive();
    _notify();
    onFailed?.call(message);
  }

  Future<void> _clearActive() async {
    jobId = null;
    sourceInputText = '';
    status = 'idle';
    stage = '';
    progress = 0.0;
    startedAt = null;
    isDetached = false;
    detachedStage = false;
    cancelRequested = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
  }

  Future<void> _persist() async {
    final id = jobId;
    if (id == null) return;
    final prefs = await SharedPreferences.getInstance();
    // SharedPreferences.setString bersifat atomik per key (tmp+replace di
    // backend web/android), jadi tidak perlu lock tambahan.
    await prefs.setString(
      storageKey,
      jsonEncode(<String, dynamic>{
        'jobId': id,
        'sourceInputText': sourceInputText,
        'status': status,
        'stage': stage,
        'progress': progress,
        'startedAt': startedAt?.toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
        if (isDetached) 'watchdog': 'detached',
        // Permintaan batal yang belum dikonfirmasi server harus survive reload,
        // kalau tidak UI kembali mengklaim job normal setelah halaman dibuka.
        if (cancelRequested) 'cancelRequested': true,
      }),
    );
  }

  void _notify() {
    notifyListeners();
  }

  /// Reset total — hanya untuk test (singleton hidup lintas test dalam satu file).
  Future<void> resetForTest() async {
    jobId = null;
    sourceInputText = '';
    status = 'idle';
    stage = '';
    progress = 0;
    startedAt = null;
    isDetached = false;
    detachedStage = false;
    cancelRequested = false;
    lastDeliveryJobId = null;
    lastDeliveryClips = const [];
    lastFailureMessage = null;
    onCompleted = null;
    onFailed = null;
    onCancelled = null;
    onDetached = null;
    onPolled = null;
    _polling = false;
    initialDelayMs = 1000;
    maxDelayMs = 3000;
    pollDeadline = const Duration(minutes: 30);
    ClipJobMap.resetCacheForTest();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
    await prefs.remove(lastBatchKey);
  }
}

/// Re-attach polling render yang tertinggal (secondary bug #3).
///
/// Render klip di-antrekan ke server lalu di-poll oleh UI yang memanggil.
/// Bila halaman di-reload / tab ditutup saat status masih queued|rendering,
/// klip akan "membeku" di Merender... selamanya. Saat boot, klip semacam itu
/// diambil kembali dan di-poll per jobId (satu poller per job), lalu tiap klip
/// yang selesai dikirim ke [onUpdated].
class RenderResume {
  RenderResume._();

  static final Set<String> _claimed = <String>{};
  static int pollDelayMs = 1000;
  static int maxPollDelayMs = 3000;
  static Duration maxWait = const Duration(minutes: 30);

  /// Dipakai RenderActions agar poller foreground tidak dobel dengan yang ini.
  static bool claim(String jobId) => _claimed.add(jobId);

  static void release(String jobId) => _claimed.remove(jobId);

  static void resetForTest() => _claimed.clear();

  static bool isPending(ClipItem clip) =>
      clip.renderStatus == 'queued' || clip.renderStatus == 'rendering';

  static Future<void> outstanding({
    required Iterable<ClipItem> clips,
    required void Function(ClipItem updated) onUpdated,
    void Function(String message)? onMessage,
  }) async {
    final pending = clips.where(isPending).toList();
    if (pending.isEmpty) return;

    final jobMap = await ClipJobMap.load();
    final byJob = <String, Set<String>>{};
    for (final clip in pending) {
      final jobId = jobMap[clip.id]?.jobId;
      if (jobId == null || jobId.isEmpty) continue;
      (byJob[jobId] ??= <String>{}).add(clip.id);
    }
    if (byJob.isEmpty) return;

    final wanted = <String, ClipItem>{
      for (final c in pending) c.id: c,
    };

    await Future.wait(byJob.entries.map((entry) async {
      final jobId = entry.key;
      if (!claim(jobId)) return; // sudah ada poller untuk job ini
      try {
        await _pollJob(jobId, entry.value, wanted, onUpdated, onMessage);
      } finally {
        release(jobId);
      }
    }));
  }

  /// Semua jalur keluar loop WAJIB menyelesaikan klip yang masih tertunda.
  /// Kalau tidak, katalog membeku di "Merender..." selamanya padahal poller
  /// sudah mati (bug "stuck Merender"). [breakReason] diisi sesuai penyebab:
  /// error berturut-turut / exception / job gagal di server / deadline habis.
  static const String reasonServerIncomplete = 'Server tidak menyelesaikan render';
  static const String reasonJobCancelled = 'Job dibatalkan server';
  static const String reasonDeadline = reasonServerIncomplete;

  static Future<void> _pollJob(
    String jobId,
    Set<String> targetIds,
    Map<String, ClipItem> wanted,
    void Function(ClipItem updated) onUpdated,
    void Function(String message)? onMessage,
  ) async {
    final api = ApiService.shared;
    final deadline = DateTime.now().add(maxWait);
    final remaining = Set<String>.from(targetIds);
    final skipped = <String>[];
    var settled = 0;
    var failed = 0;
    var delayMs = pollDelayMs;
    var consecutiveErrors = 0;
    String? breakReason;

    while (remaining.isNotEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      JobStatus job;
      try {
        job = await api.pollJob(jobId);
        consecutiveErrors = 0;
      } on ApiError {
        consecutiveErrors++;
        if (consecutiveErrors >= 3) {
          breakReason = reasonServerIncomplete;
          break;
        }
        delayMs = (delayMs + 500).clamp(pollDelayMs, maxPollDelayMs);
        continue;
      } catch (_) {
        breakReason = reasonServerIncomplete;
        break;
      }

      for (final clip in job.clips) {
        if (!remaining.contains(clip.id)) continue;
        if (!isPending(clip) && clip.renderStatus != 'none') {
          remaining.remove(clip.id);
          final base = wanted[clip.id] ?? clip;
          final updated = base.copyWith(
            renderStatus: clip.renderStatus,
            isRendered: clip.renderStatus == 'done',
            videoUrl: clip.videoUrl,
            thumbnailUrl: clip.thumbnailUrl,
            renderIndex: clip.renderIndex,
            renderable: clip.renderable,
            reason: clip.reason,
          );
          if (clip.renderStatus == 'done') {
            settled++;
          } else {
            failed++;
          }
          onUpdated(updated);
        }
      }
      if (job.status == 'failed') {
        breakReason = reasonServerIncomplete;
        break;
      }
      if (job.status == 'cancelled') {
        // Job dibatalkan server/user: klip yang masih antre tidak akan pernah
        // selesai — akhiri dengan alasan jujur, bukan 'Merender...' abadi.
        breakReason = reasonJobCancelled;
        break;
      }
      if (job.status == 'done') {
        // Server selesai tapi masih ada klip target yang belum berubah status:
        // job tidak akan pernah mengirim kabar lagi untuk mereka.
        breakReason = reasonServerIncomplete;
        break;
      }
      delayMs = ((delayMs * 1.5).round()).clamp(pollDelayMs, maxPollDelayMs);
    }

    if (remaining.isNotEmpty) {
      breakReason ??= reasonServerIncomplete;
      for (final id in remaining) {
        final base = wanted[id];
        if (base == null) continue;
        skipped.add(base.hook);
        failed++;
        onUpdated(base.copyWith(
          renderStatus: 'failed',
          isRendered: false,
          reason: breakReason,
        ));
      }
    }

    if (settled > 0 || failed > 0) {
      onMessage?.call(
        'Status render selesai di latar: $settled berhasil'
        '${failed > 0 ? ', $failed gagal' : ''}.',
      );
    }
  }
}

/// Strip markup highlight hook agar tidak tampil sebagai karakter literal di
/// kanvas simulasi preview. Semantik mengikuti `parse_hook_tokens` di
/// overlay_renderer.py: `*KATA*` dan `[KATA]` → highlight, marker dibuang,
/// katanya tetap.
///
/// Pakai replaceAllMapped, BUKAN replaceAll(r'$1'): di Dart versi ini
/// `replaceAll` dengan pola `$1` TIDAK melakukan substitusi grup (hasilnya
/// literal "$1" — sudah diverifikasi langsung), sehingga capture group harus
/// diambil eksplisit dari Match.
String stripHookMarkup(String text) {
  final starred = RegExp(r'\*([^*]+)\*');
  final bracketed = RegExp(r'\[([^\]]+)\]');
  return text
      .replaceAllMapped(starred, (m) => m.group(1) ?? '')
      .replaceAllMapped(bracketed, (m) => m.group(1) ?? '')
      .replaceAll(RegExp(r'[\[\]"]'), '');
}
