import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/campaign_policy.dart';
import 'models/clip_item.dart';
import 'models/hook_style.dart';
import 'screens/catalog_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/style_screen.dart';
import 'screens/studio_screen.dart';
import 'services/api_service.dart';
import 'services/job_tracker.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OriontClipperApp());
}

class OriontClipperApp extends StatefulWidget {
  const OriontClipperApp({super.key});

  @override
  State<OriontClipperApp> createState() => _OriontClipperAppState();
}

class _OriontClipperAppState extends State<OriontClipperApp> {
  bool _isDarkMode = true;

  @override
  void initState() {
    super.initState();
    _loadThemePreference();
  }

  Future<void> _loadThemePreference() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isDarkMode = prefs.getBool('is_dark_mode') ?? true;
    });
  }

  Future<void> _toggleTheme() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isDarkMode = !_isDarkMode;
    });
    await prefs.setBool('is_dark_mode', _isDarkMode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ORIONT CLIPPER',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: ResponsivePhoneShell(
        isDark: _isDarkMode,
        child: MainNavigationShell(
          isDarkMode: _isDarkMode,
          onToggleTheme: _toggleTheme,
        ),
      ),
    );
  }
}

/// Responsive wrapper: jika dibuka di browser PC/Desktop, aplikasi dibungkus
/// frame smartphone mewah berbayang halus agar rasanya persis seperti memegang smartphone.
class ResponsivePhoneShell extends StatelessWidget {
  final Widget child;
  final bool isDark;

  const ResponsivePhoneShell({
    super.key,
    required this.child,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > 500) {
          final targetHeight = (constraints.maxHeight - 24.0).clamp(580.0, 880.0);
          final targetWidth = (targetHeight * 0.49).clamp(340.0, 420.0);

          return Scaffold(
            backgroundColor: isDark ? const Color(0xFF040405) : const Color(0xFFEFEFEF),
            body: Center(
              child: Container(
                width: targetWidth,
                height: targetHeight,
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkBackground : AppColors.lightBackground,
                  borderRadius: BorderRadius.circular(40),
                  border: Border.all(
                    color: isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.08),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.85 : 0.12),
                      blurRadius: 40,
                      spreadRadius: 8,
                      offset: const Offset(0, 15),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(38),
                  child: child,
                ),
              ),
            ),
          );
        }
        return child;
      },
    );
  }
}

class MainNavigationShell extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const MainNavigationShell({
    super.key,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  int _currentIndex = 0;
  final List<ClipItem> _savedClips = [];
  HookStyle _activeStyle = HookStyle.defaultStyle;

  /// Satu-satunya sumber kebenaran job kurasi aktif (hidup di luar widget tree
  /// Studio sehingga pindah tab / reload tidak menghapus progress).
  JobTracker get _tracker => JobTracker.instance;

  @override
  void initState() {
    super.initState();
    _tracker.onCompleted = _handleJobCompleted;
    _tracker.onFailed = _handleJobFailed;
    _tracker.onCancelled = _handleJobCancelled;
    _tracker.onDetached = _handleJobDetached;
    unawaited(_boot());
  }

  /// Urutan boot eksplisit: muat katalog → pulihkan job → sambung render →
  /// susun ulang batch terakhir Studio dari id yang dipersisten.
  Future<void> _boot() async {
    await _loadPreferences();
    // Tarik kebijakan campaign dari server sekali saat aplikasi mulai (fire & forget).
    unawaited(_pullCampaignPolicy());
    await _reconcileJobsAfterBoot();
    await _hydrateLastBatch();
  }

  /// Item 5: 'last_batch_v1' menyimpan HANYA id klip batch terakhir. Setelah
  /// katalog + peta job terbaca, susun ulang view "Batch terakhir" Studio supaya
  /// tidak hilang karena reload—tanpa mengarang klip yang tidak ada di katalog.
  Future<void> _hydrateLastBatch() async {
    await ClipJobMap.load();
    await _tracker.loadLastBatchIds();
    if (!mounted) return;
    _tracker.restoreLastBatch(_savedClips);
    setState(() {});
  }

  @override
  void dispose() {
    if (_tracker.onCompleted == _handleJobCompleted) {
      _tracker.onCompleted = null;
      _tracker.onFailed = null;
      _tracker.onCancelled = null;
      _tracker.onDetached = null;
    }
    super.dispose();
  }

  Future<void> _reconcileJobsAfterBoot() async {
    await _tracker.restore();
    if (_tracker.isBusy) {
      unawaited(_tracker.resumePolling());
    }
    await RenderResume.outstanding(
      clips: _savedClips,
      onUpdated: (updated) {
        if (!mounted) return;
        _updateClip(updated);
      },
      onMessage: (message) {
        if (mounted) _showMessage(message);
      },
    );
  }

  /// Selesai di latar: masukkan klip + peta jobId walau user sedang di tab lain.
  /// Jangan paksa pindah tab — cukup beri tahu lewat snackbar.
  void _handleJobCompleted(String jobId, List<ClipItem> clips) {
    if (!mounted) return;
    final wasOnStudio = _currentIndex == 0;
    setState(() {
      _savedClips.insertAll(0, clips);
      if (wasOnStudio) {
        _currentIndex = 1; // hanya lompat ke Catalog bila user memang masih di Studio
      }
    });
    _saveClipsToPrefs();
    // Simpan peta clipId -> jobId agar tombol render di katalog tahu job server-nya.
    unawaited(ClipJobMap.putAll(jobId, clips));
    _showMessage('Klip selesai dibuat (${clips.length} klip) 🎬');
  }

  void _handleJobFailed(String message) {
    if (!mounted) return;
    _showMessage('Kurasi gagal: $message', isError: true);
  }

  /// Item 14: user menekan Batalkan → kita tembak POST cancel, TAPI state baru
  /// dibuang setelah server mengonfirmasi status 'cancelled' lewat polling.
  void _handleJobCancelled(String jobId) {
    if (!mounted) return;
    _showMessage('Job #$jobId dibatalkan.');
  }

  /// Watchdog melepas diri — pesan jujur, bukan kegagalan.
  void _handleJobDetached(String message) {
    if (!mounted) return;
    _showMessage(message);
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: TextStyle(
              fontFamily: AppTypography.fontFamily,
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
          duration: const Duration(seconds: 4),
        ),
      );
  }

  Future<void> _pullCampaignPolicy() async {
    try {
      await ApiConfig.instance.ensureLoaded();
      final policy = await CampaignPolicy.pull();
      if (policy != null && mounted) {
        setState(() {}); // Segarkan layar yang membaca preferensi campaign.
      }
    } catch (_) {
      // Server belum tersedia — gunakan kebijakan lokal.
    }
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final savedClipsJson = prefs.getString('saved_clips_v1');
    final firstRun = savedClipsJson == null;

    if (!mounted) return;
    setState(() {
      _activeStyle = HookStyle(
        preset: prefs.getString('hook_style_preset') ?? 'hormozi',
        position: prefs.getString('hook_style_pos') ?? 'upper_center',
        highlightColor: prefs.getString('hook_style_color') ?? '#ffe600',
      );
    });

    setState(() {
      _savedClips.clear();

      if (firstRun || savedClipsJson.isEmpty) {
        // RUN PERTAMA (key belum ada / kosong) → beri klip contoh sekali saja.
        _seedSamples(prefs);
      } else {
        try {
          final decoded = jsonDecode(savedClipsJson);
          if (decoded is List) {
            // Daftar kosong yang sah ('[]') harus TETAP kosong — tidak di-seed ulang.
            _savedClips.addAll(decoded.map((m) => ClipItem.fromJson(m)));
          } else {
            _seedSamples(prefs);
          }
        } catch (_) {
          _seedSamples(prefs);
        }
      }
    });
  }

  void _seedSamples(SharedPreferences prefs) {
    if (prefs.getBool('samples_seeded_v1') ?? false) return;
    _loadInitialSampleClips();
    // Flag disimpan di dalam _loadInitialSampleClips → _saveClipsToPrefs chain.
    unawaited(prefs.setBool('samples_seeded_v1', true));
  }

  void _loadInitialSampleClips() {
    _savedClips.addAll([
      ClipItem(
        id: 'sample_1',
        hook: "Rahasia 1% Konten Kreator yang Nggak Pernah Dibocorin",
        topic: "Strategi Virality Organik",
        duration: "00:42",
        timestamp: "01:14 - 01:56",
        score: 98,
        caption: "Kenapa banyak yang konsisten bikin video tapi tetap sepi? Ini 1 prinsip fundamental yang diabaikan 99% orang.\n\n#contentcreator #mindset #growth #viral #shorts",
        preset: "CAPCUT EDITORIAL",
        sourceTitle: "Podcast Rahasia Sukses Digital",
        script: "Banyak kreator mengira algoritma itu mistis. Padahal kuncinya cuma ada di 3 detik pertama saat audiens memutuskan untuk bertahan atau scroll.",
      ),
      ClipItem(
        id: 'sample_2',
        hook: "Stop Buang Duit Buat Tools AI Berbayar, Ini Alternatif Gratisnya",
        topic: "Kurasi AI Architecture",
        duration: "00:36",
        timestamp: "02:30 - 03:06",
        score: 95,
        caption: "Software mahal bisa digantikan 100% gratis dengan framework ini. Simpan video ini sebelum di-take down!\n\n#aitools #techtips #productivity #freewebsite",
        preset: "HORMOZI IMPACT",
        sourceTitle: "Mastering AI Workflows 2026",
        script: "Kalian tidak perlu langganan ratusan ribu per bulan. Cukup gunakan model open weights dengan Groq LPU untuk memproses ribuan data secepat kilat.",
      ),
    ]);
    _saveClipsToPrefs();
  }

  Future<void> _saveClipsToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_savedClips.map((c) => c.toJson()).toList());
    await prefs.setString('saved_clips_v1', encoded);
  }

  void _deleteClip(String id) {
    setState(() {
      _savedClips.removeWhere((c) => c.id == id);
    });
    _saveClipsToPrefs();
    unawaited(ClipJobMap.removeClips([id]));
  }

  void _updateClip(ClipItem updated) {
    setState(() {
      final index = _savedClips.indexWhere((c) => c.id == updated.id);
      if (index != -1) {
        _savedClips[index] = updated;
      }
    });
    _saveClipsToPrefs();
  }

  void _clearAllClips() {
    setState(() {
      _savedClips.clear();
    });
    _saveClipsToPrefs();
    // Katalog kosong = peta clip->job tidak berguna lagi. "Hapus semua" di
    // Engine lewat jalur ini (item 2), begitu tombol Kosongkan di Katalog.
    unawaited(ClipJobMap.clearAll());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;

    // Semua layar dibangun SEKALI dan disimpan di IndexedStack supaya state
    // (termasuk progress job di Studio) tidak dibuang saat pindah tab.
    final screens = <Widget>[
      StudioScreen(
        onToggleTheme: widget.onToggleTheme,
        isDarkMode: isDark,
        onNavigateToTab: (idx) => setState(() => _currentIndex = idx),
        activeStyle: _activeStyle,
        savedClips: _savedClips,
        onUpdateClip: _updateClip,
        // Item 3b: Studio hanya menyegarkan health pill / menyalakan timer
        // ulang 30 dtk saat tab ini benar-benar terlihat di IndexedStack.
        isTabVisible: _currentIndex == 0,
      ),
      CatalogScreen(
        clips: _savedClips,
        onToggleTheme: widget.onToggleTheme,
        isDarkMode: isDark,
        onDeleteClip: _deleteClip,
        onUpdateClip: _updateClip,
        onClearAll: _clearAllClips,
        onNavigateToStudio: () => setState(() => _currentIndex = 0),
      ),
      StyleScreen(
        onToggleTheme: widget.onToggleTheme,
        isDarkMode: isDark,
        onStyleChanged: (newStyle) {
          setState(() {
            _activeStyle = newStyle;
          });
        },
      ),
      SettingsScreen(
        onToggleTheme: widget.onToggleTheme,
        isDarkMode: isDark,
        onResetAllData: _clearAllClips,
      ),
    ];

    return Scaffold(
      backgroundColor: isDark ? AppColors.darkBackground : AppColors.lightBackground,
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
          border: Border(
            top: BorderSide(
              color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
              width: 0.8,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SafeArea(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Expanded(child: _buildNavItem(0, Icons.blur_on_rounded, 'STUDIO', isDark)),
              Expanded(child: _buildNavItem(1, Icons.auto_awesome_motion_rounded, 'CATALOG', isDark)),
              Expanded(child: _buildNavItem(2, Icons.palette_outlined, 'STYLE', isDark)),
              Expanded(child: _buildNavItem(3, Icons.tune_rounded, 'ENGINE', isDark)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label, bool isDark) {
    final isSelected = _currentIndex == index;
    final activeColor = isDark ? Colors.white : Colors.black;
    final inactiveColor = isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.05))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: isSelected
              ? Border.all(
                  color: isDark ? Colors.white.withValues(alpha: 0.18) : Colors.black.withValues(alpha: 0.12),
                  width: 0.8,
                )
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: isSelected ? activeColor : inactiveColor,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontFamily: AppTypography.fontFamily,
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                letterSpacing: 1.2,
                color: isSelected ? activeColor : inactiveColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
