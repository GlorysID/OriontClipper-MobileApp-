class HookStyle {
  final String preset;
  final String position;
  final String highlightColor;

  static const Map<String, String> presetNames = {
    'hormozi': 'Alex Hormozi (Bold & Yellow)',
    'capcut': 'CapCut Modern (Clean Pill)',
    'cinematic': 'Cinematic Gold (Warm Film)',
    'minimal': 'Minimalist (Stroke & Shadow)',
    'neon_badge': 'Cyber Neon (Cyan Glow)',
  };

  static const Map<String, String> positionNames = {
    'top': 'Atas (Top)',
    'upper_center': 'Tengah-Atas (Upper Center)',
    'center': 'Tengah (Center)',
    'lower': 'Bawah (Lower)',
  };

  static const Map<String, String> colorNames = {
    '#ffe600': 'Kuning 🟡',
    '#00e5ff': 'Cyan 🔵',
    '#ff3b30': 'Merah 🔴',
    '#00ff66': 'Hijau 🟢',
    '#ffffff': 'Putih ⚪',
  };

  static const HookStyle defaultStyle = HookStyle();

  const HookStyle({
    this.preset = 'hormozi',
    this.position = 'upper_center',
    this.highlightColor = '#ffe600',
  });

  Map<String, dynamic> toJson() => {
    'preset': preset,
    'position': position,
    'highlightColor': highlightColor,
  };

  factory HookStyle.fromJson(Map<String, dynamic> json) => HookStyle(
    preset: json['preset'] ?? 'hormozi',
    position: json['position'] ?? 'upper_center',
    highlightColor: json['highlightColor'] ?? '#ffe600',
  );

  HookStyle copyWith({
    String? preset,
    String? position,
    String? highlightColor,
  }) {
    return HookStyle(
      preset: preset ?? this.preset,
      position: position ?? this.position,
      highlightColor: highlightColor ?? this.highlightColor,
    );
  }
}
