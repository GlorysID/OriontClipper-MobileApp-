import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';

class CampaignPolicy {
  final bool isCustom;
  final String rulesText;

  const CampaignPolicy({
    this.isCustom = false,
    this.rulesText = '',
  });

  static Future<CampaignPolicy> load() async {
    final prefs = await SharedPreferences.getInstance();
    return CampaignPolicy(
      isCustom: prefs.getBool('campaign_is_custom') ?? false,
      rulesText: prefs.getString('campaign_rules_text') ?? '',
    );
  }

  static Future<void> save(bool isCustom, String rulesText) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('campaign_is_custom', isCustom);
    await prefs.setString('campaign_rules_text', rulesText.trim());
  }

  /// Kirim kebijakan lokal ke server (PUT /v1/campaign-policy).
  /// Gagal diam-diam (server bisa offline); preferensi lokal tetap jadi sumber truth.
  static Future<void> push() async {
    try {
      final policy = await load();
      await ApiService.shared.putCampaignPolicy(policy.isCustom, policy.rulesText);
    } catch (_) {
      // Server belum tersedia — abaikan, policy lokal tetap tersimpan.
    }
  }

  /// Tarik kebijakan dari server (GET /v1/campaign-policy) lalu sinkronkan ke lokal.
  static Future<CampaignPolicy?> pull() async {
    try {
      final data = await ApiService.shared.getCampaignPolicy();
      final isCustom = data['isCustom'] == true;
      final rulesText = data['rulesText']?.toString() ?? '';
      await save(isCustom, rulesText);
      return CampaignPolicy(isCustom: isCustom, rulesText: rulesText.trim());
    } catch (_) {
      return null;
    }
  }
}
