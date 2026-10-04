import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;
  final bool isSelected;
  final Color? customBackground;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.xl),
    this.margin = const EdgeInsets.only(bottom: AppSpacing.lg),
    this.onTap,
    this.isSelected = false,
    this.customBackground,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final defaultBg = isDark ? AppColors.darkSurface : AppColors.lightSurface;
    final borderColor = isSelected
        ? (isDark ? Colors.white : Colors.black)
        : (isDark ? AppColors.darkBorder : AppColors.lightBorder);

    Widget content = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: customBackground ?? (isSelected ? (isDark ? const Color(0xFF1E1E22) : const Color(0xFFF4F4F5)) : defaultBg),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: borderColor,
          width: isSelected ? 1.4 : 0.9,
        ),
      ),
      child: child,
    );

    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: content,
      );
    }
    return content;
  }
}
