import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../components/app_card.dart';
import '../components/circular_button.dart';
import '../components/pill_tag.dart';
import '../components/primary_button.dart';
import '../models/hook_style.dart';
import '../theme/app_theme.dart';

class StyleScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final bool isDarkMode;
  final Function(HookStyle)? onStyleChanged;

  const StyleScreen({
    super.key,
    required this.onToggleTheme,
    required this.isDarkMode,
    this.onStyleChanged,
  });

  @override
  State<StyleScreen> createState() => _StyleScreenState();
}

class _StyleScreenState extends State<StyleScreen> {
  String _preset = 'hormozi';
  String _position = 'upper_center';
  String _highlightColor = '#ffe600';
  final String _sampleHook = 'RAHASIA 1% KONTEN KREATOR YANG *NGGAK PERNAH* DIBOCORIN';

  @override
  void initState() {
    super.initState();
    _loadStyle();
  }

  Future<void> _loadStyle() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _preset = prefs.getString('hook_style_preset') ?? 'hormozi';
      _position = prefs.getString('hook_style_pos') ?? 'upper_center';
      _highlightColor = prefs.getString('hook_style_color') ?? '#ffe600';
    });
  }

  Future<void> _saveStyle() async {
    // Diambil SEBELUM await: hindari memakai BuildContext lintas async gap.
    final messenger = ScaffoldMessenger.of(context);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('hook_style_preset', _preset);
    await prefs.setString('hook_style_pos', _position);
    await prefs.setString('hook_style_color', _highlightColor);

    final style = HookStyle(
      preset: _preset,
      position: _position,
      highlightColor: _highlightColor,
    );
    widget.onStyleChanged?.call(style);
    HapticFeedback.mediumImpact();

    messenger.showSnackBar(
      SnackBar(
        content: const Text(
          'Style & Tata Letak Hook berhasil disimpan! 🎨',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
        ),
        backgroundColor: Colors.black,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(AppSpacing.lg),
      ),
    );
  }

  Color _parseColor(String hex) {
    try {
      final clean = hex.replaceAll('#', '');
      return Color(int.parse('FF$clean', radix: 16));
    } catch (_) {
      return const Color(0xFFFFE600);
    }
  }

  Alignment _getAlignment(String pos) {
    switch (pos) {
      case 'top':
        return const Alignment(0, -0.75);
      case 'upper_center':
        return const Alignment(0, -0.35);
      case 'center':
        return Alignment.center;
      case 'lower':
        return const Alignment(0, 0.55);
      default:
        return const Alignment(0, -0.35);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;

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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const PillTag(
                  label: 'HOOK STUDIO • 9:16',
                  variant: PillTagVariant.outline,
                ),
                CircularIconButton(
                  icon: isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                  tooltip: 'Ganti Tema',
                  onPressed: widget.onToggleTheme,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xxl),

            // Editorial Title
            Text(
              'Style &\nHook Studio',
              style: AppTypography.displayHero(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Kustomisasi visual hook, warna highlight kata, dan tata letak vertikal 9:16.',
              style: AppTypography.body(isDark),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Live 9:16 Preview Canvas (/previewhook equivalent)
            Text(
              'LIVE PREVIEW 9:16 CANVAS',
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            Center(
              child: AspectRatio(
                aspectRatio: 9 / 12,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E1118),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: isDark ? Colors.white12 : Colors.black26,
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Stack(
                      children: [
                        // Safe zone guides (dashed)
                        Positioned.fill(
                          child: Container(
                            margin: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.06),
                                width: 1,
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),

                        // Position indicator badge at top
                        Positioned(
                          top: 12,
                          left: 14,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.white24, width: 0.8),
                            ),
                            child: Text(
                              'POSISI: ${HookStyle.positionNames[_position]}',
                              style: const TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),

                        // Subtitle sample at fixed bottom
                        Positioned(
                          bottom: 24,
                          left: 16,
                          right: 16,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Simak penjelasan lengkapnya berikut ini...',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: AppTypography.fontFamily,
                                color: _parseColor(_highlightColor),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),

                        // Hook Layer positioned dynamically
                        Align(
                          alignment: _getAlignment(_position),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: _buildHookPreview(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),

            // 1. Preset Selection
            Text(
              'PILIHAN PRESET VISUAL',
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            ...HookStyle.presetNames.entries.map((entry) {
              final isSelected = _preset == entry.key;
              return AppCard(
                isSelected: isSelected,
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                onTap: () {
                  setState(() => _preset = entry.key);
                  HapticFeedback.selectionClick();
                },
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.value,
                        style: TextStyle(
                          fontFamily: AppTypography.fontFamily,
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                    ),
                    Icon(
                      isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: isSelected
                          ? (isDark ? Colors.white : Colors.black)
                          : (isDark ? Colors.white24 : Colors.black26),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: AppSpacing.xl),

            // 2. Position Selection (/setpos)
            Text(
              'LETAK POSISI HOOK',
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                children: HookStyle.positionNames.entries.map((entry) {
                  final isSelected = _position == entry.key;
                  return InkWell(
                    onTap: () {
                      setState(() => _position = entry.key);
                      HapticFeedback.selectionClick();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            entry.value,
                            style: TextStyle(
                              fontFamily: AppTypography.fontFamily,
                              fontSize: 13,
                              fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                              color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                            ),
                          ),
                          Icon(
                            isSelected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                            size: 18,
                            color: isSelected
                                ? (isDark ? Colors.white : Colors.black)
                                : (isDark ? Colors.white24 : Colors.black26),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // 3. Highlight Color Palette (/setcolor)
            Text(
              'WARNA HIGHLIGHT KATA',
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: HookStyle.colorNames.entries.map((entry) {
                  final isSelected = _highlightColor.toLowerCase() == entry.key.toLowerCase();
                  final col = _parseColor(entry.key);
                  return GestureDetector(
                    onTap: () {
                      setState(() => _highlightColor = entry.key);
                      HapticFeedback.selectionClick();
                    },
                    child: Column(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: col,
                            border: Border.all(
                              color: isSelected ? Colors.white : Colors.transparent,
                              width: 3,
                            ),
                            boxShadow: [
                              if (isSelected)
                                BoxShadow(
                                  color: col.withValues(alpha: 0.6),
                                  blurRadius: 10,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          entry.value.split(' ')[0],
                          style: TextStyle(
                            fontFamily: AppTypography.fontFamily,
                            fontSize: 10,
                            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                            color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),

            // Save Style Button
            PrimaryTactileButton(
              label: 'Simpan Konfigurasi Style',
              icon: Icons.check_circle_outline_rounded,
              onPressed: _saveStyle,
            ),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }

  Widget _buildHookPreview() {
    final highlightCol = _parseColor(_highlightColor);

    if (_preset == 'hormozi') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: highlightCol, width: 2),
        ),
        child: RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: const TextStyle(
              fontFamily: AppTypography.fontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              height: 1.25,
            ),
            children: [
              const TextSpan(text: 'RAHASIA 1% KREATOR\nYANG '),
              WidgetSpan(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: highlightCol,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text(
                    'NGGAK PERNAH',
                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 13),
                  ),
                ),
              ),
              const TextSpan(text: ' DIBOCORIN'),
            ],
          ),
        ),
      );
    } else if (_preset == 'cinematic') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFD4AF37), width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '✦ VIRAL HOOK ✦',
              style: TextStyle(color: Color(0xFFD4AF37), fontSize: 8.5, fontWeight: FontWeight.w800, letterSpacing: 1),
            ),
            const SizedBox(height: 3),
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: const TextStyle(
                  fontFamily: 'serif',
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  color: Colors.white,
                  height: 1.3,
                ),
                children: [
                  const TextSpan(text: 'Rahasia 1% Kreator yang '),
                  TextSpan(
                    text: 'Nggak Pernah',
                    style: TextStyle(color: highlightCol, fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(text: ' Dibocorin'),
                ],
              ),
            ),
          ],
        ),
      );
    } else if (_preset == 'neon_badge') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF031625).withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: highlightCol, width: 1.5),
          boxShadow: [
            BoxShadow(color: highlightCol.withValues(alpha: 0.35), blurRadius: 10),
          ],
        ),
        child: RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: TextStyle(
              fontFamily: AppTypography.fontFamily,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.3,
            ),
            children: [
              const TextSpan(text: 'RAHASIA 1% KREATOR YANG '),
              TextSpan(
                text: 'NGGAK PERNAH',
                style: TextStyle(color: highlightCol, fontWeight: FontWeight.w900),
              ),
              const TextSpan(text: ' DIBOCORIN'),
            ],
          ),
        ),
      );
    } else if (_preset == 'minimal') {
      return Text(
        _sampleHook.replaceAll('*', ''),
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: AppTypography.fontFamily,
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          decoration: TextDecoration.underline,
          decorationColor: Colors.white54,
        ),
      );
    }

    // Default: CapCut Modern
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24, width: 0.8),
      ),
      child: RichText(
        textAlign: TextAlign.center,
        text: TextSpan(
          style: const TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            height: 1.3,
          ),
          children: [
            const TextSpan(text: 'RAHASIA 1% KREATOR YANG '),
            TextSpan(
              text: 'NGGAK PERNAH',
              style: TextStyle(color: highlightCol),
            ),
            const TextSpan(text: ' DIBOCORIN'),
          ],
        ),
      ),
    );
  }
}
