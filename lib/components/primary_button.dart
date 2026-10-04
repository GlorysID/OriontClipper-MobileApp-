import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class PrimaryTactileButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final IconData? icon;
  final bool isSecondary;
  final double? height;
  final double? fontSize;
  final EdgeInsetsGeometry? padding;

  const PrimaryTactileButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.isLoading = false,
    this.icon,
    this.isSecondary = false,
    this.height,
    this.fontSize,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isSecondary
        ? (isDark ? AppColors.darkSurface : AppColors.lightSurface)
        : (isDark ? Colors.white : Colors.black);

    final fg = isSecondary
        ? (isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary)
        : (isDark ? Colors.black : Colors.white);

    final border = isSecondary
        ? BorderSide(color: isDark ? AppColors.darkBorder : AppColors.lightBorder, width: 0.9)
        : BorderSide.none;

    final buttonHeight = height ?? 48.0;
    final effectivePadding = padding ?? const EdgeInsets.symmetric(horizontal: 10);
    final effectiveFontSize = fontSize ?? 11.0;

    return SizedBox(
      width: double.infinity,
      height: buttonHeight,
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          disabledBackgroundColor: bg.withValues(alpha: 0.5),
          disabledForegroundColor: fg.withValues(alpha: 0.5),
          elevation: 0,
          side: border,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          padding: effectivePadding,
        ),
        child: isLoading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.0,
                  valueColor: AlwaysStoppedAnimation<Color>(fg),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 15, color: fg),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: AppTypography.fontFamily,
                        fontSize: effectiveFontSize,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: fg,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
