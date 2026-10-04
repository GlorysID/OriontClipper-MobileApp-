import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../components/app_card.dart';
import '../components/circular_button.dart';
import '../components/clip_preview_dialog.dart';
import '../components/pill_tag.dart';
import '../components/primary_button.dart';
import '../components/render_actions.dart';
import '../models/campaign_policy.dart';
import '../models/clip_item.dart';
import '../models/hook_style.dart';
import '../services/api_service.dart';
import '../services/job_tracker.dart';
import '../theme/app_theme.dart';

/// Studio sekarang murni VIEW dari [JobTracker]: tidak ada loop polling lokal
/// lagi, jadi progress tidak hilang saat pindah tab atau halaman di-reload.
class StudioScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final bool isDarkMode;
  final Function(int)? onNavigateToTab;

  /// Style terpilih di tab STYLE — dipakai sebagai sumber style{position,
  /// highlight_color} untuk job BERIKUTNYA (bukan prop mati lagi).
  final HookStyle? activeStyle;

  /// Katalog aktif, dipakai menampilkan klip batch terakhir saat tracker idle.
  final List<ClipItem>? savedClips;

  final Function(ClipItem updated)? onUpdateClip;

  /// Tab Studio sedang terlihat (dikelola shell lewat IndexedStack). Dipakai
  /// untuk menyegarkan health pill hanya saat layar ini benar-benar dibaca user.
  final bool isTabVisible;

  const StudioScreen({
    super.key,
    required this.onToggleTheme,
    required this.isDarkMode,
    this.onNavigateToTab,
    this.activeStyle,
    this.savedClips,
    this.onUpdateClip,
    this.isTabVisible = true,
  });

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  final TextEditingController _sourceController = TextEditingController();
  String _sourceType = 'youtube'; // 'youtube', 'gdrive', 'file', 'topic'

  /// Pilihan flood-control (v1.1 server menghormati keduanya). 0 = default
  /// server (durasi bebas mengikuti topik / semua momen emas).
  static const List<int> _durationChoices = <int>[0, 30, 60, 90, 120];
  static const List<int> _clipCountChoices = <int>[0, 1, 3, 5, 10];
  int _durationSeconds = 0; // 0 = Default server
  int _targetClipCount = 0; // 0 = Semua momen emas

  /// Hanya untuk fase PENGIRIMAN job (POST /v1/jobs/curation). Setelah jobId
  /// dapat, JobTracker yang pegang kendali — proses lanjut di latar.
  bool _isSubmitting = false;
  bool _serverOnline = false;

  /// Timer refresh health: hanya jalan saat server OFFLINE dan tab ini terlihat
  /// (item 9c). Dibuang di dispose.
  Timer? _healthTimer;

  // Campaign Policy
  bool _campaignCustom = false;
  String _campaignRules = '';

  String? _pickedFileName;
  PlatformFile? _pickedVideoFile;

  JobTracker get _tracker => JobTracker.instance;

  /// Batas unggah yang DIKETAHUI dari server (api_server v1.1 = 200 MB).
  /// Angka ini dipakai di pesan user-facing — jangan pernah menyebut batas
  /// yang tidak berlaku.
  static const int _maxUploadBytes = 200 * 1024 * 1024;

  /// Pesan guard ukuran (item 4). Sama untuk penolakan sebelum upload maupun
  /// kegagalan pembacaan byte di web (browser mati kehabisan memori).
  static const String _uploadTooLargeMessage =
      'File terlalu besar untuk diunggah (maks ~200 MB) — pakai link YouTube/Drive.';

  static String _tooLargeMessage([int? sizeBytes]) {
    final mb = sizeBytes == null ? '' : ' (${(sizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB)';
    return 'File terlalu besar untuk browser$mb — pakai sumber YouTube/Drive'
        ' atau server (batas unggah ${_maxUploadBytes ~/ (1024 * 1024)} MB).';
  }

  /// Label + teks bersih pintasan topik (tanpa emoji yang harus dipotong).
  /// Emoji (So/Sk + variation selector U+FE0F) dibuang dengan regex Unicode,
  /// bukan substring buta yang memotong 3 karakter pertama.
  static const List<String> _quickSamples = <String>[
    '🎙️ Podcast Sukses & Bisnis',
    '🤖 AI Tools & Coding 2026',
    '🧠 Mindset 1% Orang Sukses',
    '📈 Rahasia Algoritma TikTok',
  ];

  static final RegExp _leadingEmoji =
      RegExp(r'^[\p{So}\p{Sk}️‍]+\s*', unicode: true);

  /// Pintasan dipakai HANYA untuk mengisi kotak sumber. Mode topik kini
  /// berfungsi penuh di server v1.1, jadi tidak ada note-sheet dead-end lagi.
  static String _cleanSampleLabel(String sample) =>
      sample.replaceFirst(_leadingEmoji, '').trim();

  @override
  void initState() {
    super.initState();
    _tracker.addListener(_onTrackerChanged);
    _tracker.onPolled = _handleServerPolled;
    _loadStoredPreferences();
    _checkServerHealth();
    _syncHealthTimer();
  }

  @override
  void didUpdateWidget(covariant StudioScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isTabVisible != widget.isTabVisible) {
      // (b) Segarkan pill saat tab menjadi aktif; (c) nyalakan/matikan timer.
      if (widget.isTabVisible) _checkServerHealth();
      _syncHealthTimer();
    }
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _healthTimer = null;
    _tracker.removeListener(_onTrackerChanged);
    if (_tracker.onPolled == _handleServerPolled) _tracker.onPolled = null;
    _sourceController.dispose();
    super.dispose();
  }

  void _onTrackerChanged() {
    if (mounted) setState(() {});
  }

  /// (a) Tick polling yang SUKSES sudah membuktikan server hidup. Jangan
  /// kirim request health tambahan bila pill sudah ONLINE (boros); saat pill
  /// masih OFFLINE, baruan cek sungguhan supaya status tidak menebak.
  void _handleServerPolled() {
    if (!mounted) return;
    if (_serverOnline) return;
    _checkServerHealth();
  }

  /// (a) Setiap tick polling sukses = kesempatan murah untuk menyadari server
  /// sudah hidup/sudah kembali. Dipasang di shell sekaligus oleh _checkServerHealth.
  void _syncHealthTimer() {
    final shouldRun = widget.isTabVisible && !_serverOnline;
    if (shouldRun) {
      _healthTimer ??= Timer.periodic(
        const Duration(seconds: 30),
        (_) => _checkServerHealth(),
      );
    } else {
      _healthTimer?.cancel();
      _healthTimer = null;
    }
  }

  Future<void> _checkServerHealth() async {
    try {
      await ApiConfig.instance.ensureLoaded();
      await ApiService.shared.health();
      if (mounted) setState(() => _serverOnline = true);
    } catch (_) {
      if (mounted) setState(() => _serverOnline = false);
    } finally {
      if (mounted) _syncHealthTimer();
    }
  }

  Future<void> _loadStoredPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _campaignCustom = prefs.getBool('campaign_is_custom') ?? false;
      _campaignRules = prefs.getString('campaign_rules_text') ?? '';
    });
  }

  Future<void> _handlePaste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      final text = data.text!.trim();
      setState(() {
        _sourceController.text = text;
        if (text.contains('drive.google.com')) {
          _sourceType = 'gdrive';
        } else if (text.contains('youtube.com') || text.contains('youtu.be')) {
          _sourceType = 'youtube';
        }
      });
      HapticFeedback.lightImpact();
    }
  }

  Future<void> _pickVideoFile() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.video);
      if (files.isNotEmpty) {
        final file = files.first;
        // Guard jujur SEBELUM baca byte & SEBELUM menyentuh API (item 4):
        // file_picker 13 memberi ukuran lewat lengthSync() (native) tanpa I/O.
        // web tidak menyediakannya → null, dan baru diketahui saat
        // readAsBytes() gagal (ditangani _runGeneration).
        final knownSize = file.lengthSync();
        if (knownSize != null && knownSize > _maxUploadBytes) {
          _showToast(_uploadTooLargeMessage, isError: true);
          return;
        }
        setState(() {
          _pickedVideoFile = file;
          _pickedFileName = file.name;
          _sourceController.text = file.name;
          _sourceType = 'file';
        });
        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      _showToast('Gagal membuka file: $e', isError: true);
    }
  }

  void _showApiKeyModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        decoration: BoxDecoration(
          color: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(
            color: widget.isDarkMode ? AppColors.darkBorder : AppColors.lightBorder,
            width: 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_off_rounded, size: 24, color: AppColors.statusWarning),
                const SizedBox(width: 8),
                Text(
                  'SERVER BELUM TERHUBUNG',
                  style: TextStyle(
                    fontFamily: AppTypography.fontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Aplikasi ini mengkurasi klip lewat server Python OriontClipper (bukan koneksi Groq langsung). '
              'Pastikan server berjalan, lalu atur URL-nya di tab SERVER pada panel Engine.',
              style: AppTypography.body(widget.isDarkMode),
            ),
            const SizedBox(height: AppSpacing.xl),
            PrimaryTactileButton(
              label: 'Buka Tab Engine Sekarang',
              icon: Icons.tune_rounded,
              onPressed: () {
                Navigator.of(ctx).pop();
                widget.onNavigateToTab?.call(3); // Index 3 is ENGINE
              },
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }

  void _copyCaptionInStudio(String text) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    _showToast('Caption & Hashtags disalin ke clipboard! 📋');
  }

  /// Style yang dipakai untuk job BERIKUTNYA (diubah di tab STYLE / ENGINE).
  HookStyle get _style => widget.activeStyle ?? HookStyle.defaultStyle;

  /// Klip batch terakhir + seluruh katalog aktif (sumber tunggal: shell).
  List<ClipItem> get _displayClips => widget.savedClips ?? const <ClipItem>[];

  /// SECTION HASIL (item 12): bila tracker idle dan ada batch terakhir, tampilkan
  /// batch itu saja. Katalog penuh TIDAK pernah dirender di Studio — tanpa batch,
  /// user diarahkan ke Tab Katalog lewat baris link.
  List<ClipItem> get _resultClips {
    final batch = _tracker.lastDeliveryClips;
    return batch.isNotEmpty ? batch : const <ClipItem>[];
  }

  bool get _isShowingLastBatch => _resultClips.isNotEmpty;

  /// Pill 'SIAP PREVIEW 9:16' hanya jujur bila ada minimal satu klip yang
  /// memang punya video sumber (renderable). Batch murni ide/topik tidak
  /// pernah boleh mengklaim "siap preview" seperti klip hasil render.
  bool get _hasRenderableResults => _resultClips.any((c) => c.renderable);

  bool get _isBusy => _tracker.isBusy || _isSubmitting;

  Future<void> _renderSingleClipInStudio(ClipItem clip) async {
    HapticFeedback.mediumImpact();

    final outcome = await RenderActions.renderSingleClip(
      context,
      clip,
      widget.isDarkMode,
      onQueued: () => widget.onUpdateClip?.call(clip.copyWith(renderStatus: 'queued')),
    );

    if (!mounted) return;
    switch (outcome.kind) {
      case RenderStatusKind.done:
        if (outcome.updated != null) widget.onUpdateClip?.call(outcome.updated!);
        showRenderSnackBar(context, 'Video 9:16 "${clip.hook}" berhasil dirender server & siap diekspor! 🎬');
        break;
      case RenderStatusKind.cancelled:
        break;
      case RenderStatusKind.skipped:
        // Dilewati server (langgar aturan) → kembalikan 'none' apa adanya.
        widget.onUpdateClip?.call(
          outcome.updated ?? clip.copyWith(renderStatus: 'none'),
        );
        showRenderSnackBar(context, outcome.message, isError: true);
        break;
      case RenderStatusKind.noJob:
      case RenderStatusKind.failed:
      case RenderStatusKind.queued:
        widget.onUpdateClip?.call(
          outcome.kind == RenderStatusKind.failed && outcome.updated != null
              ? outcome.updated!
              : clip.copyWith(renderStatus: 'none'),
        );
        showRenderSnackBar(context, outcome.message, isError: true);
        break;
    }
  }

  void _onGenerateTapped() {
    final inputVal = _sourceController.text.trim();
    if (inputVal.isEmpty) {
      _showToast('Masukkan link YouTube, Google Drive, atau topik video.', isError: true);
      return;
    }
    if (_tracker.isBusy) {
      _showToast('Masih ada kurasi yang berjalan di latar — tunggu selesai dulu.', isError: true);
      return;
    }
    // Detached = server masih mengerjakan job yang sama. Menekan Generate lagi
    // berarti kurasi DUA KALI untuk sumber yang sama — tahan, suruh pantau.
    if (_tracker.isDetached) {
      _showToast(
        'Job #${_tracker.jobId} masih diproses server. Tekan "Pantau ulang" '
        'atau batalkan sebelum kurasi baru.',
        isError: true,
      );
      return;
    }
    _showCampaignSelectionSheet();
  }

  void _showCampaignSelectionSheet() {
    final rulesCtrl = TextEditingController(text: _campaignRules);
    bool isCustomLocal = _campaignCustom;
    // Salinan pilihan flood-control: baru disimpan ke state layar saat user
    // menekan tombol mulai (sheet boleh ditutup dengan X tanpa mengubah apa pun).
    int clipCountLocal = _targetClipCount;
    int durationLocal = _durationSeconds;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: EdgeInsets.only(
            left: AppSpacing.xxl,
            right: AppSpacing.xxl,
            top: AppSpacing.xxl,
            bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xxl,
          ),
          decoration: BoxDecoration(
            color: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(
              color: widget.isDarkMode ? AppColors.darkBorder : AppColors.lightBorder,
              width: 1,
            ),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    PillTag(
                      label: 'FLOW KURASI BOT TELEGRAM',
                      variant: PillTagVariant.status,
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'ATURAN KAMPANYE (/campaign)',
                  style: TextStyle(
                    fontFamily: AppTypography.fontFamily,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                    color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Tentukan apakah video ini terikat aturan campaign khusus atau dibebaskan (AI mencari konteks sesuka hati secara utuh):',
                  style: AppTypography.body(widget.isDarkMode),
                ),
                const SizedBox(height: AppSpacing.lg),

                // Option 1: Bebas (Tanpa Aturan Campaign)
                GestureDetector(
                  onTap: () {
                    setModalState(() => isCustomLocal = false);
                    HapticFeedback.selectionClick();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: !isCustomLocal
                          ? (widget.isDarkMode ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.05))
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: !isCustomLocal
                            ? (widget.isDarkMode ? Colors.white : Colors.black)
                            : (widget.isDarkMode ? AppColors.darkBorder : AppColors.lightBorder),
                        width: !isCustomLocal ? 1.5 : 0.8,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          !isCustomLocal ? Icons.radio_button_checked : Icons.radio_button_off,
                          size: 20,
                          color: widget.isDarkMode ? Colors.white : Colors.black,
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Bebas (Tanpa Aturan Campaign)',
                                style: TextStyle(
                                  fontFamily: AppTypography.fontFamily,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'AI OriontClipper bebas mencari & menalar konteks sesuka hati tanpa batasan rules, mengekstrak semua momen emas dengan pemikiran utuh tanpa terpotong di tengah jalan.',
                                style: TextStyle(
                                  fontFamily: AppTypography.fontFamily,
                                  fontSize: 11,
                                  color: widget.isDarkMode ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),

                // Option 2: Aturan Campaign Kustom
                GestureDetector(
                  onTap: () {
                    setModalState(() => isCustomLocal = true);
                    HapticFeedback.selectionClick();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: isCustomLocal
                          ? (widget.isDarkMode ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.05))
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isCustomLocal
                            ? (widget.isDarkMode ? Colors.white : Colors.black)
                            : (widget.isDarkMode ? AppColors.darkBorder : AppColors.lightBorder),
                        width: isCustomLocal ? 1.5 : 0.8,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          isCustomLocal ? Icons.radio_button_checked : Icons.radio_button_off,
                          size: 20,
                          color: widget.isDarkMode ? Colors.white : Colors.black,
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Isi Aturan Campaign Kustom',
                                style: TextStyle(
                                  fontFamily: AppTypography.fontFamily,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Tuliskan S&K sponsor/campaign jika video memiliki aturan tersendiri (larangan merk kompetitor, syarat CTA bio, target durasi/topik tertentu).',
                                style: TextStyle(
                                  fontFamily: AppTypography.fontFamily,
                                  fontSize: 11,
                                  color: widget.isDarkMode ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                if (isCustomLocal) ...[
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: rulesCtrl,
                    maxLines: 3,
                    style: TextStyle(
                      fontFamily: AppTypography.fontFamily,
                      fontSize: 12,
                      color: widget.isDarkMode ? Colors.white : Colors.black,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Contoh: Wajib fokus topik AI, dilarang sebut merk kompetitor, sertakan ajakan cek link di bio.',
                      hintStyle: TextStyle(
                        fontFamily: AppTypography.fontFamily,
                        fontSize: 11.5,
                        color: (widget.isDarkMode ? Colors.white : Colors.black).withValues(alpha: 0.35),
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
                ],

                // ── Pengendali banjir klip (server v1.1 menghormati keduanya) ──
                const SizedBox(height: AppSpacing.xl),
                Text(
                  'JUMLAH KLIP',
                  style: AppTypography.microHeader(widget.isDarkMode),
                ),
                const SizedBox(height: AppSpacing.xs),
                _buildChoiceChips(
                  values: _clipCountChoices,
                  selected: clipCountLocal,
                  labelFor: (v) => v == 0 ? 'Semua' : '$v',
                  onPick: (v) => setModalState(() => clipCountLocal = v),
                  isDark: widget.isDarkMode,
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'DURASI MAKS KLIP',
                  style: AppTypography.microHeader(widget.isDarkMode),
                ),
                const SizedBox(height: AppSpacing.xs),
                _buildChoiceChips(
                  values: _durationChoices,
                  selected: durationLocal,
                  labelFor: (v) => v == 0 ? 'Default' : '$v dtk',
                  onPick: (v) => setModalState(() => durationLocal = v),
                  isDark: widget.isDarkMode,
                ),

                const SizedBox(height: AppSpacing.xl),
                PrimaryTactileButton(
                  label: 'Mulai Kurasi & Render Klip 🚀',
                  icon: Icons.movie_creation_outlined,
                  onPressed: () {
                    final customVal = isCustomLocal;
                    final textVal = rulesCtrl.text.trim();
                    final clipVal = clipCountLocal;
                    final durVal = durationLocal;
                    // Pop DULU sebelum await: hindari pakai BuildContext lintas async gap.
                    Navigator.of(ctx).pop();
                    setState(() {
                      _campaignCustom = customVal;
                      _campaignRules = textVal;
                      _targetClipCount = clipVal;
                      _durationSeconds = durVal;
                    });
                    // Simpan kebijakan lalu sinkronkan ke server (fire-and-forget, gagal diam).
                    unawaited(
                      CampaignPolicy.save(customVal, textVal)
                          .then((_) => CampaignPolicy.push()),
                    );
                    _runGeneration();
                  },
                ),
                const SizedBox(height: AppSpacing.md),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(rulesCtrl.dispose);
  }

  /// Hanya mengirim job ke server lalu menyerahkannya ke [JobTracker].
  /// Tidak ada polling di sini — proses lanjut walaupun tab/reload berubah.
  Future<void> _runGeneration() async {
    final inputVal = _sourceController.text.trim();
    if (inputVal.isEmpty) {
      _showToast('Masukkan link YouTube, Google Drive, atau topik video.', isError: true);
      return;
    }
    if (_tracker.isBusy || _tracker.isDetached || _isSubmitting) return;

    setState(() => _isSubmitting = true);

    final api = ApiService.shared;
    // STYLE & HOOK TERPILIH — satu-satunya sumber style untuk request.
    // (Baris ini pernah di-hardcode 'hormozi'/'upper_center'/'#ffe600' dengan
    // komentar MUTATION-TEMP dari uji mutasi; itu bohong ke user & server.)
    final style = _style;
    // Ukuran teks topik divalidasi H-nya di server (8..400), tapi UI menahan
    // lebih awal dengan pesan yang dimengerti.
    if (_sourceType == 'topic' && (inputVal.length < 8 || inputVal.length > 400)) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showToast('Topik/ide harus 8-400 karakter agar server bisa mengkurasi.', isError: true);
      return;
    }

    try {
      await ApiConfig.instance.ensureLoaded();

      // Sumber file: unggah bytes sungguhan ke server -> file_id.
      String? fileId;
      String? url;
      if (_sourceType == 'file') {
        final picked = _pickedVideoFile;
        if (picked == null) {
          throw ApiError('Pilih file video terlebih dahulu lewat ikon folder.');
        }
        // Guard ukuran SEBELUM request (item 4). Di web, bytes hanya tersedia
        // setelah readAsBytes; kegagalan di sini biasanya = file terlalu besar
        // untuk memori browser, jadi pesannya harus jujur soal itu.
        final Uint8List bytes;
        try {
          bytes = await picked.readAsBytes();
        } on MissingPluginException {
          // web/desktop tanpa plugin pembaca byte: jangan bohong soal sebabnya.
          throw ApiError(_uploadTooLargeMessage);
        } catch (_) {
          throw ApiError(_uploadTooLargeMessage);
        }
        if (bytes.isEmpty) {
          throw ApiError('File kosong — tidak ada yang bisa diunggah.');
        }
        if (bytes.lengthInBytes > _maxUploadBytes) {
          throw ApiError(_tooLargeMessage(bytes.lengthInBytes));
        }
        final upload = await api.uploadFile(bytes, picked.name);
        if (upload.fileId.isEmpty) {
          throw ApiError('Server tidak menerima file (fileId kosong).');
        }
        fileId = upload.fileId;
      } else {
        // youtube, gdrive, dan TOPIK semuanya dikirim lewat field "url"
        // (kontrak v1.1: {type:"topic", url:"<teks 8..400>"} berfungsi penuh).
        url = inputVal;
      }

      final jobId = await api.createCurationJob(
        sourceType: _sourceType,
        url: url,
        fileId: fileId,
        durationSeconds: _durationSeconds,
        targetClipCount: _targetClipCount,
        templatePreset: style.preset,
        campaignActive: _campaignCustom,
        campaignRules: _campaignRules,
        position: style.position,
        highlightColor: style.highlightColor,
        preferredModel: ApiConfig.instance.preferredModel.isEmpty
            ? null
            : ApiConfig.instance.preferredModel,
      );

      if (!mounted) {
        // Studio sempat di-dispose: tetap serahkan job ke tracker global.
        await _tracker.start(jobId, sourceInput: inputVal);
        return;
      }
      setState(() => _isSubmitting = false);
      await _tracker.start(jobId, sourceInput: inputVal);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showToast('Gagal memproses: ${e.message}', isError: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      final cleanMsg = e.toString().replaceAll('Exception: ', '');
      _showToast('Gagal memproses: $cleanMsg', isError: true);
    }
  }

  void _showToast(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(
            color: isError ? Colors.white : (widget.isDarkMode ? Colors.black : Colors.white),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: isError
            ? AppColors.statusDanger
            : (widget.isDarkMode ? Colors.white : Colors.black),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(AppSpacing.lg),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final serverOnline = _serverOnline;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xxl,
          vertical: AppSpacing.xl,
        ),
        children: [
          // Top Navigation Bar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: GestureDetector(
                  onTap: () {
                    _checkServerHealth();
                    if (!serverOnline) _showApiKeyModal();
                  },
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: PillTag(
                      label: serverOnline ? 'SERVER • ONLINE' : 'SERVER • OFFLINE',
                      variant: PillTagVariant.status,
                      statusColor: serverOnline ? AppColors.statusActive : AppColors.statusWarning,
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  const SizedBox(width: AppSpacing.sm),
                  GestureDetector(
                    onTap: _showCampaignSelectionSheet,
                    child: PillTag(
                      label: _campaignCustom ? 'CAMPAIGN: ATURAN' : 'CAMPAIGN: BEBAS',
                      variant: PillTagVariant.outline,
                    ),
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

          // Editorial Hero Headline
          Text(
            'OriontClip\nStudio',
            style: AppTypography.displayHero(isDark),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Kurasi video panjang (YouTube, Google Drive, file lokal) menjadi klip vertikal 9:16 viral.',
            style: AppTypography.body(isDark),
          ),
          const SizedBox(height: AppSpacing.hero),

          // 1. Source Input Type Switcher (Matching Telegram Bot Inputs)
          Text(
            'JENIS SUMBER VIDEO (PROSES VIDEO)',
            style: AppTypography.microHeader(isDark),
          ),
          const SizedBox(height: AppSpacing.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildSourceTypeChip('youtube', 'YouTube URL', Icons.play_circle_outline_rounded, isDark),
                _buildSourceTypeChip('gdrive', 'Google Drive', Icons.cloud_outlined, isDark),
                _buildSourceTypeChip('file', 'Upload File', Icons.file_upload_outlined, isDark),
                _buildSourceTypeChip('topic', 'Topik / Ide', Icons.lightbulb_outline_rounded, isDark),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Input Box with Paste or File Pick button
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sourceController,
                    style: TextStyle(
                      fontFamily: AppTypography.fontFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: _getSourceHint(),
                      hintStyle: TextStyle(
                        fontFamily: AppTypography.fontFamily,
                        fontSize: 12.5,
                        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.3),
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (_sourceType == 'file')
                  CircularIconButton(
                    icon: Icons.folder_open_rounded,
                    tooltip: 'Pilih File Video',
                    size: 38,
                    onPressed: _pickVideoFile,
                  )
                else
                  CircularIconButton(
                    icon: Icons.content_paste_rounded,
                    tooltip: 'Tempel Link',
                    size: 38,
                    onPressed: _handlePaste,
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),

          // Pintasan topik: mengisi kotak sumber saja. Mode topik berfungsi
          // penuh di server v1.1 → tidak ada note-sheet "menunggu server" lagi.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _quickSamples.map((sample) {
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _sourceController.text = _cleanSampleLabel(sample);
                      _sourceType = 'topic';
                    });
                    HapticFeedback.lightImpact();
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      sample,
                      style: TextStyle(
                        fontFamily: AppTypography.fontFamily,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          if (_sourceType == 'topic') ...[
            const SizedBox(height: AppSpacing.sm),
            // Server v1.1 menerima mode topik sungguhan ({type:'topic',
            // url:<ide>}) — hasilnya klip konseptual. Jujur: tidak ada video
            // sumber, jadi klip ini tidak bisa dirender sampai sumbernya ada.
            Text(
              'Klip ide bersifat konseptual — tidak bisa dirender sampai sumber video.',
              style: TextStyle(
                fontFamily: AppTypography.fontFamily,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xxl),

          const SizedBox(height: AppSpacing.xxl),

          // Style & Hook Quick Link (Direct to Style Tab)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'STYLE & HOOK TERPILIH',
                style: AppTypography.microHeader(isDark),
              ),
              GestureDetector(
                onTap: () => widget.onNavigateToTab?.call(2), // Tab 2 is STYLE
                child: Text(
                  'Kustomisasi di Tab Style →',
                  style: TextStyle(
                    fontFamily: AppTypography.fontFamily,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            onTap: () => widget.onNavigateToTab?.call(2),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _style.preset == 'hormozi' ? const Color(0xFFFFE600) : Colors.white,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        HookStyle.presetNames[_style.preset] ?? 'Alex Hormozi (Bold & Yellow)',
                        style: TextStyle(
                          fontFamily: AppTypography.fontFamily,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Posisi: ${HookStyle.positionNames[_style.position]} • Highlight: ${HookStyle.colorNames[_style.highlightColor]}',
                        style: TextStyle(
                          fontFamily: AppTypography.fontFamily,
                          fontSize: 11,
                          color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios_rounded, size: 14),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),

          // 5. Processing Progress (dari JobTracker), Detached, atau Primary Button
          if (_tracker.isDetached) ...[
            _buildDetachedCard(isDark),
          ] else if (_isBusy) ...[
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _isSubmitting ? 0.05 : _tracker.progress,
                      backgroundColor: isDark ? Colors.white12 : Colors.black12,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        isDark ? Colors.white : Colors.black,
                      ),
                      minHeight: 3.5,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    _isSubmitting
                        ? 'Menghubungi server kurasi...'
                        : '${_tracker.progressLabel} (${_tracker.percentLabel}%)',
                    key: const ValueKey('studio_job_status'),
                    style: TextStyle(
                      fontFamily: AppTypography.fontFamily,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                      color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (!_isSubmitting) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _tracker.busyLabel,
                      style: TextStyle(
                        fontFamily: AppTypography.fontFamily,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    // Item 14: batalkan job aktif. Optimistis: UI menahan
                    // kartu sampai server mengonfirmasi (JobTracker._pollLoop).
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton.icon(
                          key: const ValueKey('studio_cancel_job'),
                          onPressed: _cancellingJob ? null : _cancelActiveJob,
                          icon: Icon(
                            _cancellingJob ? Icons.hourglass_empty_rounded : Icons.cancel_outlined,
                            size: 16,
                          ),
                          label: Text(
                            _cancellingJob ? 'Membatalkan...' : 'Batalkan',
                            style: TextStyle(
                              fontFamily: AppTypography.fontFamily,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            PrimaryTactileButton(
              label: _tracker.busyLabel,
              icon: Icons.hourglass_top_rounded,
              fontSize: 9.5,
              isLoading: true,
              onPressed: null,
            ),
          ] else ...[
            PrimaryTactileButton(
              label: 'Generate Viral Shorts',
              icon: Icons.arrow_forward_rounded,
              onPressed: _onGenerateTapped,
            ),
          ],

          // 6. HASIL RENDER KLIP VIRAL LANGSUNG DI STUDIO ("Hasil Render Nya Mana?")
          //     Studio menampilkan BATCH TERAKHIR saja (bukan seluruh katalog) —
          //     seluruh library tetap di Tab Katalog.
          if (_isShowingLastBatch) ...[
            const SizedBox(height: AppSpacing.xxl),
            Text(
              'BATCH TERAKHIR (Job #${_tracker.lastDeliveryJobId}) • ${_resultClips.length} KLIP',
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.xs),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Klip hasil kurasi terakhir dengan konteks utuh, naskah tuntas, & anti-potong di tengah jalan:',
                    style: TextStyle(
                      fontFamily: AppTypography.fontFamily,
                      fontSize: 11,
                      color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                    ),
                  ),
                ),
                // Jujur: pill "SIAP PREVIEW" hanya bila ada klip yang memang
                // sudah selesai dirender (bisa benar-benar diputar).
                if (_hasRenderableResults)
                  const PillTag(
                    label: 'SIAP PREVIEW 9:16',
                    variant: PillTagVariant.status,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            ..._resultClips.map((clip) => _buildStudioResultCard(isDark, clip)),
            const SizedBox(height: AppSpacing.sm),
            _buildCatalogLinkRow(isDark),
          ] else if (_displayClips.isNotEmpty) ...[
            // Tanpa batch tersimpan (mis. setelah reload sebelum id dipulihkan):
            // JANGAN render seluruh library di Studio — cukup satu baris link.
            const SizedBox(height: AppSpacing.xxl),
            _buildCatalogLinkRow(isDark),
          ],
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }

  Widget _buildCatalogLinkRow(bool isDark) {
    return Center(
      child: TextButton.icon(
        onPressed: () => widget.onNavigateToTab?.call(1), // Index 1 is Catalog
        icon: const Icon(Icons.collections_bookmark_outlined, size: 15),
        label: Text(
          'Buka & Kelola Semua Klip di Tab Katalog (${_displayClips.length}) →',
          style: TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
      ),
    );
  }
  /// Satu kartu hasil (dipakai untuk batch terakhir maupun fallback katalog).

  Widget _buildStudioResultCard(bool isDark, ClipItem clip) {
    final isPending = clip.renderStatus == 'queued' || clip.renderStatus == 'rendering';
    final renderLabel = !clip.renderable
        ? 'Tanpa video'
        : clip.isRendered
            ? 'Dirender ✓'
            : isPending
                ? 'Merender...'
                : clip.renderStatus == 'failed'
                    ? 'Coba Render Lagi'
                    : 'Render .mp4';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Row: Presets & Score
            Row(
              children: [
                PillTag(
                  label: clip.preset.toUpperCase(),
                  variant: PillTagVariant.outline,
                ),
                const SizedBox(width: 8),
                PillTag(
                  label: 'SKOR ${clip.score}',
                  variant: PillTagVariant.solid,
                ),
                const Spacer(),
                Text(
                  clip.duration,
                  style: TextStyle(
                    fontFamily: AppTypography.fontFamily,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),

            // Kepatuhan + status renderable (jujur, bukan oranye untuk NONE —
            // NONE = chip netral 'BEBAS', sama seperti kartu Katalog).
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                ComplianceBadge(status: clip.complianceStatus),
                if (!clip.renderable)
                  PillTag(
                    label: 'TANPA VIDEO',
                    variant: PillTagVariant.outline,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),

            // Hook Quotation
            Text(
              '"${clip.hook}"',
              style: TextStyle(
                fontFamily: AppTypography.fontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.2,
                color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              clip.topic.toUpperCase(),
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.md),

            // Script / Naskah Tuntas
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                  width: 0.8,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ALUR PEMIKIRAN & NASKAH TUNTAS:',
                    style: TextStyle(
                      fontFamily: AppTypography.fontFamily,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    clip.script.isNotEmpty ? clip.script : clip.hook,
                    style: TextStyle(
                      fontFamily: AppTypography.fontFamily,
                      fontSize: 11.5,
                      height: 1.45,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Action Buttons: Preview 9:16 + Render + Copy Caption
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: PrimaryTactileButton(
                    label: 'Preview 9:16',
                    icon: Icons.play_arrow_rounded,
                    height: 40,
                    fontSize: 10.5,
                    onPressed: () => ClipPreviewDialog.show(context, clip, isDark),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: Tooltip(
                    message: clip.renderable
                        ? (clip.renderStatus == 'failed' && clip.reason.isNotEmpty
                            ? clip.reason
                            : 'Render 9:16 lewat server')
                        : RenderActions.nonRenderableTooltip,
                    child: PrimaryTactileButton(
                      label: renderLabel,
                      icon: clip.isRendered
                          ? Icons.check_circle_rounded
                          : Icons.movie_filter_outlined,
                      isSecondary: true,
                      height: 40,
                      fontSize: 10.5,
                      isLoading: isPending,
                      // Klip konseptual (topic/test) tidak punya video: disabled
                      // + label jujur, bukan error server yang membingungkan.
                      onPressed: clip.renderable ? () => _renderSingleClipInStudio(clip) : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircularIconButton(
                  icon: Icons.copy_rounded,
                  tooltip: 'Salin Caption',
                  size: 40,
                  onPressed: () => _copyCaptionInStudio(clip.caption),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }


  /// Kartu jujur saat watchdog melepas pemantauan (item 8): server masih
  /// mengerjakan, Klien berhenti menunggu. Tidak ada klaim "gagal", tidak ada
  /// janji pollingBackground; satu tombol untuk menyambung pantauan.
  Widget _buildDetachedCard(bool isDark) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.hourglass_bottom_rounded, size: 20, color: AppColors.statusWarning),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  _tracker.progressLabel,
                  key: const ValueKey('studio_job_status'),
                  style: TextStyle(
                    fontFamily: AppTypography.fontFamily,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Proses tetap berjalan di server. Job (Job #${_tracker.jobId}) '
            'disimpan — tekan Pantau ulang untuk melihat hasilnya tanpa kurasi dua kali.',
            style: TextStyle(
              fontFamily: AppTypography.fontFamily,
              fontSize: 10.5,
              height: 1.45,
              color: isDark ? Colors.white60 : Colors.black54,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          PrimaryTactileButton(
            label: 'Pantau ulang',
            icon: Icons.refresh_rounded,
            height: 42,
            onPressed: _isResuming ? null : _resumeDetached,
          ),
        ],
      ),
    );
  }

  bool _isResuming = false;

  /// Item 14: "Batalkan" pada kartu progress. Permintaan dikirim, tapi state
  /// baru dibuang saat server mengonfirmasi — jadi tombol hanya menampilkan
  /// status, tidak berbohong "sudah dibatalkan".
  bool _cancellingJob = false;

  Future<void> _cancelActiveJob() async {
    HapticFeedback.mediumImpact();
    setState(() => _cancellingJob = true);
    final error = await _tracker.requestCancel();
    if (!mounted) return;
    setState(() => _cancellingJob = false);
    _showToast(
      error ?? 'Membatalkan job — menunggu konfirmasi server...',
      isError: error != null,
    );
  }

  Future<void> _resumeDetached() async {
    HapticFeedback.mediumImpact();
    setState(() => _isResuming = true);
    try {
      await _tracker.resumePolling();
    } finally {
      if (mounted) setState(() => _isResuming = false);
    }
  }

  Widget _buildChoiceChips({
    required List<int> values,
    required int selected,
    required String Function(int value) labelFor,
    required ValueChanged<int> onPick,
    required bool isDark,
  }) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: values.map((v) {
        final isSelected = v == selected;
        return GestureDetector(
          key: ValueKey('choice_chip_$v'),
          onTap: () {
            onPick(v);
            HapticFeedback.selectionClick();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
              labelFor(v),
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
      }).toList(),
    );
  }

  String _getSourceHint() {
    switch (_sourceType) {
      case 'youtube':
        return 'https://youtube.com/watch?v=...';
      case 'gdrive':
        return 'https://drive.google.com/file/d/...';
      case 'file':
        return _pickedFileName ?? 'Pilih file video (.mp4/.mov/.mkv)...';
      case 'topic':
        return 'Tulis topik atau ide video di sini...';
      default:
        return 'Masukkan link atau topik video...';
    }
  }

  Widget _buildSourceTypeChip(String id, String label, IconData icon, bool isDark) {
    final isSelected = _sourceType == id;
    return GestureDetector(
      onTap: () {
        setState(() => _sourceType = id);
        HapticFeedback.selectionClick();
      },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected
                  ? (isDark ? Colors.black : Colors.white)
                  : (isDark ? Colors.white70 : Colors.black87),
            ),
            const SizedBox(width: 6),
            Text(
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
          ],
        ),
      ),
    );
  }
}
