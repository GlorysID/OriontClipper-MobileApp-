import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum PillTagVariant {
  solid,
  outline,
  status,
}

class PillTag extends StatelessWidget {
  final String label;
  final PillTagVariant variant;
  final Color? statusColor;
  final IconData? icon;
  final VoidCallback? onTap;

  const PillTag({
    super.key,
    required this.label,
    this.variant = PillTagVariant.outline,
    this.statusColor,
    this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Color bg;
    Color textColor;
    Border? border;

    switch (variant) {
      case PillTagVariant.solid:
        bg = isDark ? Colors.white : Colors.black;
        textColor = isDark ? Colors.black : Colors.white;
        border = null;
        break;
      case PillTagVariant.outline:
        bg = Colors.transparent;
        textColor = isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary;
        border = Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.9,
        );
        break;
      case PillTagVariant.status:
        bg = (statusColor ?? AppColors.statusActive).withValues(alpha: isDark ? 0.12 : 0.08);
        textColor = isDark ? Colors.white : const Color(0xFF0F172A);
        border = Border.all(
          color: (statusColor ?? AppColors.statusActive).withValues(alpha: 0.3),
          width: 0.9,
        );
        break;
    }

    Widget pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: border,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (variant == PillTagVariant.status) ...[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: statusColor ?? AppColors.statusActive,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
          ] else if (icon != null) ...[
            Icon(icon, size: 12, color: textColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: textColor,
            ),
          ),
        ],
      ),
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: pill);
    }
    return pill;
  }
}

/// Ikon/label jujur untuk status kepatuhan klip.
///
/// BUG LAMA: UI hanya membedakan COMPLIANT vs bukan-COMPLIANT, sehingga
/// status NONE (tidak ada aturan campaign) ikut tampil oranye "⚠ REVIEW" —
/// seolah-olah server menemukan masalah. Sekarang NONE → chip netral 'BEBAS'
/// (atau tidak ada badge sama sekali lewat [ComplianceBadge.whenever]).
({String label, Color color})? complianceBadgeSpec(String status) {
  switch (status.toUpperCase()) {
    case 'COMPLIANT':
      return (label: '✓ COMPLIANT', color: Colors.green);
    case 'REVIEW':
      return (label: '⚠ REVIEW', color: AppColors.statusWarning);
    case 'NONE':
    default:
      return (label: 'BEBAS', color: Colors.transparent);
  }
}

class ComplianceBadge extends StatelessWidget {
  final String status;

  /// NONE tidak menampilkan badge sama sekali (bila true).
  final bool hideForNone;

  const ComplianceBadge({
    super.key,
    required this.status,
    this.hideForNone = false,
  });

  bool get _isNone => status.toUpperCase() == 'NONE';

  @override
  Widget build(BuildContext context) {
    if (hideForNone && _isNone) return const SizedBox.shrink();
    final spec = complianceBadgeSpec(status)!;
    final isNone = _isNone;
    final isNeutral = spec.color == Colors.transparent;
    final borderColor = isNeutral
        ? (Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkBorder
            : AppColors.lightBorder)
        : spec.color;
    final textColor = isNone
        ? (Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkTextSecondary
            : AppColors.lightTextSecondary)
        : spec.color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isNone
            ? Colors.transparent
            : spec.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: isNeutral ? Border.all(color: borderColor, width: 0.8) : null,
      ),
      child: Text(
        spec.label,
        style: TextStyle(
          color: textColor,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
