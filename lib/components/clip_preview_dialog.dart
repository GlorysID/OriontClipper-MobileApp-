import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../models/clip_item.dart';
import '../services/api_service.dart';
import '../services/job_tracker.dart' show stripHookMarkup;
import '../theme/app_theme.dart';
import 'circular_button.dart';
import 'pill_tag.dart';
import 'primary_button.dart';

/// Modal dialog preview pemutar video vertikal 9:16 interaktif.
/// Jika klip sudah punya URL video hasil render server, diputar sungguhan
/// via video_player; jika belum, tampil kanvas simulasi dengan visualisasi
/// gelombang audio dan animasi subtitle kinetik dinamis.
class ClipPreviewDialog extends StatefulWidget {
  final ClipItem clip;
  final bool isDarkMode;

  const ClipPreviewDialog({
    super.key,
    required this.clip,
    required this.isDarkMode,
  });

  static void show(BuildContext context, ClipItem clip, bool isDarkMode) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ClipPreviewDialog(clip: clip, isDarkMode: isDarkMode),
    );
  }

  @override
  State<ClipPreviewDialog> createState() => _ClipPreviewDialogState();
}

class _ClipPreviewDialogState extends State<ClipPreviewDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  Timer? _playbackTimer;
  int _currentSecond = 0;
  int _totalDurationSeconds = 45;
  bool _isPlaying = true;
  int _activeWordIndex = 0;

  late List<String> _words;

  /// Jumlah kata per baris subtitle kinetik (satu "run").
  static const int _wordsPerRun = 4;

  // Pemutar video asli (hanya aktif bila clip.videoUrl tersedia)
  VideoPlayerController? _videoController;
  bool _videoInitializing = false;
  String? _videoError;

  bool get _hasRealVideo {
    final url = widget.clip.videoUrl;
    return url != null && url.isNotEmpty;
  }

  /// Video hanya bisa diputar/diunduh bila benar-benar ada URL render server.
  bool get _canPlayVideo => _hasRealVideo && _videoError == null;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    // Parse duration from string e.g. "00:45" -> 45
    final parts = widget.clip.duration.split(':');
    if (parts.length == 2) {
      final mins = int.tryParse(parts[0]) ?? 0;
      final secs = int.tryParse(parts[1]) ?? 45;
      _totalDurationSeconds = mins * 60 + secs;
      if (_totalDurationSeconds <= 0) _totalDurationSeconds = 45;
    }

    // Build subtitle word sequence from hook and script.
    // Markup highlight (*KATA* / [KATA]) dibuang agar asterisk/bracket tidak
    // tampil literal — sama seperti parse_hook_tokens di server (katanya tetap).
    final fullText = widget.clip.script.isNotEmpty ? widget.clip.script : widget.clip.hook;
    _words = stripHookMarkup(fullText)
        .split(' ')
        .where((w) => w.trim().isNotEmpty)
        .toList();
    if (_words.isEmpty) {
      _words = stripHookMarkup(widget.clip.hook).split(' ').where((w) => w.trim().isNotEmpty).toList();
    }
    if (_words.isEmpty) _words = const ['Siap', 'dirender'];

    if (_hasRealVideo) {
      _initVideo();
    } else {
      _startPlayback();
    }
  }

  Future<void> _initVideo() async {
    setState(() {
      _videoInitializing = true;
      _videoError = null;
    });
    final controller = VideoPlayerController.networkUrl(Uri.parse(widget.clip.videoUrl!));
    _videoController = controller;
    try {
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _videoInitializing = false;
        _totalDurationSeconds = controller.value.duration.inSeconds;
        if (_totalDurationSeconds <= 0) _totalDurationSeconds = 45;
      });
      controller.addListener(_onVideoTick);
      await controller.play();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _videoInitializing = false;
        _videoError = 'Video gagal dimuat dari server';
      });
      // JANGAN berhenti di layar error: aktifkan timer simulasi sehingga kata
      // tetap berjalan (bug lama: kanvas beku di detik 0 dengan label error).
      _startPlayback();
    }
  }

  void _onVideoTick() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    setState(() {
      _currentSecond = controller.value.position.inSeconds;
      _isPlaying = controller.value.isPlaying;
    });
  }

  void _startPlayback() {
    _playbackTimer?.cancel();
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 350), (timer) {
      if (!_isPlaying) return;
      // Video asli punya posisinya sendiri (lihat _onVideoTick) — timer ini
      // hanya menggerakkan kanvas simulasi.
      if (_canPlayVideo && _videoController?.value.isInitialized == true) return;
      if (mounted) {
        setState(() {
          _activeWordIndex = (_activeWordIndex + 1) % _words.length;
          _currentSecond = ((_activeWordIndex / _words.length) * _totalDurationSeconds).toInt();
        });
      }
    });
  }

  /// Fraction (0..1) dari scrub bar → seek. Video asli memakai seekTo sungguhan;
  /// simulasi memetakan ke kata agar highlight ikut melompat.
  void _seekToFraction(double fraction) {
    final f = fraction.clamp(0.0, 1.0);
    final controller = _videoController;
    if (_canPlayVideo && controller != null && controller.value.isInitialized) {
      final total = controller.value.duration;
      final target = total * f;
      controller.seekTo(target < Duration.zero ? Duration.zero : target);
      setState(() {
        _currentSecond = target.inSeconds;
        _activeWordIndex = _words.isEmpty
            ? 0
            : (_words.length * f).round().clamp(0, _words.length - 1);
      });

      HapticFeedback.selectionClick();
      return;
    }
    setState(() {
      _currentSecond = (_totalDurationSeconds * f).toInt();
      _activeWordIndex = (_words.length * f).truncate().clamp(0, _words.length - 1);
    });
    HapticFeedback.selectionClick();
  }

  void _togglePlayPause() {
    final controller = _videoController;
    if (_canPlayVideo && controller != null && controller.value.isInitialized) {
      HapticFeedback.lightImpact();
      if (controller.value.isPlaying) {
        controller.pause();
      } else {
        controller.play();
      }
      setState(() {});
      return;
    }
    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        _animController.repeat(reverse: true);
      } else {
        _animController.stop();
      }
    });
    HapticFeedback.lightImpact();
  }

  void _replay() {
    final controller = _videoController;
    if (_canPlayVideo && controller != null && controller.value.isInitialized) {
      controller.seekTo(Duration.zero);
      controller.play();
      HapticFeedback.mediumImpact();
      return;
    }
    setState(() {
      _activeWordIndex = 0;
      _currentSecond = 0;
      _isPlaying = true;
      _animController.repeat(reverse: true);
    });
    HapticFeedback.mediumImpact();
  }

  /// Unduh mp4 (server v1.1 mengirim Content-Disposition: attachment untuk
  /// ?dl=1 → di web ini memicu dialog download browser).
  /// TODO(native-android): saat berjalan sebagai aplikasi Android,
  /// launchUrl hanya membuka browser/external — perlu path unduhan native
  /// (mis. share_plus / flutter_downloader + save ke galeri) di lane berikutnya.
  Future<void> _downloadVideo() async {
    final url = widget.clip.videoUrl;
    if (url == null || url.isEmpty) {
      _showPreviewToast('Video belum dirender server — tidak ada yang bisa diunduh.', isError: true);
      return;
    }
    HapticFeedback.lightImpact();
    final uri = Uri.parse(ApiService.shared.config.downloadUrl(url));
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      _showPreviewToast('Browser menolak membuka tautan unduhan.', isError: true);
    }
  }

  Future<void> _copyVideoLink() async {
    final url = widget.clip.videoUrl;
    if (url == null || url.isEmpty) {
      _showPreviewToast('Video belum dirender server — tidak ada tautan.', isError: true);
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    HapticFeedback.lightImpact();
    _showPreviewToast('Tautan video disalin ke clipboard! 🔗');
  }

  void _showPreviewToast(String message, {bool isError = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(
            color: isError ? Colors.white : (isDark ? Colors.black : Colors.white),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
        backgroundColor: isError ? AppColors.statusDanger : (isDark ? Colors.white : Colors.black),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(AppSpacing.lg),
      ),
    );
  }

  void _copyCaption() {
    Clipboard.setData(ClipboardData(text: widget.clip.caption));
    HapticFeedback.lightImpact();
    _showPreviewToast('Caption & Hashtags berhasil disalin! 📋');
  }

  void _copyScript() {
    final text = 'HOOK: ${widget.clip.hook}\nTOPIK: ${widget.clip.topic}\nNASKAH:\n${widget.clip.script}';
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    _showPreviewToast('Naskah skrip subtitle disalin ke clipboard! 🎬');
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    _animController.dispose();
    _videoController?.removeListener(_onVideoTick);
    _videoController?.dispose();
    _videoController = null;
    super.dispose();
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final presetUpper = widget.clip.preset.toUpperCase();

    return Container(
      height: MediaQuery.of(context).size.height * 0.90,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F0F12) : const Color(0xFFF9F9FB),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 44,
            height: 4.5,
            decoration: BoxDecoration(
              color: isDark ? Colors.white24 : Colors.black26,
              borderRadius: BorderRadius.circular(3),
            ),
          ),

          // Header Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PillTag(
                      label: '${widget.clip.preset} • 9:16',
                      variant: PillTagVariant.solid,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Live Vertical Preview',
                      style: TextStyle(
                        fontFamily: AppTypography.fontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                      ),
                    ),
                  ],
                ),
                CircularIconButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Tutup',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Main 9:16 Simulated Video Canvas
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 9 / 16,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                    border: Border.all(
                      color: isDark ? Colors.white12 : Colors.black26,
                      width: 1.5,
                    ),
                  ),
                   child: ClipRRect(
                     borderRadius: BorderRadius.circular(22),
                     child: Stack(
                       fit: StackFit.expand,
                       children: [
                         // Video asli hasil render server (fallback ke kanvas simulasi bila kosong)
                         if (_hasRealVideo && _videoController != null && _videoController!.value.isInitialized && _videoError == null)
                           Center(
                             child: VideoPlayer(_videoController!),
                           )
                         else
                           // Background Atmospheric Gradient
                           Container(
                             decoration: const BoxDecoration(
                               gradient: LinearGradient(
                                 colors: [
                                   Color(0xFF0A0A0E),
                                   Color(0xFF14141E),
                                   Color(0xFF08080C),
                                 ],
                                 begin: Alignment.topCenter,
                                 end: Alignment.bottomCenter,
                               ),
                             ),
                           ),

                         // Loading video dari server
                         if (_hasRealVideo && _videoInitializing)
                           const Center(
                             child: SizedBox(
                               width: 26,
                               height: 26,
                               child: CircularProgressIndicator(
                                 strokeWidth: 2.2,
                                 valueColor: AlwaysStoppedAnimation<Color>(Colors.white54),
                               ),
                             ),
                           ),

                         // Label fallback error video
                         if (_videoError != null)
                           Center(
                             child: Text(
                               '$_videoError\nMenampilkan simulasi.',
                               textAlign: TextAlign.center,
                               style: TextStyle(
                                 fontFamily: AppTypography.fontFamily,
                                 fontSize: 11,
                                 height: 1.5,
                                 color: Colors.white.withValues(alpha: 0.65),
                               ),
                             ),
                           ),

                         // Animated Audio Waveform in Center (hanya mode simulasi)
                         if (!_hasRealVideo || _videoError != null)
                           Center(
                             child: AnimatedBuilder(
                               animation: _animController,
                               builder: (context, child) {
                                 return Row(
                                   mainAxisAlignment: MainAxisAlignment.center,
                                   children: List.generate(14, (idx) {
                                     final animVal = (_animController.value + (idx * 0.12)) % 1.0;
                                     final height = _isPlaying ? (16 + (animVal * 42)) : 8.0;
                                     return Container(
                                       margin: const EdgeInsets.symmetric(horizontal: 2.2),
                                       width: 3.5,
                                       height: height,
                                       decoration: BoxDecoration(
                                         color: isDark
                                             ? Colors.white.withValues(alpha: 0.35 + (animVal * 0.45))
                                             : Colors.white70,
                                         borderRadius: BorderRadius.circular(4),
                                       ),
                                     );
                                   }),
                                 );
                               },
                             ),
                           ),


                        // Top Overlay: Virality Badge & Timecode
                        Positioned(
                          top: 14,
                          left: 14,
                          right: 14,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.white24, width: 0.8),
                                ),
                                child: Text(
                                  'VIRAL SCORE ${widget.clip.score}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.white24, width: 0.8),
                                ),
                                child: Text(
                                  widget.clip.duration,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Kinetic Subtitle Display (Lower-Middle Center)
                        Positioned(
                          bottom: 55,
                          left: 16,
                          right: 16,
                          child: _buildSubtitlesByPreset(presetUpper),
                        ),

                        // Scrub Timeline bar at absolute bottom of video
                        Positioned(
                          bottom: 12,
                          left: 14,
                          right: 14,
                          child: Row(
                            children: [
                              Text(
                                _formatTime(_currentSecond),
                                style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                // SCRUB NYATA: tap/drag memetakan fraction ke
                                // seekTo (video asli) atau ke posisi kata
                                // (simulasi). Sebelumnya bar ini murni dekoratif.
                                child: Builder(
                                  builder: (scrubContext) {
                                    double fractionFor(Offset global) {
                                      final box =
                                          scrubContext.findRenderObject() as RenderBox?;
                                      if (box == null || box.size.width <= 0) return 0.0;
                                      return (box.globalToLocal(global).dx / box.size.width)
                                          .clamp(0.0, 1.0);
                                    }

                                    return GestureDetector(
                                      key: const ValueKey('preview_scrub_bar'),
                                      behavior: HitTestBehavior.opaque,
                                      onTapDown: (d) => _seekToFraction(fractionFor(d.globalPosition)),
                                      onHorizontalDragUpdate: (d) =>
                                          _seekToFraction(fractionFor(d.globalPosition)),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(3),
                                          child: LinearProgressIndicator(
                                            value: _totalDurationSeconds > 0
                                                ? (_currentSecond / _totalDurationSeconds).clamp(0.0, 1.0)
                                                : 0.0,
                                            backgroundColor: Colors.white12,
                                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                                            minHeight: 3.5,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _formatTime(_totalDurationSeconds),
                                style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Control Bar: Play / Pause, Replay, Action buttons
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl, vertical: 12),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              border: Border(
                top: BorderSide(
                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                  width: 0.8,
                ),
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularIconButton(
                      icon: Icons.replay_rounded,
                      tooltip: 'Ulangi',
                      size: 40,
                      onPressed: _replay,
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    CircularIconButton(
                      icon: _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      tooltip: _isPlaying ? 'Pause' : 'Play',
                      size: 48,
                      onPressed: _togglePlayPause,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: PrimaryTactileButton(
                        label: 'Salin Caption',
                        icon: Icons.copy_rounded,
                        isSecondary: true,
                        onPressed: _copyCaption,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: PrimaryTactileButton(
                        label: 'Salin Skrip Video',
                        icon: Icons.subtitles_rounded,
                        isSecondary: true,
                        onPressed: _copyScript,
                      ),
                    ),
                  ],
                ),
                // EKSPOR: selalu tampil supaya user tahu jalurnya, tapi jujur
                // disabled + tooltip "Belum dirender" bila video belum ada.
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Tooltip(
                        message: _hasRealVideo
                            ? (_canPlayVideo
                                ? 'Unduh mp4 dari server'
                                : 'Video gagal dimuat — coba lagi nanti')
                            : 'Belum dirender',
                        child: PrimaryTactileButton(
                          label: 'Unduh Video',
                          icon: Icons.download_rounded,
                          height: 44,
                          fontSize: 10.5,
                          onPressed: _hasRealVideo && _canPlayVideo ? _downloadVideo : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      flex: 2,
                      child: Tooltip(
                        message: _hasRealVideo ? 'Salin tautan video' : 'Belum dirender',
                        child: PrimaryTactileButton(
                          label: 'Salin Tautan',
                          icon: Icons.link_rounded,
                          isSecondary: true,
                          height: 44,
                          fontSize: 10.5,
                          onPressed: _hasRealVideo ? _copyVideoLink : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubtitlesByPreset(String preset) {
    final startIdx = ((_activeWordIndex ~/ _wordsPerRun) * _wordsPerRun)
        .clamp(0, _words.isEmpty ? 0 : _words.length - 1);
    final endIdx = (startIdx + _wordsPerRun).clamp(0, _words.length);
    final chunkWords = _words.sublist(startIdx, endIdx);

    /// Indeks absolut tiap kata dalam run — HILANGKAN `_words.indexOf(word)`:
    /// untuk kalimat dengan kata berulang (atau kata sama di run lain), indexOf
    /// selalu mengembalikan kemunculan PERTAMA sehingga highlight menempel di
    /// kata yang salah. Sekarang highlight ditentukan oleh posisi run+offset.
    final indexed = <(String word, int absolute)>[
      for (var i = 0; i < chunkWords.length; i++) (chunkWords[i], startIdx + i),
    ];

    if (preset.contains('HORMOZI')) {
      // Hormozi Impact: Black on High-Contrast Yellow box
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: indexed.map((pair) {
              final word = pair.$1;
              final isActive = pair.$2 == _activeWordIndex;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: isActive ? const Color(0xFFFFE600) : Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: isActive ? Colors.black : Colors.white24,
                    width: 1.2,
                  ),
                ),
                child: Text(
                  word.toUpperCase(),
                  style: TextStyle(
                    fontFamily: AppTypography.fontFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: isActive ? Colors.black : Colors.white,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      );
    } else if (preset.contains('CINEMATIC')) {
      // Cinematic Gold: Understated serif font with gold top badge
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFD4AF37).withValues(alpha: 0.4), width: 1),
        ),
        child: Column(
          children: [
            const Text(
              '✦ KEY INSIGHT ✦',
              style: TextStyle(color: Color(0xFFD4AF37), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.2),
            ),
            const SizedBox(height: 4),
            Text(
              chunkWords.join(' '),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'serif',
                fontSize: 14,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                height: 1.3,
              ),
            ),
          ],
        ),
      );
    } else if (preset.contains('NEON')) {
      // Neon Third: Electric cyan lower third box
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF031625).withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF00FFCC), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00FFCC).withValues(alpha: 0.35),
              blurRadius: 10,
            ),
          ],
        ),
        child: Text(
          chunkWords.join(' ').toUpperCase(),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Color(0xFF00FFCC),
            letterSpacing: 0.6,
          ),
        ),
      );
    } else if (preset.contains('MINIMAL')) {
      // Pure Minimalist: Swiss typography, clean underline
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          chunkWords.join(' '),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            decoration: TextDecoration.underline,
            decorationColor: Colors.white38,
          ),
        ),
      );
    }

    // Default: CapCut Editorial (White bold with kinetic yellow active word emphasis)
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 4,
      children: indexed.map((pair) {
        final word = pair.$1;
        final isActive = pair.$2 == _activeWordIndex;
        return Text(
          word.toUpperCase(),
          style: TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w900,
            color: isActive ? const Color(0xFFFFEB3B) : Colors.white,
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: 0.9),
                blurRadius: 6,
                offset: const Offset(1, 1),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
