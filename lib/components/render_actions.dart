import 'package:flutter/material.dart';

import '../models/clip_item.dart';
import '../services/api_service.dart';
import '../services/job_tracker.dart';
import '../theme/app_theme.dart';
import 'pill_tag.dart';

enum RenderStatusKind { noJob, cancelled, queued, done, failed, skipped }

class RenderOutcome {
  final RenderStatusKind kind;
  final String message;
  final ClipItem? updated;

  RenderOutcome(this.kind, this.message, {this.updated});
}

/// Alur render nyata ke server: cek jobId → gerbang compliance →
/// antrekan render → poll sampai renderStatus done/failed.
class RenderActions {
  /// Klip bawaan (contoh UI) tidak pernah punya job di server, jadi render
  /// harus ditolak dengan pesan jujur SEBELUM memanggil API.
  static bool isSampleClip(ClipItem clip) => clip.id.startsWith('sample_');

  static const String sampleClipMessage =
      'Klip contoh tidak bisa dirender — buat klip dari Studio.';

  /// Klip masih butuh konfirmasi manusia sebelum dirender.
  static bool needsComplianceGate(ClipItem clip) {
    return clip.riskFlags.isNotEmpty ||
        clip.complianceStatus == 'REVIEW' ||
        (clip.campaignNotes.isNotEmpty && clip.complianceStatus != 'COMPLIANT');
  }

  /// Klip tanpa video sumber (type topic/test) tidak punya apa pun untuk
  /// dirender — tombol harus disabled dengan label jujur, bukan error server.
  static bool isNonRenderable(ClipItem clip) => !clip.renderable;

  static const String nonRenderableTooltip =
      'Klip konseptual tanpa video sumber — tidak ada yang bisa dirender.';

  /// 400 dari gerbang job server (mis. seluruh isi job non-renderable →
  /// job-gate) tidak boleh tampil mentah. Sisi klien sudah menyaring klip
  /// non-renderable; sisa 400 = kabar server yang butuh terjemahan ramah.
  static String friendlyRenderError(ApiError e) {
    if (e.statusCode == 400) {
      return 'Server menolak render (400): ${e.message}\n'
          'Kemungkinan sumber klip ini bukan video (ide/topik) — hanya klip '
          'dengan video sumber yang bisa dirender.';
    }
    return e.message;
  }

  static Future<String?> jobIdFor(ClipItem clip) => ClipJobMap.jobIdFor(clip.id);

  /// Dialog gerbang compliance (mencerminkan gate di bot Telegram).
  /// Mengembalikan true bila user memilih lanjut render ("Render Paksa").
  static Future<bool> confirmCompliance(
    BuildContext context,
    ClipItem clip,
    bool isDark, {
    int batchCount = 1,
  }) async {
    final flags = <String>[
      ...clip.riskFlags,
      if (clip.complianceStatus == 'REVIEW') 'Status: REVIEW (butuh pemeriksaan manusia)',
    ];
    // Nada gate SAMA dengan badge katalog (item 1): REVIEW → oranye alarm,
    // NONE/netral → ikon abu. Gerbang ini hanya muncul bila ada flag nyata,
    // jadi status COMPLIANT yang ikut terseret memakai nada netral.
    final spec = complianceBadgeSpec(clip.complianceStatus)!;
    final gateTone = spec.color == Colors.transparent
        ? (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)
        : spec.color;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
        title: Row(
          children: [
            Icon(
              clip.complianceStatus == 'REVIEW' || clip.riskFlags.isNotEmpty
                  ? Icons.warning_amber_rounded
                  : Icons.info_outline_rounded,
              color: gateTone,
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                batchCount > 1 ? 'KLIP BUTUH RESTU ($batchCount)' : 'KLIP BUTUH RESTU',
                style: TextStyle(
                  fontFamily: AppTypography.fontFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Server menandai klip ini dengan catatan risiko/kepatuhan. Render tetap bisa dipaksa, tapi baca dulu catatannya:',
                style: AppTypography.body(isDark),
              ),
              const SizedBox(height: 12),
              ...flags.take(6).map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '• ',
                            style: TextStyle(
                              fontFamily: AppTypography.fontFamily,
                              fontSize: 12,
                              color: isDark ? Colors.white70 : Colors.black87,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              f,
                              style: TextStyle(
                                fontFamily: AppTypography.fontFamily,
                                fontSize: 11.5,
                                height: 1.4,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              if (clip.complianceNote.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                // TODO(E9): tampilkan catatan campaign terstruktur dari server.
                Text(
                  'Catatan server: ${clip.complianceNote}',
                  style: TextStyle(
                    fontFamily: AppTypography.fontFamily,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    height: 1.45,
                    color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Batal', style: TextStyle(color: isDark ? Colors.white60 : Colors.black54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark ? Colors.white : Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              batchCount > 1 ? 'Render Paksa Semua' : 'Render Paksa',
              style: TextStyle(
                color: isDark ? Colors.black : Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// Render satu klip end-to-end. [onQueued] dipanggil begitu server menerima antrean.
  static Future<RenderOutcome> renderSingleClip(
    BuildContext context,
    ClipItem clip,
    bool isDark, {
    void Function()? onQueued,
  }) async {
    if (isSampleClip(clip)) {
      return RenderOutcome(RenderStatusKind.noJob, sampleClipMessage);
    }
    if (isNonRenderable(clip)) {
      return RenderOutcome(RenderStatusKind.noJob, nonRenderableTooltip);
    }

    final api = ApiService.shared;
    final jobId = await jobIdFor(clip);
    if (jobId == null || jobId.isEmpty) {
      return RenderOutcome(
        RenderStatusKind.noJob,
        'Klip ini tidak punya job di server. Jalankan kurasi ulang di Studio untuk render nyata.',
      );
    }

    // User sudah menyetujui lewat gerbang → render PAKSA (force) agar server
    // tidak melewati klip ini diam-diam.
    var force = false;
    if (needsComplianceGate(clip)) {
      if (!context.mounted) {
        return RenderOutcome(RenderStatusKind.cancelled, 'Layar ditutup sebelum render dimulai.');
      }
      final go = await confirmCompliance(context, clip, isDark);
      if (!go) return RenderOutcome(RenderStatusKind.cancelled, 'Render dibatalkan.');
      force = true;
    }

    final index = clipIndexOf(clip);
    try {
      await api.renderClip(jobId, index, force: force);
    } on ApiError catch (e) {
      return RenderOutcome(RenderStatusKind.failed, friendlyRenderError(e));
    }

    onQueued?.call();

    // Cegah resume-render latar (RenderResume) membuat poller ganda untuk job
    // yang sama selama poll foreground ini aktif.
    final claimed = RenderResume.claim(jobId);
    final JobStatus job;
    try {
      job = await waitForRenders(api, jobId, clipIds: {clip.id});
    } finally {
      if (claimed) RenderResume.release(jobId);
    }
    final matches = job.clips.where((c) => c.id == clip.id).toList();
    if (matches.isEmpty) {
      return RenderOutcome(
        RenderStatusKind.failed,
        RenderResume.reasonServerIncomplete,
        updated: clip.copyWith(
          renderStatus: 'failed',
          isRendered: false,
          reason: RenderResume.reasonServerIncomplete,
        ),
      );
    }
    final updated = matches.first;
    if (updated.renderStatus == 'done') {
      updated.isRendered = true;
      return RenderOutcome(RenderStatusKind.done, 'Render selesai.', updated: updated);
    }
    if (updated.renderStatus == 'queued' || updated.renderStatus == 'rendering') {
      // Batas waktu habis tapi server masih mengaku antre: jangan tinggalkan
      // "Merender..." selamanya — tandai gagal dengan alasan jujur.
      return RenderOutcome(
        RenderStatusKind.failed,
        RenderResume.reasonServerIncomplete,
        updated: clip.copyWith(
          renderStatus: 'failed',
          isRendered: false,
          reason: RenderResume.reasonServerIncomplete,
        ),
      );
    }
    return RenderOutcome(
      RenderStatusKind.failed,
      updated.reason.trim().isNotEmpty ? updated.reason : 'Render gagal di server.',
      updated: updated,
    );
  }

  /// Render massal: kelompokkan klip per jobId, panggil /render-all, lalu poll.
  ///
  /// [onQueued] sekarang dipanggil PER JOB dengan daftar klip milik job itu
  /// saja — sebelumnya shell menandai SEMUA klip pending sebagai queued,
  /// sehingga klip dari job lain ikut membeku di "Merender...".
  /// [onSettled] dipanggil SEGERA saat satu klip selesai/gagal (bukan di end),
  /// supaya katalog menampilkan progres per klip, bukan satu lonjakan terakhir.
  static Future<List<RenderOutcome>> renderAllInJob(
    BuildContext context,
    List<ClipItem> clips,
    bool isDark, {
    void Function(List<ClipItem> queuedClips)? onQueued,
    void Function(ClipItem updated)? onSettled,
  }) async {
    final api = ApiService.shared;

    // Kelompokkan klip berdasarkan jobId server.
    final jobs = <String, List<ClipItem>>{};
    final orphans = <ClipItem>[];
    final samples = <ClipItem>[];
    final conceptual = <ClipItem>[];
    for (final clip in clips) {
      if (isSampleClip(clip)) {
        samples.add(clip);
        continue;
      }
      if (isNonRenderable(clip)) {
        conceptual.add(clip);
        continue;
      }
      final jobId = await jobIdFor(clip);
      if (jobId == null || jobId.isEmpty) {
        orphans.add(clip);
      } else {
        (jobs[jobId] ??= <ClipItem>[]).add(clip);
      }
    }

    final outcomes = <RenderOutcome>[];
    if (samples.isNotEmpty) {
      outcomes.add(RenderOutcome(
        RenderStatusKind.noJob,
        '${samples.length} klip contoh dilewati: $sampleClipMessage',
      ));
    }
    if (conceptual.isNotEmpty) {
      outcomes.add(RenderOutcome(
        RenderStatusKind.noJob,
        '${conceptual.length} klip tanpa video dilewati: $nonRenderableTooltip',
      ));
    }
    if (orphans.isNotEmpty) {
      outcomes.add(RenderOutcome(
        RenderStatusKind.noJob,
        '${orphans.length} klip lama tidak terhubung ke job server (butuh kurasi ulang).',
      ));
    }

    for (final entry in jobs.entries) {
      final jobId = entry.key;
      final targets = entry.value;
      final flagged = targets.where(needsComplianceGate).toList();
      var force = false;
      if (flagged.isNotEmpty) {
        if (!context.mounted) {
          outcomes.add(RenderOutcome(RenderStatusKind.cancelled, 'Layar ditutup sebelum render dimulai.'));
          break;
        }
        final go = await confirmCompliance(context, flagged.first, isDark, batchCount: flagged.length);
        if (!go) {
          outcomes.add(RenderOutcome(RenderStatusKind.cancelled, 'Batch render dibatalkan.'));
          continue;
        }
        // "Render Paksa Semua" harus benar-benar memaksa (v1.1: body {"force":true}).
        force = true;
      }

      RenderAllResult result;
      try {
        result = await api.renderAll(jobId, force: force);
      } on ApiError catch (e) {
        // Server v1.1: job yang SELURUHNYA non-renderable dibalas 400 job-gate
        // (bukan 200+skipped). Jangan tampilkan 400 mentah-mentah.
        outcomes.add(RenderOutcome(RenderStatusKind.failed, friendlyRenderError(e)));
        continue;
      }

      // Klip yang dilewati server: kembalikan status 'none' (JUJUR — tidak
      // pernah masuk antrean) dan laporkan agar UI memberi jalan keluar.
      final skippedIds = <String>{};
      if (result.skipped.isNotEmpty) {
        final byIndex = <int, ClipItem>{
          for (final c in targets) clipIndexOf(c): c,
        };
        for (final s in result.skipped) {
          final clip = byIndex[s.index];
          if (clip == null) continue;
          skippedIds.add(clip.id);
          outcomes.add(RenderOutcome(
            RenderStatusKind.skipped,
            s.reason.trim().isEmpty
                ? 'Klip "${clip.hook}" dilewati server (langgar aturan).'
                : 'Klip "${clip.hook}" dilewati: ${s.reason}',
            updated: clip.copyWith(renderStatus: 'none', isRendered: false),
          ));
        }
      }

      final queued = targets.where((c) => !skippedIds.contains(c.id)).toList();
      if (queued.isEmpty) continue;
      onQueued?.call(queued);

      final Set<String> queuedIds = queued.map((c) => c.id).toSet();
      final JobStatus job;
      final claimed = RenderResume.claim(jobId);
      final Set<String> settledIds = <String>{};
      // Dedup untuk update inkremental per tick — terpisah dari settledIds
      // yang dipakai menyusun outcome akhir (kontrak pemanggil).
      final Set<String> announcedIds = <String>{};
      try {
        // onTick: setiap balasan poll, segera update klip yang sudah settle
        // (item 9) — katalog tidak menunggu seluruh batch selesai.
        job = await waitForRenders(
          api,
          jobId,
          clipIds: queuedIds,
          onTick: (latest) {
            for (final c in latest.clips) {
              if (!queuedIds.contains(c.id)) continue;
              final settled = c.renderStatus == 'done' || c.renderStatus == 'failed';
              if (settled) {
                if (announcedIds.add(c.id)) {
                  c.isRendered = c.renderStatus == 'done';
                  onSettled?.call(c);
                }
              } else if (c.renderStatus == 'queued' || c.renderStatus == 'rendering') {
                // Sinkronkan progres server → label "Merender..." ikut bergerak.
                final base = queued.firstWhere((q) => q.id == c.id);
                onSettled?.call(base.copyWith(renderStatus: c.renderStatus));
              }
            }
          },
        );
      } finally {
        if (claimed) RenderResume.release(jobId);
      }
      var settled = 0;
      for (final clip in queued) {
        final matches = job.clips.where((c) => c.id == clip.id).toList();
        if (matches.isEmpty) continue;
        final updated = matches.first;
        if (updated.renderStatus == 'done') {
          updated.isRendered = true;
          settled++;
          settledIds.add(clip.id);
          outcomes.add(RenderOutcome(RenderStatusKind.done, 'Render selesai.', updated: updated));
        } else if (updated.renderStatus == 'failed') {
          settled++;
          settledIds.add(clip.id);
          outcomes.add(RenderOutcome(RenderStatusKind.failed, 'Render gagal di server.', updated: updated));
        } else if (updated.renderStatus == 'queued' || updated.renderStatus == 'rendering') {
          // Batas waktu poll habis: jangan tinggalkan "Merender..." selamanya.
          settled++;
          settledIds.add(clip.id);
          outcomes.add(RenderOutcome(
            RenderStatusKind.failed,
            RenderResume.reasonServerIncomplete,
            updated: clip.copyWith(
              renderStatus: 'failed',
              isRendered: false,
              reason: RenderResume.reasonServerIncomplete,
            ),
          ));
        }
      }
      // Klip yang tidak pernah muncul di balasan server juga harus berhenti
      // berstatus queued — jujur gagal, bukan membeku.
      for (final clip in queued) {
        if (settledIds.contains(clip.id)) continue;
        outcomes.add(RenderOutcome(
          RenderStatusKind.failed,
          RenderResume.reasonServerIncomplete,
          updated: clip.copyWith(
            renderStatus: 'failed',
            isRendered: false,
            reason: RenderResume.reasonServerIncomplete,
          ),
        ));
      }
      if (settled == 0) {
        outcomes.add(RenderOutcome(RenderStatusKind.failed, 'Server tidak menyelesaikan render tepat waktu.'));
      }
    }

    if (outcomes.isEmpty) {
      outcomes.add(RenderOutcome(RenderStatusKind.failed, 'Tidak ada klip yang bisa dirender.'));
    }
    return outcomes;
  }

  /// Poll job (backoff 1s..3s) sampai semua klip target berstatus done/failed.
  /// [onTick] dipanggil setiap balasan sukses supaya UI dapat update per klip.
  static Future<JobStatus> waitForRenders(
    ApiService api,
    String jobId, {
    required Set<String> clipIds,
    Duration maxWait = const Duration(minutes: 10),
    void Function(JobStatus latest)? onTick,
  }) async {
    final deadline = DateTime.now().add(maxWait);
    int delayMs = 1000;
    int consecutiveErrors = 0;
    var last = JobStatus(jobId: jobId, status: 'running', stage: '', progress: 0, clips: const []);

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(Duration(milliseconds: delayMs));
      try {
        last = await api.pollJob(jobId);
        consecutiveErrors = 0;
      } on ApiError {
        consecutiveErrors++;
        if (consecutiveErrors >= 3) return last;
        delayMs = (delayMs + 500).clamp(1000, 3000);
        continue;
      }
      onTick?.call(last);
      if (clipIds.isEmpty) return last;
      final matched = last.clips.where((c) => clipIds.contains(c.id)).toList();
      final settled = matched.isNotEmpty &&
          matched.every((c) => c.renderStatus == 'done' || c.renderStatus == 'failed');
      if (settled) return last;
      if (last.status == 'failed' || last.status == 'cancelled') return last;
      delayMs = ((delayMs * 1.5).round()).clamp(1000, 3000);
    }
    return last;
  }
}

/// SnackBar konsisten untuk hasil render.
///
/// Warna ADAPTIF: di light theme snackbar gelap dengan teks terang, di dark
/// theme snackbar terang dengan teks gelap (bug lama: hardcoded hitam +
/// teks putih sehingga nyaris tak terbaca / menabrak tema).
void showRenderSnackBar(BuildContext context, String message, {bool isError = false}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final bg = isError ? AppColors.statusDanger : (isDark ? Colors.white : const Color(0xFF17171A));
  final fg = isError ? Colors.white : (isDark ? const Color(0xFF0A0A0A) : Colors.white);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: TextStyle(
          fontFamily: AppTypography.fontFamily,
          color: fg,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
      backgroundColor: bg,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(AppSpacing.lg),
    ),
  );
}
