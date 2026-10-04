import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../components/app_card.dart';
import '../components/circular_button.dart';
import '../components/clip_preview_dialog.dart';
import '../components/pill_tag.dart';
import '../components/primary_button.dart';
import '../components/render_actions.dart';
import '../models/clip_item.dart';
import '../services/api_service.dart';
import '../services/job_tracker.dart';
import '../theme/app_theme.dart';

class CatalogScreen extends StatefulWidget {
  final List<ClipItem> clips;
  final VoidCallback onToggleTheme;
  final bool isDarkMode;
  final Function(String id)? onDeleteClip;
  final Function(ClipItem updated)? onUpdateClip;
  final VoidCallback? onClearAll;
  final VoidCallback? onNavigateToStudio;

  const CatalogScreen({
    super.key,
    required this.clips,
    required this.onToggleTheme,
    required this.isDarkMode,
    this.onDeleteClip,
    this.onUpdateClip,
    this.onClearAll,
    this.onNavigateToStudio,
  });

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  String _selectedFilter = 'ALL';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _busyClipIds = {};

  /// Klip yang sudah diumumkan "antre" pada batch berjalan saat ini — mencegah
  /// snackbar "N klip antre" diulang untuk klip yang sama.
  final Set<String> _queuedAnnounced = <String>{};

  @override
  void initState() {
    super.initState();
    // Header perlu tahu kapan job kurasi aktif (tombol Batalkan) — tracker
    // adalah ChangeNotifier, jadi listened-builder cukup untuk badge kecil ini.
    JobTracker.instance.addListener(_onTrackerChanged);
  }

  @override
  void dispose() {
    JobTracker.instance.removeListener(_onTrackerChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onTrackerChanged() {
    if (mounted) setState(() {});
  }

  List<ClipItem> get _filteredClips {
    return widget.clips.where((c) {
      if (_selectedFilter == '95+') {
        if (c.score < 95) return false;
      } else if (_selectedFilter == 'RENDERED') {
        if (!c.isRendered) return false;
      } else if (_selectedFilter != 'ALL') {
        if (!c.preset.toUpperCase().contains(_selectedFilter)) return false;
      }

      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchHook = c.hook.toLowerCase().contains(q);
        final matchTopic = c.topic.toLowerCase().contains(q);
        final matchSource = c.sourceTitle.toLowerCase().contains(q);
        if (!matchHook && !matchTopic && !matchSource) return false;
      }

      return true;
    }).toList();
  }

  void _copyCaption(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Caption & Hashtags disalin ke clipboard! 📋',
          style: TextStyle(
            color: widget.isDarkMode ? Colors.black : Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
        backgroundColor: widget.isDarkMode ? Colors.white : Colors.black,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(AppSpacing.lg),
      ),
    );
  }

  void _editHookText(BuildContext context, ClipItem clip) {
    final hookCtrl = TextEditingController(text: clip.hook);
    showDialog(
      context: context,      builder: (ctx) => AlertDialog(
        backgroundColor: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
        title: Text(
          'Kustomisasi Teks Hook (/edithook)',
          style: TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Gunakan tanda *KATA* untuk memberi warna highlight menyala pada kata tersebut.',
              style: TextStyle(
                fontFamily: AppTypography.fontFamily,
                fontSize: 11,
                color: widget.isDarkMode ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: hookCtrl,
              maxLines: 2,
              style: TextStyle(
                fontFamily: AppTypography.fontFamily,
                fontSize: 13,
                color: widget.isDarkMode ? Colors.white : Colors.black,
              ),
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Batal',
              style: TextStyle(
                color: widget.isDarkMode ? Colors.white60 : Colors.black54,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.isDarkMode ? Colors.white : Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              final newHook = hookCtrl.text.trim();
              if (newHook.isNotEmpty) {
                final updated = clip.copyWith(hook: newHook);
                widget.onUpdateClip?.call(updated);
                Navigator.of(ctx).pop();
                HapticFeedback.lightImpact();
              }
            },
            child: Text(
              'Simpan',
              style: TextStyle(
                color: widget.isDarkMode ? Colors.black : Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    // Controller dialog hook dulu bocor — dibuang saat dialog ditutup.
    ).whenComplete(hookCtrl.dispose);
  }

  Future<void> _generateSingleClip(ClipItem clip) async {
    if (_busyClipIds.contains(clip.id)) return;
    setState(() => _busyClipIds.add(clip.id));

    final outcome = await RenderActions.renderSingleClip(
      context,
      clip,
      widget.isDarkMode,
      onQueued: () {
        widget.onUpdateClip?.call(clip.copyWith(renderStatus: 'queued'));
      },
    );

    if (!mounted) return;
    setState(() => _busyClipIds.remove(clip.id));

    switch (outcome.kind) {
      case RenderStatusKind.done:
        widget.onUpdateClip?.call(outcome.updated!);
        HapticFeedback.mediumImpact();
        showRenderSnackBar(
          context,
          'Klip "${clip.hook}" berhasil dirender server & siap diekspor! 🎬',
        );
        break;
      case RenderStatusKind.cancelled:
        break;
      case RenderStatusKind.skipped:
        // Dilewati server (langgar aturan) → jujur 'none', bukan antrean palsu.
        if (outcome.updated != null) {
          widget.onUpdateClip?.call(outcome.updated!);
        } else {
          widget.onUpdateClip?.call(clip.copyWith(renderStatus: 'none'));
        }
        showRenderSnackBar(
          context,
          outcome.message,
          isError: true,
        );
        break;
      case RenderStatusKind.noJob:
      case RenderStatusKind.failed:
      case RenderStatusKind.queued:
        widget.onUpdateClip?.call(
          clip.copyWith(
            renderStatus: outcome.kind == RenderStatusKind.failed &&
                    outcome.updated != null
                ? outcome.updated!.renderStatus
                : 'none',
          ),
        );
        showRenderSnackBar(context, outcome.message, isError: true);
        break;
    }
  }

  Future<void> _generateAllClips() async {
    if (_busyClipIds.isNotEmpty) return;
    final allPending = widget.clips.where((c) => !c.isRendered).toList();
    if (allPending.isEmpty) {
      showRenderSnackBar(context, 'Semua klip sudah selesai dirender. ⚡');
      return;
    }

    // Klip contoh tidak punya job di server → jangan dikirim & jangan ditandai
    // "Merender..." (akan membeku selamanya).
    final pending = allPending.where((c) => !RenderActions.isSampleClip(c)).toList();
    final skippedSamples = allPending.length - pending.length;
    if (pending.isEmpty) {
      showRenderSnackBar(context, RenderActions.sampleClipMessage, isError: true);
      return;
    }

    setState(() => _busyClipIds.addAll(pending.map((c) => c.id)));
    final outcomes = await RenderActions.renderAllInJob(
      context,
      pending,
      widget.isDarkMode,
      // BUG LAMA: shell menandai SEMUA klip pending sebagai queued, sehingga
      // klip dari job lain ikut membeku di "Merender...". Sekarang hanya klip
      // milik job yang baru saja di-antre yang berubah status.
      onQueued: (queuedClips) {
        final fresh = queuedClips.where((c) => !_queuedAnnounced.contains(c.id));
        for (final c in queuedClips) {
          widget.onUpdateClip?.call(c.copyWith(renderStatus: 'queued'));
          _queuedAnnounced.add(c.id);
        }
        if (fresh.isNotEmpty) {
          // Jujur: baru ANTRE, bukan selesai.
          showRenderSnackBar(context, '${fresh.length} klip antre di server.');
        }
      },
      // Progres per klip: update katalog begitu satu klip settle (done/failed),
      // bukan hanya di akhir batch.
      onSettled: (updated) {
        widget.onUpdateClip?.call(updated);
      },
    );
    if (!mounted) return;
    setState(() => _busyClipIds.clear());
    _queuedAnnounced.clear();

    var done = 0;
    String? lastError;
    if (skippedSamples > 0) {
      lastError = '$skippedSamples klip contoh dilewati (tidak bisa dirender).';
    }
    for (final o in outcomes) {
      if (o.kind == RenderStatusKind.done && o.updated != null) {
        done++;
        widget.onUpdateClip?.call(o.updated!);
      } else if (o.kind != RenderStatusKind.done) {
        if (o.updated != null) widget.onUpdateClip?.call(o.updated!);
        lastError = o.message;
      }
    }

    if (done > 0) {
      HapticFeedback.heavyImpact();
      showRenderSnackBar(
        context,
        '$done klip berhasil dirender server!'
        '${lastError == null ? ' ⚡' : ' • $lastError'}',
      );
    } else if (lastError != null) {
      showRenderSnackBar(context, lastError, isError: true);
    }
  }

  /// Batalkan job kurasi aktif dari header katalog (item 14). Optimistis:
  /// State TIDAK dibuang di sini — JobTracker menunggu konfirmasi server.
  Future<void> _cancelActiveJob() async {
    final tracker = JobTracker.instance;
    if (!tracker.isBusy) return;
    setState(() => _cancelling = true);
    final error = await tracker.requestCancel();
    if (!mounted) return;
    setState(() => _cancelling = false);
    showRenderSnackBar(
      context,
      error ?? 'Membatalkan job — menunggu konfirmasi server...',
      isError: error != null,
    );
  }

  bool _cancelling = false;

  Future<void> _downloadVideo(ClipItem clip) async {
    final url = clip.videoUrl;
    if (url == null || url.isEmpty) {
      showRenderSnackBar(context, 'Klip belum dirender — belum ada yang bisa diunduh.', isError: true);
      return;
    }
    final ok = await launchUrl(
      Uri.parse(ApiService.shared.config.downloadUrl(url)),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      showRenderSnackBar(context, 'Browser menolak membuka tautan unduhan.', isError: true);
    }
  }

  void _confirmDelete(BuildContext context, ClipItem clip) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
        title: Text(
          'Hapus Klip ini?',
          style: TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
          ),
        ),
        content: Text(
          'Klip "${clip.hook}" akan dihapus dari katalog.',
          style: AppTypography.body(widget.isDarkMode),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Batal', style: TextStyle(color: widget.isDarkMode ? Colors.white60 : Colors.black54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.statusDanger,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              widget.onDeleteClip?.call(clip.id);
            },
            child: const Text('Hapus', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _confirmClearAll(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
        title: Text(
          'Kosongkan Seluruh Katalog?',
          style: TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
          ),
        ),
        content: Text(
          'Semua ${widget.clips.length} klip tersimpan akan dibersihkan.',
          style: AppTypography.body(widget.isDarkMode),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Batal', style: TextStyle(color: widget.isDarkMode ? Colors.white60 : Colors.black54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.statusDanger,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              widget.onClearAll?.call();
            },
            child: const Text('Kosongkan', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final displayClips = _filteredClips;

    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xxl,
            vertical: AppSpacing.xl,
          ),
          children: [
            // Top Bar
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PillTag(
                      label: '${widget.clips.length} PILIHAN KLIP AKTIF',
                      variant: PillTagVariant.outline,
                    ),
                    // Item 14: batch header — job kurasi aktif bisa dibatalkan
                    // dari katalog tanpa kembali ke Studio. Compact: TextButton
                    // (PrimaryTactileButton ber-lebar infinity akan meledak di
                    // dalam Row(min) milik Wrap — bug layout ditemukan test).
                    if (JobTracker.instance.isBusy) ...[
                      const SizedBox(width: 4),
                      TextButton.icon(
                        key: const ValueKey('catalog_cancel_job'),
                        onPressed: _cancelling ? null : _cancelActiveJob,
                        icon: Icon(
                          _cancelling ? Icons.hourglass_empty : Icons.cancel_outlined,
                          size: 15,
                        ),
                        label: Text(
                          _cancelling ? 'Membatalkan...' : 'Batalkan',
                          style: TextStyle(
                            fontFamily: AppTypography.fontFamily,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: isDark ? Colors.white70 : Colors.black54,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        ),
                      ),
                    ],
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.clips.isNotEmpty)
                      CircularIconButton(
                        icon: Icons.delete_sweep_outlined,
                        tooltip: 'Kosongkan Katalog',
                        onPressed: () => _confirmClearAll(context),
                      ),
                    const SizedBox(width: AppSpacing.sm),
                    CircularIconButton(
                      icon: isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                      tooltip: 'Ganti Tema',
                      onPressed: widget.onToggleTheme,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xxl),

            // Editorial Title
            Text(
              'Curated\nLibrary',
              style: AppTypography.displayHero(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Katalog kurasi momen viral — pilih klip mana saja yang ingin digenerate atau tonton preview.',
              style: AppTypography.body(isDark),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Action: Generate All Clips Button (Matching Telegram Bot run_generate_all_flow)
            if (widget.clips.isNotEmpty) ...[
              PrimaryTactileButton(
                label: 'Batch Generate Semua Klip',
                icon: Icons.bolt_rounded,
                height: 46,
                onPressed: () => _generateAllClips(),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],

            // Search bar
            if (widget.clips.isNotEmpty) ...[
              Container(
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  border: Border.all(
                    color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                    width: 0.8,
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        onChanged: (val) => setState(() => _searchQuery = val.trim()),
                        style: TextStyle(
                          fontFamily: AppTypography.fontFamily,
                          fontSize: 12,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Cari hook, topik, atau kata kunci...',
                          hintStyle: TextStyle(
                            fontFamily: AppTypography.fontFamily,
                            fontSize: 12,
                            color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.3),
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    if (_searchQuery.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                        child: Icon(Icons.cancel_rounded, size: 16, color: isDark ? Colors.white38 : Colors.black38),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // Filter Pills Row
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildFilterChip('ALL', 'Semua (${widget.clips.length})', isDark),
                    _buildFilterChip('95+', 'Viral 95+', isDark),
                    _buildFilterChip('RENDERED', 'Sudah Render', isDark),
                    _buildFilterChip('HORMOZI', 'Hormozi', isDark),
                    _buildFilterChip('CAPCUT', 'CapCut', isDark),
                    _buildFilterChip('CINEMATIC', 'Cinematic', isDark),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
            ],

            // Content List or Empty State
            if (widget.clips.isEmpty) ...[
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl, vertical: 48),
                child: Column(
                  children: [
                    Icon(
                      Icons.movie_creation_outlined,
                      size: 40,
                      color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      'BELUM ADA KLIP AKTIF',
                      style: AppTypography.microHeader(isDark),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Kirim link YouTube, Google Drive, atau upload video di tab Studio untuk memproses.',
                      style: AppTypography.body(isDark),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    if (widget.onNavigateToStudio != null)
                      PrimaryTactileButton(
                        label: 'Buka Studio Sekarang',
                        icon: Icons.arrow_forward_rounded,
                        onPressed: widget.onNavigateToStudio,
                      ),
                  ],
                ),
              ),
            ] else if (displayClips.isEmpty) ...[
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl, vertical: 36),
                child: Column(
                  children: [
                    Icon(
                      Icons.filter_alt_off_outlined,
                      size: 32,
                      color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'TIDAK DITEMUKAN',
                      style: AppTypography.microHeader(isDark),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Tidak ada klip yang cocok dengan pencarian "$_searchQuery".',
                      style: AppTypography.body(isDark),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ] else ...[
              ...displayClips.map((clip) {
                return AppCard(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  margin: const EdgeInsets.only(bottom: AppSpacing.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Top Row: Viral Index Pill & Timecode & Render Badge
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PillTag(
                                label: 'VIRAL INDEX ${clip.score}/100',
                                variant: PillTagVariant.solid,
                              ),
                              const SizedBox(width: 6),
                              if (clip.isRendered)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppColors.statusActive.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: AppColors.statusActive, width: 0.8),
                                  ),
                                  child: const Text(
                                    'RENDERED',
                                    style: TextStyle(color: AppColors.statusActive, fontSize: 9, fontWeight: FontWeight.w800),
                                  ),
                                ),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.access_time_rounded, size: 12, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  '${clip.duration} • ${clip.timestamp}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: AppTypography.fontFamily,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Preset Tag & Source title & Compliance
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          PillTag(
                            label: clip.preset,
                            variant: PillTagVariant.outline,
                          ),
                          // COMPLIANT hijau, REVIEW amber, NONE → chip netral
                          // 'BEBAS' (bukan oranye: tidak ada temuan server).
                          ComplianceBadge(status: clip.complianceStatus),
                          if (!clip.renderable)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                'TANPA VIDEO',
                                style: TextStyle(
                                  color: isDark
                                      ? AppColors.darkTextSecondary
                                      : AppColors.lightTextSecondary,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 220),
                            child: Text(
                              clip.sourceTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: AppTypography.fontFamily,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Thumbnail 9:16 dari server (v1.1). Bila URL mati,
                      // errorBuilder jatuh ke layout teks seperti sebelumnya.
                      _buildThumbnail(clip, isDark),

                      // Hook Quotation (with /edithook action)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              '"${clip.hook}"',
                              style: TextStyle(
                                fontFamily: AppTypography.fontFamily,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                                color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                                height: 1.35,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 16),
                            tooltip: 'Edit Hook (/edithook)',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => _editHookText(context, clip),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        clip.topic.toUpperCase(),
                        style: AppTypography.microHeader(isDark),
                      ),
                      const SizedBox(height: AppSpacing.lg),

                      // Caption Preview Box
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
                          borderRadius: BorderRadius.circular(AppRadius.input),
                          border: Border.all(
                            color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                            width: 0.8,
                          ),
                        ),
                        child: Text(
                          clip.caption,
                          style: TextStyle(
                            fontFamily: AppTypography.fontFamily,
                            fontSize: 12,
                            color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF3F3F46),
                            height: 1.45,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),

                      // Action Buttons Row: Generate / Render + Preview 9:16 + Copy + Delete
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Tooltip(
                              // Item 8: klip tanpa video sumber tidak bisa
                              // dirender — disabled dengan alasan jujur.
                              message: RenderActions.isNonRenderable(clip)
                                  ? RenderActions.nonRenderableTooltip
                                  : (clip.renderStatus == 'failed' &&
                                          clip.reason.trim().isNotEmpty
                                      ? clip.reason
                                      : 'Render 9:16 lewat server'),
                              child: PrimaryTactileButton(
                                key: ValueKey('catalog_render_${clip.id}'),
                                label: _renderButtonLabel(clip),
                                icon: clip.isRendered
                                    ? Icons.check_circle_rounded
                                    : Icons.movie_filter_outlined,
                                isSecondary: clip.isRendered,
                                height: 42,
                                fontSize: 10.5,
                                isLoading: _busyClipIds.contains(clip.id),
                                onPressed: RenderActions.isNonRenderable(clip)
                                    ? null
                                    : () => _generateSingleClip(clip),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            flex: 3,
                            child: PrimaryTactileButton(
                              label: 'Preview 9:16',
                              icon: Icons.play_arrow_rounded,
                              isSecondary: true,
                              height: 42,
                              fontSize: 10.5,
                              onPressed: () => ClipPreviewDialog.show(context, clip, isDark),
                            ),
                          ),
                          const SizedBox(width: 6),
                          CircularIconButton(
                            icon: Icons.copy_rounded,
                            tooltip: 'Salin Caption',
                            size: 38,
                            onPressed: () => _copyCaption(context, clip.caption),
                          ),
                          if ((clip.videoUrl ?? '').isNotEmpty) ...[
                            const SizedBox(width: 6),
                            CircularIconButton(
                              icon: Icons.download_rounded,
                              tooltip: 'Unduh Video',
                              size: 38,
                              onPressed: () => _downloadVideo(clip),
                            ),
                          ],
                          const SizedBox(width: 6),
                          CircularIconButton(
                            icon: Icons.delete_outline_rounded,
                            tooltip: 'Hapus Klip',
                            size: 38,
                            onPressed: () => _confirmDelete(context, clip),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }),
            ],
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }

  /// Slot thumbnail 9:16 (item 13). Hemat: hanya dirender bila server mengirim
  /// thumbnailUrl; tinggi kecil; kegagalan jaringan → placeholder teks sehingga
  /// kartu tetap seperti layout lama.
  /// Label jujur tombol render (item 10/11): status 'failed' karena server tak
  /// menjawab TIDAK boleh tampil sebagai "Merender..." abadi.
  String _renderButtonLabel(ClipItem clip) {
    if (!clip.renderable) return 'Tanpa Video';
    if (clip.isRendered) return 'Dirender ✓';
    final pending =
        _busyClipIds.contains(clip.id) || clip.renderStatus == 'queued' || clip.renderStatus == 'rendering';
    if (pending) return 'Merender...';
    if (clip.renderStatus == 'failed') {
      return clip.reason.contains(RenderResume.reasonServerIncomplete)
          ? 'Gagal — server tak menjawab'
          : 'Coba Render Lagi';
    }
    return 'Render Klip';
  }

  Widget _buildThumbnail(ClipItem clip, bool isDark) {
    final url = clip.thumbnailUrl;
    if (url == null || url.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 96,
          width: 54,
          child: Image.network(
            ApiService.shared.config.absolute(url),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Container(
              color: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
              child: Icon(
                Icons.movie_outlined,
                size: 20,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return Container(
                color: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip(String id, String label, bool isDark) {
    final isSelected = _selectedFilter == id;
    return GestureDetector(
      onTap: () {
        setState(() => _selectedFilter = id);
        HapticFeedback.selectionClick();
      },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? Colors.white : Colors.black)
              : (isDark ? AppColors.darkSurface : AppColors.lightSurface),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? (isDark ? Colors.white : Colors.black)
                : (isDark ? AppColors.darkBorder : AppColors.lightBorder),
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
            color: isSelected
                ? (isDark ? Colors.black : Colors.white)
                : (isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary),
          ),
        ),
      ),
    );
  }
}
