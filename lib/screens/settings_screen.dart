import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../components/app_card.dart';
import '../components/circular_button.dart';
import '../components/pill_tag.dart';
import '../components/primary_button.dart';
import '../components/setting_toggle_tile.dart';
import '../models/campaign_policy.dart';
import '../services/api_service.dart';
import '../services/job_tracker.dart';
import '../theme/app_theme.dart';

/// Kelas [CookieService] lokal sudah dihapus: cookie hidup di server
/// (GET/POST/DELETE /v1/cookies). Satu-satunya teks yang masih dipakai dari
/// modul lama adalah panduan export, dipindahkan ke sini.
const String _exportTutorial = '''
Panduan Export cookies.txt (Bypass Blokir Bot YouTube):

1. Buka browser (Chrome / Edge / Firefox) di PC / Laptop.
2. Login ke akun YouTube Anda (bisa gunakan akun cadangan).
3. Pasang ekstensi gratis "Get cookies.txt LOCALLY" dari Chrome Web Store.
4. Buka tab YouTube, klik ikon ekstensi → pilih "Export" → simpan sebagai cookies.txt.
5. Buka file tersebut, salin isinya, dan tempelkan di menu ini.
''';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final bool isDarkMode;

  /// Dipanggil shell untuk mode "Hapus semua": bersihkan katalog di memori +
  /// prefs. Mode "Hapus cache preferensi" TIDAK memanggil ini (klip harus
  /// tetap ada — jangan pernah bohong soal itu).
  final VoidCallback? onResetAllData;

  const SettingsScreen({
    super.key,
    required this.onToggleTheme,
    required this.isDarkMode,
    this.onResetAllData,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  Timer? _baseUrlSaveDebounce;
  bool _obscureToken = true;
  bool _testingConnection = false;
  String _testResult = '';
  bool _testSuccess = false;

  // Models dari server (/v1/models)
  List<AiModelInfo> _serverModels = [];
  bool _loadingModels = false;
  String _modelsError = '';

  // Preferences toggles
  bool _autoSubtitles = true;
  bool _highBitrate = true;
  bool _cacheTranscripts = true;
  String _preferredModel = 'llama-3.1-8b-instant';

  // Cookies (status SUNGGUH dari server v1.1, GET /v1/cookies)
  CookieStatus _cookieStatus = CookieStatus(hasCookies: false);
  bool _cookieStatusLoading = false;
  String _cookieStatusError = '';
  bool _cookieBusy = false;
  bool _campaignCustom = false;
  String _campaignRules = '';

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  @override
  void dispose() {
    // Timer debounce baseUrl harus dibatalkan, tidak bocor saat tab ditutup.
    _baseUrlSaveDebounce?.cancel();
    _baseUrlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    await ApiConfig.instance.ensureLoaded();
    final prefs = await SharedPreferences.getInstance();
    final policy = await CampaignPolicy.load();

    if (!mounted) return;
    setState(() {
      _baseUrlController.text = ApiConfig.instance.baseUrl;
      _tokenController.text = ApiConfig.instance.apiToken;
      _autoSubtitles = prefs.getBool('pref_auto_subtitles') ?? true;
      _highBitrate = prefs.getBool('pref_high_bitrate') ?? true;
      _cacheTranscripts = prefs.getBool('pref_cache_transcripts') ?? true;
      _preferredModel = ApiConfig.instance.preferredModel;
      _campaignCustom = policy.isCustom;
      _campaignRules = policy.rulesText;
    });

    _fetchModels();
    // v1.1: cookie hidup di SERVER (GET /v1/cookies). Prefs lokal bukan sumber
    // kebenaran lagi — jangan pernah menampilkannya sebagai status.
    _fetchCookieStatus();
  }

  Future<void> _fetchCookieStatus() async {
    setState(() {
      _cookieStatusLoading = true;
      _cookieStatusError = '';
    });
    try {
      final status = await ApiService.shared.getCookies();
      if (!mounted) return;
      setState(() {
        _cookieStatus = status;
        _cookieStatusLoading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _cookieStatus = CookieStatus(hasCookies: false);
        _cookieStatusLoading = false;
        _cookieStatusError = e.message;
      });
    }
  }

  Future<void> _fetchModels() async {
    setState(() {
      _loadingModels = true;
      _modelsError = '';
    });
    try {
      final res = await ApiService.shared.models();
      if (!mounted) return;
      setState(() {
        _serverModels = res.models;
        _loadingModels = false;
        if (_preferredModel.isEmpty && res.defaultModel.isNotEmpty) {
          _preferredModel = res.defaultModel;
        }
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _serverModels = [];
        _loadingModels = false;
        _modelsError = e.message;
      });
    }
  }

  void _onBaseUrlChanged(String value) {
    _baseUrlSaveDebounce?.cancel();
    _baseUrlSaveDebounce = Timer(const Duration(milliseconds: 600), () async {
      final normalized = value.trim();
      if (normalized.isNotEmpty) {
        await ApiConfig.instance.saveBaseUrl(normalized);
        if (mounted) {
          setState(() => _baseUrlController.text = ApiConfig.instance.baseUrl);
        }
        _fetchModels();
      }
    });
  }

  Future<void> _saveToken() async {
    await ApiConfig.instance.saveToken(_tokenController.text);
    _showToast('Token server tersimpan.');
  }

  Future<void> _testConnection() async {
    // Simpan dulu agar tes memakai URL terbaru.
    _baseUrlSaveDebounce?.cancel();
    final typed = _baseUrlController.text.trim();
    if (typed.isNotEmpty) {
      await ApiConfig.instance.saveBaseUrl(typed);
      if (mounted) setState(() => _baseUrlController.text = ApiConfig.instance.baseUrl);
    }

    setState(() {
      _testingConnection = true;
      _testResult = 'Menghubungi ${ApiConfig.instance.shortHostLabel}...';
    });

    try {
      final t0 = DateTime.now();
      final health = await ApiService.shared.health();
      final latency = DateTime.now().difference(t0).inMilliseconds;
      if (!mounted) return;
      setState(() {
        _testSuccess = health.ok;
        _testResult = health.ok
            ? 'Terhubung v${health.version} • Latensi: ${latency}ms • ${health.busy ? "SIBUK (ada job jalan)" : "IDLE"} • Uptime ${(health.uptimeS / 60).floor()} mnt'
            : 'Server merespons tapi menandai ok=false.';
      });
      if (health.ok) _fetchModels();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _testSuccess = false;
        _testResult = 'Gagal: ${e.message}';
      });
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  Future<void> _saveToggle(String key, bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, val);
  }

  Future<void> _saveModel(String modelId) async {
    setState(() => _preferredModel = modelId);
    // Kirim lewat ApiConfig → studio ikut mengirimnya sebagai preferred_model.
    await ApiConfig.instance.savePreferredModel(modelId);
    _showToast('Model default diatur ke $modelId');
  }

  Future<void> _manageCookiesDialog() async {
    // Jangan baca prefs lokal: cookie sesungguhnya hidup di server.
    final existing = _cookieStatus.hasCookies;
    final cookieCtrl = TextEditingController();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: AppSpacing.xxl,
            right: AppSpacing.xxl,
            top: AppSpacing.xxl,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + AppSpacing.xxl,
          ),
          child: Container(
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
                Text(
                  'YOUTUBE COOKIES MANAGER (/cookies)',
                  style: AppTypography.microHeader(widget.isDarkMode),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  existing
                      ? 'Server sudah menyimpan cookies (${_cookieStatus.updatedLabel}). '
                          'Tempel teks cookies.txt baru untuk menimpanya.'
                      : 'Server belum punya cookies. Tempel isi cookies.txt (format Netscape) '
                          'lalu Simpan — file disimpan di server, bukan di HP ini.',
                  style: AppTypography.body(widget.isDarkMode),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: cookieCtrl,
                  maxLines: 6,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  decoration: InputDecoration(
                    hintText: '# Netscape HTTP Cookie File\n.youtube.com TRUE / FALSE ...',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: PrimaryTactileButton(
                        label: _cookieBusy ? 'Menyimpan...' : 'Simpan ke Server',
                        height: 44,
                        fontSize: 10.5,
                        isLoading: _cookieBusy,
                        onPressed: _cookieBusy
                            ? null
                            : () async {
                                final text = cookieCtrl.text.trim();
                                if (text.length < 20) {
                                  _showToast(
                                    'Teks terlalu pendek untuk jadi cookies Netscape yang valid.',
                                    isError: true,
                                  );
                                  return;
                                }
                                setSheetState(() => _cookieBusy = true);
                                try {
                                  await ApiService.shared.postCookies(text);
                                  if (!ctx.mounted) return;
                                  Navigator.of(ctx).pop();
                                  if (!mounted) return;
                                  setState(() => _cookieBusy = false);
                                  await _fetchCookieStatus();
                                  if (mounted) _showToast('Cookies tersimpan di server.');
                                } on ApiError catch (e) {
                                  if (!mounted) return;
                                  setState(() => _cookieBusy = false);
                                  // 400 = server menolak format — tampilkan apa adanya.
                                  _showToast('Server menolak: ${e.message}', isError: true);
                                }
                              },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    CircularIconButton(
                      icon: Icons.delete_outline_rounded,
                      tooltip: existing ? 'Hapus Cookies di Server' : 'Tidak ada cookies untuk dihapus',
                      size: 42,
                      onPressed: (existing && !_cookieBusy)
                          ? () async {
                              setState(() => _cookieBusy = true);
                              try {
                                await ApiService.shared.deleteCookies();
                                if (!mounted) return;
                                setState(() => _cookieBusy = false);
                                await _fetchCookieStatus();
                                if (mounted) _showToast('Cookies dihapus dari server.');
                              } on ApiError catch (e) {
                                if (!mounted) return;
                                setState(() => _cookieBusy = false);
                                _showToast('Gagal menghapus: ${e.message}', isError: true);
                              }
                            }
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(cookieCtrl.dispose);
  }

  void _showTutorialModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
        title: Text(
          'Cara Export cookies.txt',
          style: TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
          ),
        ),
        content: Text(
          _exportTutorial,
          style: AppTypography.body(widget.isDarkMode),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.isDarkMode ? Colors.white : Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Mengerti',
              style: TextStyle(color: widget.isDarkMode ? Colors.black : Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  void _manageCampaignDialog() {
    bool tempCustom = _campaignCustom;
    final rulesController = TextEditingController(text: _campaignRules);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
          title: Text(
            'Campaign Compliance (/campaign)',
            style: TextStyle(
              fontFamily: AppTypography.fontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pilih apakah kurasi klip mengikuti gaya bebas viral atau mematuhi panduan sponsor/kampanye khusus.',
                  style: AppTypography.body(widget.isDarkMode),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() => tempCustom = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: !tempCustom
                                ? (widget.isDarkMode ? Colors.white : Colors.black)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: widget.isDarkMode ? Colors.white24 : Colors.black26,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              'Mode Bebas',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                                color: !tempCustom
                                    ? (widget.isDarkMode ? Colors.black : Colors.white)
                                    : (widget.isDarkMode ? Colors.white70 : Colors.black87),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() => tempCustom = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: tempCustom
                                ? (widget.isDarkMode ? Colors.white : Colors.black)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: widget.isDarkMode ? Colors.white24 : Colors.black26,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              'Aturan Custom',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                                color: tempCustom
                                    ? (widget.isDarkMode ? Colors.black : Colors.white)
                                    : (widget.isDarkMode ? Colors.white70 : Colors.black87),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (tempCustom) ...[
                  const SizedBox(height: 16),
                  Text(
                    'PANDUAN / BRIEF KAMPANYE:',
                    style: AppTypography.microHeader(widget.isDarkMode),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: rulesController,
                    maxLines: 4,
                    style: TextStyle(
                      fontFamily: AppTypography.fontFamily,
                      fontSize: 12,
                      color: widget.isDarkMode ? Colors.white : Colors.black,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Contoh: Jangan ada kata kasar, sebutkan brand di awal 5 detik, fokus edukasi...',
                      hintStyle: TextStyle(
                        color: (widget.isDarkMode ? Colors.white : Colors.black).withValues(alpha: 0.3),
                      ),
                      filled: true,
                      fillColor: widget.isDarkMode ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: widget.isDarkMode ? AppColors.darkBorder : AppColors.lightBorder,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Batal', style: TextStyle(color: widget.isDarkMode ? Colors.white70 : Colors.black54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: widget.isDarkMode ? Colors.white : Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                final rulesVal = rulesController.text.trim();
                await CampaignPolicy.save(tempCustom, rulesVal);
                unawaited(CampaignPolicy.push());
                if (!ctx.mounted) return;
                Navigator.of(ctx).pop();
                if (!mounted) return;
                setState(() {
                  _campaignCustom = tempCustom;
                  _campaignRules = rulesVal;
                });
                _showToast('Kebijakan kampanye diperbarui & dikirim ke server.');
              },
              child: Text(
                'Simpan',
                style: TextStyle(color: widget.isDarkMode ? Colors.black : Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    // Controller dialog kampanye dulu bocor (tidak pernah dibuang).
    ).whenComplete(rulesController.dispose);
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
        title: Text(
          'Panduan Penggunaan (/help)',
          style: TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHelpRow('▸ Kirim link YouTube / GDrive', 'Server otomatis ambil transkrip & menganalisis momen terbaik.'),
              _buildHelpRow('▸ Upload file video', 'Pilih file .mp4, .mov, atau .mkv — dikirim sungguhan ke server.'),
              _buildHelpRow('▸ Style & Hook (/style)', 'Kustomisasi preset visual (Hormozi, CapCut, dll), posisi teks, & warna highlight.'),
              _buildHelpRow('▸ Edit Teks Hook (/edithook)', 'Ubah teks hook sesukamu & gunakan *KATA* untuk highlight warna menyala.'),
              _buildHelpRow('▸ Cookies (/cookies)', 'Dikelola server — pasang, ganti, atau hapus langsung dari halaman ini.'),
              _buildHelpRow('▸ Campaign (/campaign)', 'Atur aturan kepatuhan sponsor — tersinkron ke server.'),
              _buildHelpRow('▸ Live Preview 9:16', 'Putar hasil render asli server, atau simulasi kinetik sebelum render.'),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.isDarkMode ? Colors.white : Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Tutup',
              style: TextStyle(color: widget.isDarkMode ? Colors.black : Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpRow(String title, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontFamily: AppTypography.fontFamily,
              fontWeight: FontWeight.w800,
              fontSize: 12,
              color: widget.isDarkMode ? Colors.white : Colors.black,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            style: TextStyle(
              fontFamily: AppTypography.fontFamily,
              fontSize: 11,
              color: widget.isDarkMode ? Colors.white70 : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
        title: Text(
          'Tentang OriontClip (/about)',
          style: TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'OriontClip 2.0 — Interactive AI Video Curator',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
            ),
            const SizedBox(height: 8),
            const Text('• Transkripsi: Whisper-Large-v3 LPU / YouTube Captions\n'
                '• Analisis AI: Llama 3.1 8B Instant (Ultra-cepat)\n'
                '• Subtitle: ASS Styling, Kinetic Highlight, Safe-Zone Placement\n'
                '• Render: 1080×1920 (9:16 Vertikal)\n'
                '• Instagram: @jalipryyy',
                style: TextStyle(fontSize: 11.5, height: 1.5)),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.isDarkMode ? Colors.white : Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Tutup', style: TextStyle(color: widget.isDarkMode ? Colors.black : Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _confirmResetData() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
        title: Text(
          'Reset Pengaturan & Cache',
          style: TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: widget.isDarkMode ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pilih scope reset. Keduanya TIDAK menyentuh baseUrl & token server.',
              style: AppTypography.body(widget.isDarkMode),
            ),
            const SizedBox(height: 14),
            Text(
              '1. Hapus cache preferensi — toggle pipeline, model pilihan, dan '
              'kebijakan campaign. Semua klip katalog tetap aman.',
              style: TextStyle(
                fontFamily: AppTypography.fontFamily,
                fontSize: 11.5,
                height: 1.45,
                color: widget.isDarkMode ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '2. Hapus semua — cache preferensi DI ATAS plus seluruh klip '
              'katalog dan peta job render. Job di server ikut dihapus '
              '(DELETE /v1/jobs) selama server bisa dihubungi.',
              style: TextStyle(
                fontFamily: AppTypography.fontFamily,
                fontSize: 11.5,
                height: 1.45,
                color: widget.isDarkMode ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
          ],
        ),
        // Tiga aksi ditumpuk vertikal: di layar sempit, baris aksi horizontal
        // akan overflow (label Indonesia panjang).
        actionsOverflowButtonSpacing: 4,
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton(
                key: const ValueKey('reset_prefs_button'),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _resetPreferenceCache();
                },
                child: Text(
                  'Hapus Cache Preferensi',
                  style: TextStyle(
                    color: widget.isDarkMode ? Colors.white : Colors.black,
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              ElevatedButton(
                key: const ValueKey('reset_all_button'),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.statusDanger),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _resetEverything();
                },
                child: const Text(
                  'Hapus Semua (Klip + Cache)',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11.5),
                ),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(
                  'Batal',
                  style: TextStyle(color: widget.isDarkMode ? Colors.white60 : Colors.black54),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// MODE 1 — jujur: HANYA cache preferensi pipeline. Klip, baseUrl, token
  /// tidak disentuh.
  Future<void> _resetPreferenceCache() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in _pipelinePrefKeys) {
      await prefs.remove(key);
    }
    await ApiConfig.instance.savePreferredModel('');
    if (mounted) setState(() => _preferredModel = '');
    _loadPreferences();
    _showToast('Cache preferensi dibersihkan. Klip Anda tetap aman.');
  }

  /// Kunci preferensi yang dibuang KEDUA mode reset. `saved_clips_v1`,
  /// `api_base_url`, `api_token` sengaja TIDAK ada di daftar ini.
  static const List<String> _pipelinePrefKeys = <String>[
    'pref_auto_subtitles',
    'pref_high_bitrate',
    'pref_cache_transcripts',
    'pref_groq_model',
    'campaign_is_custom',
    'campaign_rules_text',
  ];

  /// Tambahan untuk mode "Hapus semua": jejak batch Studio + katalog + peta job
  /// (dibersihkan lewat [JobTracker.abandon]/shell/ClipJobMap.clearAll).
  static const List<String> _studioCacheKeys = <String>[
    JobTracker.lastBatchKey,
  ];

  /// MODE 2 — hapus semua: cache preferensi + katalog lokal + peta job, lalu
  /// hapus (fire-and-forget) tiap job server unik yang masih tercatat, supaya
  /// render yatim tidak terus jalan menggerus kapasitas server.
  Future<void> _resetEverything() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in _pipelinePrefKeys) {
      await prefs.remove(key);
    }
    for (final key in _studioCacheKeys) {
      await prefs.remove(key);
    }
    await ApiConfig.instance.savePreferredModel('');

    // Unique jobId dari peta clip->job sebelum peta dibersihkan.
    final jobMap = await ClipJobMap.load();
    final jobIds = jobMap.values.map((r) => r.jobId).toSet();
    final activeId = JobTracker.instance.jobId;
    if (activeId != null && activeId.isNotEmpty) jobIds.add(activeId);

    await ClipJobMap.clearAll();
    await JobTracker.instance.abandon();
    if (mounted) setState(() => _preferredModel = '');

    // Katalog via shell (menulis ulang saved_clips_v1 jadi kosong).
    widget.onResetAllData?.call();

    for (final id in jobIds) {
      unawaited(_deleteJobQuietly(id));
    }

    _loadPreferences();
    _showToast('Semua klip, peta job, dan cache preferensi dihapus.');
  }

  /// Hapus job di server tanpa menghentikan reset bila gagal (server bisa
  /// offline; job mungkin sudah selesai — bukan bencana).
  Future<void> _deleteJobQuietly(String jobId) async {
    try {
      await ApiService.shared.deleteJob(jobId);
    } catch (_) {
      // Fire-and-forget: status job tidak mengubah hasil reset lokal.
    }
  }

  void _showToast(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(
            color: widget.isDarkMode ? Colors.black : Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
        backgroundColor: isError ? AppColors.statusDanger : (widget.isDarkMode ? Colors.white : Colors.black),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(AppSpacing.lg),
      ),
    );
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
                  label: 'SERVER & ENGINE',
                  variant: PillTagVariant.outline,
                ),
                Row(
                  children: [
                    CircularIconButton(
                      icon: Icons.help_outline_rounded,
                      tooltip: 'Bantuan (/help)',
                      onPressed: _showHelpDialog,
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

            // Editorial Header
            Text(
              'Server &\nEngine',
              style: AppTypography.displayHero(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Hubungkan aplikasi ke server Python OriontClipper, pilih model kurasi, dan atur preferensi pipeline.',
              style: AppTypography.body(isDark),
            ),
            const SizedBox(height: AppSpacing.hero),

            // Section 0: SERVER CONNECTION (baru — pengganti koneksi Groq langsung)
            Text(
              'SERVER ORIONTCLIPPER',
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(
                          'BASE URL API',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: AppTypography.fontFamily,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      PillTag(
                        label: _testSuccess
                            ? 'AKTIF'
                            : (_testResult.isNotEmpty ? 'GAGAL' : 'BELUM DITES'),
                        variant: _testSuccess ? PillTagVariant.solid : PillTagVariant.outline,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _buildServerField(
                    controller: _baseUrlController,
                    obscure: false,
                    hint: ApiConfig.defaultBaseUrl,
                    onChanged: _onBaseUrlChanged,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'TOKEN SERVER (OPSIONAL — HEADER X-API-TOKEN)',
                    style: TextStyle(
                      fontFamily: AppTypography.fontFamily,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _buildServerField(
                    controller: _tokenController,
                    obscure: _obscureToken,
                    hint: 'Kosongkan untuk server loopback lokal',
                    onSubmitted: (_) => _saveToken(),
                    onToggleObscure: () => setState(() => _obscureToken = !_obscureToken),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    children: [
                      Expanded(
                        child: PrimaryTactileButton(
                          label: _testingConnection ? 'Memeriksa...' : 'Tes Koneksi',
                          icon: Icons.wifi_tethering_rounded,
                          onPressed: _testingConnection ? null : _testConnection,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: PrimaryTactileButton(
                          label: 'Simpan Token',
                          isSecondary: true,
                          onPressed: _saveToken,
                        ),
                      ),
                    ],
                  ),
                  if (_testResult.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
                        borderRadius: BorderRadius.circular(AppRadius.input),
                        border: Border.all(
                          color: _testSuccess
                              ? AppColors.statusActive.withValues(alpha: 0.4)
                              : AppColors.statusDanger.withValues(alpha: 0.4),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        _testResult,
                        style: TextStyle(
                          fontFamily: AppTypography.fontFamily,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _testSuccess ? AppColors.statusActive : AppColors.statusDanger,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // Note card: kredensial kini di server
            AppCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      'Kunci API kini dikelola server (atau Termux .env). '
                      'Aplikasi ini hanya bicara ke server — tidak ada lagi Groq key di HP Anda.',
                      style: AppTypography.body(isDark),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // Section 2: YouTube Cookies Manager (/cookies) — nyata via server v1.1
            Text(
              'COOKIES YOUTUBE BYPASS (/cookies)',
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'STATUS COOKIES',
                        style: TextStyle(
                          fontFamily: AppTypography.fontFamily,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                      PillTag(
                        label: _cookieStatusLoading
                            ? 'MEMERIKSA...'
                            : (_cookieStatus.hasCookies ? 'TERPASANG ✓' : 'TIDAK AKTIF'),
                        variant: _cookieStatus.hasCookies && !_cookieStatusLoading
                            ? PillTagVariant.solid
                            : PillTagVariant.outline,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Jujur: hanya apa yang server katakan (GET /v1/cookies).
                  Text(
                    _cookieStatusError.isNotEmpty
                        ? 'Server tidak bisa diperiksa: $_cookieStatusError'
                        : (_cookieStatus.hasCookies
                            ? 'Disimpan server • diperbarui ${_cookieStatus.updatedLabel}'
                            : 'YouTube mewajibkan cookies untuk video yang dibatasi umur '
                                'atau kena blokir bot-check. Sekarang bisa dipasang langsung '
                                'dari aplikasi ini.'),
                    style: AppTypography.body(isDark),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    children: [
                      Expanded(
                        child: PrimaryTactileButton(
                          label: _cookieStatus.hasCookies ? 'Ganti Cookies' : 'Pasang Cookies',
                          icon: Icons.vpn_key_outlined,
                          height: 44,
                          fontSize: 10.5,
                          onPressed: _cookieStatusLoading ? null : _manageCookiesDialog,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: PrimaryTactileButton(
                          label: 'Cara Export',
                          icon: Icons.help_outline_rounded,
                          isSecondary: true,
                          height: 44,
                          fontSize: 10.5,
                          onPressed: _showTutorialModal,
                        ),
                      ),
                      const SizedBox(width: 8),
                      CircularIconButton(
                        icon: Icons.refresh_rounded,
                        tooltip: 'Perbarui status dari server',
                        size: 44,
                        onPressed: _cookieStatusLoading ? null : _fetchCookieStatus,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // Section 3: Campaign Compliance Policy (/campaign)
            Text(
              'CAMPAIGN COMPLIANCE POLICY (/campaign)',
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'KEBIJAKAN KAMPANYE',
                        style: TextStyle(
                          fontFamily: AppTypography.fontFamily,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                        ),
                      ),
                      PillTag(
                        label: _campaignCustom ? 'ATURAN CUSTOM' : 'MODE BEBAS',
                        variant: _campaignCustom ? PillTagVariant.solid : PillTagVariant.outline,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _campaignCustom
                        ? 'Mematuhi panduan sponsor: ${_campaignRules.isEmpty ? "Aktif" : _campaignRules}'
                        : 'Mode bebas tanpa batasan aturan sponsor. Kurasi murni untuk potensi viralitas maksimal.',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.body(isDark),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  PrimaryTactileButton(
                    label: 'Atur Kebijakan Kampanye',
                    icon: Icons.verified_user_outlined,
                    onPressed: _manageCampaignDialog,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // Section 4: Model Inference Selector (dari server)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'MODEL INFERENCE ENGINE',
                  style: AppTypography.microHeader(isDark),
                ),
                GestureDetector(
                  onTap: _loadingModels ? null : _fetchModels,
                  child: Row(
                    children: [
                      Icon(
                        Icons.refresh_rounded,
                        size: 15,
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Muat ulang',
                        style: TextStyle(
                          fontFamily: AppTypography.fontFamily,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_loadingModels)
              AppCard(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                  ),
                ),
              )
            else if (_serverModels.isEmpty)
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DAFTAR MODEL BELUM TERSEDIA',
                      style: TextStyle(
                        fontFamily: AppTypography.fontFamily,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _modelsError.isNotEmpty
                          ? _modelsError
                          : 'Server aktif tapi belum mengirim daftar model. Tekan "Muat ulang" setelah server berjalan.',
                      style: AppTypography.body(isDark),
                    ),
                    if (_preferredModel.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'Model terpilih saat ini: $_preferredModel',
                        style: TextStyle(
                          fontFamily: AppTypography.fontFamily,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              )
            else
              ..._serverModels.map((m) {
                final isSelected = _preferredModel == m.id;
                return AppCard(
                  isSelected: isSelected,
                  margin: const EdgeInsets.only(bottom: AppSpacing.md),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                  onTap: () => _saveModel(m.id),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    m.name,
                                    style: TextStyle(
                                      fontFamily: AppTypography.fontFamily,
                                      fontSize: 13,
                                      fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                                      color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                                    ),
                                  ),
                                ),
                                if (m.tag.isNotEmpty) ...[
                                  const SizedBox(width: AppSpacing.sm),
                                  PillTag(
                                    label: m.tag,
                                    variant: isSelected ? PillTagVariant.solid : PillTagVariant.outline,
                                  ),
                                ],
                              ],
                            ),
                            if (m.desc.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                m.desc,
                                style: TextStyle(
                                  fontFamily: AppTypography.fontFamily,
                                  fontSize: 11,
                                  color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                                ),
                              ),
                            ],
                          ],
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

            // Section 5: Pipeline Preferences Toggles
            Text(
              'PIPELINE PREFERENCES',
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                children: [
                  SettingToggleTile(
                    title: 'Kinetic Subtitles',
                    description: 'Burn-in karaoke-style word emphasis on all vertical cuts',
                    value: _autoSubtitles,
                    onChanged: (val) {
                      setState(() => _autoSubtitles = val);
                      _saveToggle('pref_auto_subtitles', val);
                    },
                  ),
                  Divider(color: isDark ? AppColors.darkDivider : AppColors.lightDivider, height: 24),
                  SettingToggleTile(
                    title: '1080p Master Render',
                    description: 'Encode at maximum CRF 21 with high-profile libx264',
                    value: _highBitrate,
                    onChanged: (val) {
                      setState(() => _highBitrate = val);
                      _saveToggle('pref_high_bitrate', val);
                    },
                  ),
                  Divider(color: isDark ? AppColors.darkDivider : AppColors.lightDivider, height: 24),
                  SettingToggleTile(
                    title: 'Persistent Transcript Cache',
                    description: 'Reuse Whisper segments to reduce duplicate API queries',
                    value: _cacheTranscripts,
                    onChanged: (val) {
                      setState(() => _cacheTranscripts = val);
                      _saveToggle('pref_cache_transcripts', val);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // Section 6: Bantuan & Tentang Bot
            Text(
              'INFORMASI & BANTUAN (/help & /about)',
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Row(
                children: [
                  Expanded(
                    child: PrimaryTactileButton(
                      label: 'Panduan Bantuan',
                      icon: Icons.menu_book_rounded,
                      isSecondary: true,
                      onPressed: _showHelpDialog,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: PrimaryTactileButton(
                      label: 'Tentang OriontClip',
                      icon: Icons.info_outline_rounded,
                      isSecondary: true,
                      onPressed: _showAboutDialog,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // Section 7: Pemeliharaan
            Text(
              'PEMELIHARAAN',
              style: AppTypography.microHeader(isDark),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Row(
                children: [
                  Expanded(
                    child: PrimaryTactileButton(
                      label: 'Dashboard Server',
                      icon: Icons.open_in_new_rounded,
                      isSecondary: true,
                      onPressed: () => launchUrl(
                        Uri.parse(ApiConfig.instance.baseUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: PrimaryTactileButton(
                      label: 'Reset Cache',
                      icon: Icons.refresh_rounded,
                      isSecondary: true,
                      onPressed: _confirmResetData,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.hero),
          ],
        ),
      ),
    );
  }

  Widget _buildServerField({
    required TextEditingController controller,
    required bool obscure,
    required String hint,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
    VoidCallback? onToggleObscure,
  }) {
    final isDark = widget.isDarkMode;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
        borderRadius: BorderRadius.circular(AppRadius.input),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              style: TextStyle(
                fontFamily: AppTypography.fontFamily,
                fontSize: 13,
                color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
              ),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(
                  color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.25),
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          if (onToggleObscure != null)
            IconButton(
              icon: Icon(
                obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                size: 18,
                color: isDark ? Colors.white38 : Colors.black38,
              ),
              onPressed: onToggleObscure,
              tooltip: obscure ? 'Tampilkan Token' : 'Sembunyikan Token',
            ),
        ],
      ),
    );
  }
}
