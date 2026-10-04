// Smoke + REGRESI test untuk OriontClipper.
//
// (0) Smoke: semua tab body harus benar-benar TERLIHAT (bukan cuma ada di
//     widget tree) dan nol exception runtime.
//     Latar belakang bug: nav bawah pernah membuat ListView body bertinggi 0 px
//     (`alignment` pada AnimatedContainer nav memaksa item memenuhi tinggi
//     Scaffold), sehingga aplikasi web tampil blank di body sementara nav tetap
//     tergambar. Test lama hanya mengecek teks 'STUDIO'/'ENGINE' yang hidup di
//     bottomNavigationBar, jadi lolos meski body kosong. Assert di bawah
//     mengunci tinggi body > 0, marker teks unik tiap tab onstage, dan nol
//     exception.
//
// (a) REGRESI "pindah tab saat kurasi berjalan": progress (teks stage server)
//     harus TETAP ada di Studio setelah berpindah tab di tengah polling.
//     Sebelum diperbaiki, loop polling hidup di dalam _StudioScreenState sehingga
//     pindah tab (Studio di-dispose) menghapus progress. Sekarang JobTracker是
//     singleton di luar widget tree dan IndexedStack tidak meng-dispose Studio.
//     Test ini juga mengunci kontrak request kurasi (style{position,
//     highlight_color} + template_preset dari prefs) serta impor klip ke Katalog
//     + ClipJobMap saat job selesai.
//
// (b) REGRESI "reload saat kurasi berjalan": `active_job_v1` yang tersimpan
//     harus dipulihkan saat boot (progress tampil) lalu di-poll sampai done dan
//     klipnya diimpor.
//
// (c) REGRESI "reload saat render berjalan": klip dengan renderStatus
//     queued/rendering + `clip_job_map_v1` harus diambil kembali oleh
//     RenderResume saat boot, di-update (renderStatus/isRendered/videoUrl) dan
//     dipersisten — tanpa menyisakan poller ganda.
//
// (d) REGRESI markup highlight (*KATA* / [KATA]) tidak boleh tampil sebagai
//     karakter literal di kanvas simulasi preview.
//
// Catatan jaringan: semua akses API lewat seam [ApiService.installTestClient]
// (client http injeksi-test). Produksi tidak pernah memanggilnya, sehingga
// client default (http.Client sungguhan) tetap dipakai.
//
// Catatan timing: di flutter_test timer memang fiktif (pump maju-jalankan
// Future.delayed), tapi `DateTime.now()` TIDAK difake. Karena itu test TIDAK
// balapan dengan polling backoff: FakeApiClient menahan job di status
// non-terminal sampai [FakeApiClient.releaseDone] dipanggil, jadi urutan event
// sepenuhnya deterministik.
//
// Catatan pumpAndSettle: Studio/Katalog menampilkan CircularProgressIndicator
// (animasi tak berbatas) selama job/render berjalan. pumpAndSettle dipanggil
// HANYA setelah state idle, kalau tidak test gagal karena never-settle.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:oriont_clipper/components/clip_preview_dialog.dart';
import 'package:oriont_clipper/components/pill_tag.dart';
import 'package:oriont_clipper/main.dart';
import 'package:oriont_clipper/models/clip_item.dart';
import 'package:oriont_clipper/screens/settings_screen.dart';
import 'package:oriont_clipper/services/api_service.dart';
import 'package:oriont_clipper/services/job_tracker.dart';
import 'package:oriont_clipper/theme/app_theme.dart';

/// Klip dengan SEMUA field kontrak /v1 (lihat CLIP_KEYS di
/// tests/probe_api_server.py) supaya ClipItem.fromJson tidak menebak.
Map<String, dynamic> fakeClipJson({
  required String jobId,
  int rank = 1,
  String renderStatus = 'none',
  String? videoUrl,
  String? thumbnailUrl,
  int? index,
  bool? renderable,
  String complianceStatus = 'COMPLIANT',
}) {
  return <String, dynamic>{
    'id': '${jobId}_$rank',
    'hook': 'RAHASIA 1% KREATOR YANG *NGGAK PERNAH* DIBOCORIN',
    'topic': 'Konsistensi Konten',
    'duration': '00:32',
    'timestamp': '01:00 - 01:32',
    'score': 93,
    'caption': 'Volume kerja mengalahkan kesempurnaan. #fyp #shorts',
    'preset': 'CAPCUT EDITORIAL',
    'sourceTitle': 'Podcast Konsistensi 2026',
    'script': 'Kuncinya sederhana: volume kerja mengalahkan kesempurnaan.',
    'complianceStatus': complianceStatus,
    'complianceNote': 'Sesuai panduan konten viral',
    'highlightColor': '#00e5ff',
    'position': 'lower',
    'isRendered': renderStatus == 'done',
    'createdAt': DateTime.now().toIso8601String(),
    'start': 60.0,
    'end': 92.0,
    'rank': rank,
    'reason': 'Punchline penutup, konteks utuh.',
    'bgmMood': 'uplifting',
    'riskFlags': <String>[],
    'campaignNotes': <String>[],
    'sourceUrl': 'https://youtube.com/watch?v=fake',
    'videoUrl': videoUrl,
    'renderStatus': renderStatus,
    // v1.1 (kontrak server): index 1-based, thumbnail, renderable.
    'index': ?index,
    'thumbnailUrl': ?thumbnailUrl,
    'renderable': ?renderable,
  };
}

/// Pseudo-server /v1: health, models, campaign-policy, POST curation, POST
/// render, dan GET status job.
///
/// Balas GET /v1/jobs/{id} memakai [repliesByJob] berurutan (balasan terakhir
/// dipakai berulang selama job belum di-release), lalu balas [doneReplies]
/// setelah [releaseDone] dipanggil. Dengan begini test tidak bergantung pada
/// kecepatan backoff polling.
class FakeApiClient extends http.BaseClient {
  FakeApiClient({
    required this.curationJobId,
    required this.repliesByJob,
    this.doneReplies = const <String, Map<String, dynamic>>{},
  });

  final String curationJobId;
  final Map<String, List<Map<String, dynamic>>> repliesByJob;
  final Map<String, Map<String, dynamic>> doneReplies;
  final Set<String> _released = <String>{};

  /// Log "METHOD /path" setiap request yang masuk.
  final List<String> calls = <String>[];

  /// Body JSON yang dikirim ke POST /v1/jobs/curation.
  final List<Map<String, dynamic>> curationBodies = <Map<String, dynamic>>[];

  /// jobId yang dibatalkan (POST /v1/jobs/{id}/cancel) & dihapus
  /// (DELETE /v1/jobs/{id}) — untuk mengunci alur reset & tombol Batalkan.
  final List<String> cancelCalls = <String>[];
  final List<String> deleteJobCalls = <String>[];

  final Map<String, int> _pollCount = <String, int>{};

  void releaseDone(String jobId) => _released.add(jobId);

  int pollsFor(String jobId) => _pollCount[jobId] ?? 0;

  int get jobPollCalls => calls.where((c) => c.startsWith('GET /v1/jobs/')).length;

  Map<String, dynamic> _jobReply(String jobId) {
    if (_released.contains(jobId) && doneReplies.containsKey(jobId)) {
      return <String, dynamic>{...doneReplies[jobId]!, 'jobId': jobId};
    }
    final list = repliesByJob[jobId];
    if (list == null || list.isEmpty) {
      return <String, dynamic>{
        'status': 'running',
        'stage': 'Bekerja...',
        'progress': 0.2,
        'clips': <Object>[],
      };
    }
    final i = _pollCount[jobId] ?? 0;
    _pollCount[jobId] = i + 1;
    final reply = list[i < list.length ? i : list.length - 1];
    return <String, dynamic>{...reply, 'jobId': jobId};
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final method = request.method;
    final path = request.url.path;
    final segments = request.url.pathSegments;
    calls.add('$method $path');

    final body = request is http.Request ? request.body : '';

    Object? payload;
    var status = 200;

    if (method == 'POST' && path.endsWith('/v1/jobs/curation')) {
      curationBodies.add(
        body.isEmpty
            ? <String, dynamic>{}
            : (jsonDecode(body) as Map<String, dynamic>),
      );
      payload = <String, dynamic>{'jobId': curationJobId};
    } else if (method == 'POST' &&
        segments.length == 4 &&
        segments[1] == 'jobs' &&
        segments[3] == 'cancel') {
      // POST /v1/jobs/{jobId}/cancel (v1.1)
      cancelCalls.add(segments[2]);
      payload = <String, dynamic>{'ok': true, 'status': 'cancelled'};
    } else if (method == 'DELETE' &&
        segments.length == 3 &&
        segments[1] == 'jobs') {
      // DELETE /v1/jobs/{jobId}
      deleteJobCalls.add(segments[2]);
      payload = <String, dynamic>{'ok': true};
    } else if (path.endsWith('/v1/cookies')) {
      // GET/POST/DELETE /v1/cookies (v1.1) — status jujur "belum ada".
      payload = <String, dynamic>{'hasCookies': false, 'updated': null};
    } else if (method == 'GET' && path.endsWith('/v1/health')) {
      payload = <String, dynamic>{
        'ok': true,
        'version': 'fake-1.0',
        'busy': false,
        'uptime_s': 12.5,
      };
    } else if (method == 'GET' && path.endsWith('/v1/models')) {
      payload = <String, dynamic>{
        'models': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'fake-model',
            'name': 'Fake Model',
            'tag': 'test',
            'desc': 'reply test',
          },
        ],
        'default': 'fake-model',
      };
    } else if (path.endsWith('/v1/campaign-policy')) {
      payload = <String, dynamic>{'isCustom': false, 'rulesText': ''};
    } else if (method == 'GET' &&
        segments.length == 3 &&
        segments[1] == 'jobs') {
      // GET /v1/jobs/{jobId}
      payload = _jobReply(segments[2]);
    } else if (method == 'POST' &&
        segments.length == 6 &&
        segments[2] == 'jobs' &&
        segments[5] == 'render') {
      // POST /v1/jobs/{jobId}/clips/{index}/render
      payload = <String, dynamic>{'ok': true};
    } else if (method == 'POST' &&
        segments.length == 4 &&
        segments[2] == 'jobs' &&
        segments[3] == 'render-all') {
      payload = <String, dynamic>{'rendered': <int>[1]};
    } else if (method == 'GET' && path.endsWith('/v1/media/metadata')) {
      payload = <String, dynamic>{'title': 'Judul Fake', 'author': 'Kreator'};
    } else {
      status = 404;
      payload = <String, dynamic>{
        'error': 'FakeApiClient: rute $method $path tidak dikenal',
      };
    }

    final bytes = utf8.encode(jsonEncode(payload));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      status,
      request: request,
      headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
      contentLength: bytes.length,
    );
  }
}

// ── Helper pompa ─────────────────────────────────────────────────────────────

const Key kStatusKey = ValueKey<String>('studio_job_status');

Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _pump(WidgetTester tester, {int times = 1, int ms = 50}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(Duration(milliseconds: ms));
  }
}

/// Teks kartu progress Studio, atau null bila kartu belum/tidak onstage.
String? _statusText(WidgetTester tester) {
  final finder = find.byKey(kStatusKey);
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<Text>(finder).data ?? '';
}

/// Pompa sampai [condition] true. Jangan pakai expect di dalam condition:
/// kegagalan expect akan langsung menggagalkan test alih-alih dicoba lagi.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxPumps = 400,
  int stepMs = 50,
  String reason = 'kondisi',
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (condition()) return;
    await tester.pump(Duration(milliseconds: stepMs));
  }
  fail('$reason tidak tercapai dalam $maxPumps pump x ${stepMs}ms.');
}

/// Akhiri test dengan aman: snackbar memakai Timer dismiss 4 detik yang tetap
/// pending setelah animasi selesai, dan flutter_test menggagalakan test bila
/// masih ada Timer saat pohon dibuang. Pompa maju beberapa kali lebih panjang
/// dari durasi snackbar terlama (4s) untuk membuang semua timer non-periodik.
Future<void> _finish(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(seconds: 6));
  }
  await tester.pumpAndSettle();
}

/// Viewport default flutter_test adalah 800x600. Di lebar > 500 aplikasi
/// dibungkus frame HP (maks ~880 px tinggi) sehingga tombol GENERATE & kartu
/// progress Studio sering berada DI BAWAH lipatan ListView (lazy → tidak pernah
/// dibangun) dan finder tidak menemukannya. 420x2000 logis membuat ResponsivePhoneShell
/// melewati jalur "tanpa frame" (<= 500) dengan tinggi lega, jadi seluruh isi
/// Studio terbangun dan alur nyata bisa dijalankan tanpa scroll.
Future<void> _tallViewport(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// Viewport lega membuat ListView Studio membangun baris yang biasanya tersembunyi
/// di bawah lipatan ( STYLE&HOOK, header HASIL RENDER, dst ). Di produksi fontnya
/// 'Segoe UI'; di flutter_test font itu tidak ada sehingga jatuh ke **Ahem** —
/// tiap glyph = kotak selebar fontSize, jadi teks terukur jauh lebih lebar dan
/// baris-baris tadi "A RenderFlex overflowed by Npx". Itu artefak font test,
/// BUKAN bug layout aplikasi (aplikasi tampil normal di browser).
///
/// Karena lebar konten dibatasi <= 420px oleh ResponsivePhoneShell, overflow
/// Ahem ini tidak bisa dihindari lewat ukuran viewport apa pun. Helper ini
/// memasang penyaring FlutterError yang MENGABAIKAN pesan overflow dan tetap
/// mengumpulkan (lalu menuntut kosong) semua exception lain — jadi regresi nyata
/// tidak lolos senyap.
void _silenceAhemOverflow() {
  final previous = FlutterError.onError;
  final realErrors = <FlutterErrorDetails>[];
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('RenderFlex overflowed')) return;
    realErrors.add(details);
  };
  addTearDown(() {
    FlutterError.onError = previous;
    // HANYA string exception: FlutterErrorDetails.toString() menelusuri render
    // object yang sudah disposed saat teardown; crash di jalur itu menutupi
    // sebab asli.
    final strings = realErrors
        .map((e) {
          try {
            return e.exception.toString();
          } catch (_) {
            return '<details render failed: ${e.exception.runtimeType}>';
          }
        })
        .take(6)
        .toList();
    expect(strings, isEmpty,
        reason: 'Exception nyata (non-overflow) terlempar');
  });
}

List<ClipItem> _clipsFrom(SharedPreferences prefs) {
  final raw = prefs.getString('saved_clips_v1');
  if (raw == null || raw.isEmpty) return <ClipItem>[];
  final decoded = jsonDecode(raw);
  if (decoded is! List) return <ClipItem>[];
  return decoded
      .map((m) =>
          ClipItem.fromJson((m is Map) ? m.cast<String, dynamic>() : const {}))
      .toList();
}

/// Section PEMELIHARAAN Settings ada jauh di bawah lipatan dan ListView
/// dibangun malas → target harus di-scroll dulu sebelum tap.
Future<void> _scrollInSettings(WidgetTester tester, Finder target) async {
  final scrollable = find
      .descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable))
      .first;
  await tester.scrollUntilVisible(target, 260, scrollable: scrollable);
  await tester.pump();
}

void main() {
  late FakeApiClient fake;

  void installFake({
    String jobId = 'fakejob',
    Map<String, List<Map<String, dynamic>>> replies =
        const <String, List<Map<String, dynamic>>>{},
    Map<String, Map<String, dynamic>> done =
        const <String, Map<String, dynamic>>{},
  }) {
    fake = FakeApiClient(
      curationJobId: jobId,
      repliesByJob: replies,
      doneReplies: done,
    );
    ApiService.installTestClient(fake);
  }

  /// Set delay polling saja (in-memory pada singleton). TIDAK menyentuh prefs,
  /// jadi aman dipanggil SESUDAH setMockInitialValues tanpa menghapus job/clips
  /// yang di-seed (JobTracker.resetForTest() sendiri menghapus `active_job_v1`).
  void configureDelays({int? trackerDelayMs, int? renderDelayMs}) {
    if (trackerDelayMs != null) {
      JobTracker.instance.initialDelayMs = trackerDelayMs;
      JobTracker.instance.maxDelayMs = trackerDelayMs * 2;
    }
    if (renderDelayMs != null) {
      RenderResume.pollDelayMs = renderDelayMs;
      RenderResume.maxPollDelayMs = renderDelayMs * 2;
    }
  }

  /// JobTracker & RenderResume hidup lintas test dalam satu file (singleton /
  /// static), jadi state + prefs dibersihkan total di tiap setUp.
  Future<void> resetState({
    int trackerDelayMs = 10,
    int renderDelayMs = 10,
  }) async {
    RenderResume.resetForTest();
    RenderResume.maxWait = const Duration(seconds: 30);
    await JobTracker.instance.resetForTest();
    JobTracker.instance.pollDeadline = const Duration(seconds: 30);
    configureDelays(
      trackerDelayMs: trackerDelayMs,
      renderDelayMs: renderDelayMs,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    installFake();
    await resetState();
  });

  tearDown(() {
    // Kembali ke default produksi (client http sungguhan).
    ApiService.installTestClient(http.Client());
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('Smoke: semua tab visible (guard bug blank-body)', () {
    testWidgets('Oriont Clipper App smoke test', (WidgetTester tester) async {
      final caught = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => caught.add(details);
      try {
        SharedPreferences.setMockInitialValues({});

        await tester.pumpWidget(const OriontClipperApp());
        await _settle(tester);

        expect(find.byType(OriontClipperApp), findsOneWidget);

        // Nav bawah tetap utuh & bisa disentuh.
        for (final label in ['STUDIO', 'CATALOG', 'STYLE', 'ENGINE']) {
          expect(find.text(label), findsOneWidget, reason: 'Nav $label hilang');
        }

        // Body (bukan nav) harus punya tinggi nyata — inti guard bug blank-body.
        final listView = find.byType(ListView);
        expect(listView, findsWidgets);
        final bodyRo = listView.first.evaluate().first.renderObject as RenderBox;
        expect(bodyRo.size.height, greaterThan(200),
            reason:
                'Tinggi body ListView = ${bodyRo.size.height} (bug blank-body!)');

        // 0) STUDIO — layar pertama.
        expect(find.textContaining('JENIS SUMBER VIDEO'), findsOneWidget,
            reason: 'Header sumber Studio tidak visible');

        // 1) CATALOG
        await tester.tap(find.text('CATALOG'));
        await _settle(tester, frames: 4);
        expect(find.textContaining('Curated'), findsOneWidget,
            reason: 'Body Catalog tidak visible');

        // 2) STYLE
        await tester.tap(find.text('STYLE'));
        await _settle(tester, frames: 4);
        expect(find.textContaining('Hook Studio'), findsOneWidget,
            reason: 'Body Style tidak visible');

        // 3) SETTINGS / ENGINE
        await tester.tap(find.text('ENGINE'));
        await _settle(tester, frames: 4);
        expect(find.textContaining('SERVER ORIONTCLIPPER'), findsOneWidget,
            reason: 'Section SERVER di Settings tidak visible');

        // Semua tab harus build & layout tanpa exception runtime.
        expect(caught, isEmpty,
            reason:
                'Ada exception runtime: ${caught.map((c) => c.exception).toList()}');
      } finally {
        FlutterError.onError = previous;
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('Regresi: job kurasi bertahan lintas tab & reload', () {
    testWidgets(
        '(a) pindah tab saat polling berjalan tidak menghapus progress; '
        'request kurasi memakai style dari prefs; klip masuk katalog + job map',
        (WidgetTester tester) async {
      _silenceAhemOverflow();
      // Style tersimpan (prefs) HARUS diteruskan ke request, bukan hardcode.
      // Reset DI HULU (membersihkan singleton), baru seed prefs terakhir agar
      // resetForTest() tidak menghapus `active_job_v1` yang ingin di-seed.
      await resetState(trackerDelayMs: 40);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_clips_v1': '[]', // run sudah pernah terjadi → tanpa klip contoh
        'hook_style_preset': 'capcut',
        'hook_style_pos': 'lower',
        'hook_style_color': '#00e5ff',
        'campaign_is_custom': false,
        'campaign_rules_text': '',
      });

      installFake(
        jobId: 'fakejob',
        // Reply TERAKHIR dipakai berulang sampai releaseDone → stage 'Membaca
        // transkrip' tetap terpasang selama kita berpindah tab (deterministik,
        // tidak balapan dengan jumlah poll yang sudah jalan).
        replies: <String, List<Map<String, dynamic>>>{
          'fakejob': <Map<String, dynamic>>[
            <String, dynamic>{
              'status': 'queued',
              'stage': 'Mengantri di server...',
              'progress': 0.1,
              'clips': <Object>[],
            },
            <String, dynamic>{
              'status': 'running',
              'stage': 'Membaca transkrip video sumber...',
              'progress': 0.4,
              'clips': <Object>[],
            },
          ],
        },
        done: <String, Map<String, dynamic>>{
          'fakejob': <String, dynamic>{
            'status': 'done',
            'stage': 'Selesai',
            'progress': 1.0,
            'clips': <Map<String, dynamic>>[
              fakeClipJson(jobId: 'fakejob'),
            ],
          },
        },
      );

      await _tallViewport(tester);
      await tester.pumpWidget(const OriontClipperApp());
      await _settle(tester);

      // --- Alur Studio nyata: isi link → Generate → konfirmasi campaign.
      await tester.enterText(
          find.byType(TextField).first, 'https://youtu.be/fake123');
      await _pump(tester, times: 2);

      await tester.tap(find.textContaining('GENERATE VIRAL SHORTS'));
      await _settle(tester, frames: 3);
      final confirm = find.textContaining('MULAI KURASI');
      expect(confirm, findsOneWidget, reason: 'Sheet aturan campaign tidak muncul');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);

      // --- Progress harus mencapai stage "running" dari server.
      await _pumpUntil(
        tester,
        () => (_statusText(tester) ?? '').contains('Membaca transkrip'),
        reason: 'stage running tampil di Studio',
      );
      expect(_statusText(tester), contains('Membaca transkrip'),
          reason: 'Teks stage server tidak ditampilkan apa adanya');

      // ── INTI BUG: pindah tab ke CATALOG di tengah polling, lalu kembali.
      await tester.tap(find.text('CATALOG'));
      await _settle(tester, frames: 4);
      expect(find.textContaining('Curated'), findsOneWidget,
          reason: 'Katalog tidak tampil setelah pindah tab');

      await tester.tap(find.text('STUDIO'));
      await _settle(tester, frames: 4);

      // Job masih berjalan dan stage-nya masih terpasang di UI.
      expect(JobTracker.instance.isBusy, isTrue,
          reason: 'JobTracker kehilangan state saat pindah tab');
      expect(find.byKey(kStatusKey), findsOneWidget,
          reason: 'Kartu progress hilang setelah pindah tab (regresi bug utama!)');
      expect(_statusText(tester), isNot(isEmpty),
          reason: 'Kartu progress tampil tapi tanpa teks stage');
      expect(find.textContaining('GENERATE VIRAL SHORTS'), findsNothing,
          reason: 'Tombol generate harus tetap terkunci selama job berjalan');

      // --- Kontrak request kurasi: style{position, highlight_color} + preset.
      expect(fake.curationBodies, hasLength(1),
          reason: 'POST /v1/jobs/curation tidak dikirim sekali pun');
      final sent = fake.curationBodies.single;
      final style = sent['style'] as Map<String, dynamic>;
      expect(style['position'], 'lower', reason: 'position bukan dari prefs');
      expect(style['highlight_color'], '#00e5ff',
          reason: 'highlight_color bukan dari prefs');
      expect(sent['template_preset'], 'capcut',
          reason: 'template_preset masih hardcode hormozi');
      expect((sent['source'] as Map<String, dynamic>)['url'],
          'https://youtu.be/fake123');

      // --- Baru izinkan job selesai: klip harus masuk walau user pindah tab.
      final prefs = await SharedPreferences.getInstance();
      fake.releaseDone('fakejob');
      await _pumpUntil(tester, () => !JobTracker.instance.isBusy,
          reason: 'JobTracker menyelesaikan job done');

      expect(JobTracker.instance.lastDeliveryJobId, 'fakejob');
      expect(JobTracker.instance.lastDeliveryClips, hasLength(1));
      expect(prefs.getString(JobTracker.storageKey), isNull,
          reason: 'active_job_v1 harus dibersihkan setelah selesai');

      final savedIds = _clipsFrom(prefs).map((c) => c.id).toList();
      expect(savedIds, contains('fakejob_1'),
          reason: 'Klip hasil kurasi tidak dipersisten ke katalog');
      expect((await ClipJobMap.load())['fakejob_1']?.jobId, 'fakejob',
          reason: 'ClipJobMap tidak menyimpan clipId -> jobId');

      // Shell melompat otomatis ke Katalog saat user masih di Studio; di sini
      // kita sudah pernah pindah tab, jadi cukup pastikan klip-nya onstage.
      await _pumpUntil(
        tester,
        () => find.textContaining('KONSISTENSI KONTEN').evaluate().isNotEmpty,
        reason: 'klip hasil kurasi tampil di Katalog',
      );
      expect(fake.pollsFor('fakejob'), greaterThanOrEqualTo(3),
          reason: 'Polling tidak berjalan sampai selesai');

      await _finish(tester);
    });

    testWidgets(
        '(b) reload/browser restart: active_job_v1 dipulihkan, stage tampil, '
        'job di-poll ulang dan klip diimpor', (WidgetTester tester) async {
      _silenceAhemOverflow();
      final nowIso = DateTime.now().toIso8601String();
      // Reset DI HULU dulu: JobTracker.resetForTest() menghapus `active_job_v1`,
      // jadi ia tidak boleh dijalankan setelah seed.
      await resetState(trackerDelayMs: 300);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_clips_v1': '[]',
        'active_job_v1': jsonEncode(<String, dynamic>{
          'jobId': 'resumejob',
          'sourceInputText': 'https://youtu.be/resumed',
          'status': 'running',
          'stage': 'Memulihkan job dari server...',
          'progress': 0.42,
          'startedAt': nowIso,
          'updatedAt': nowIso,
        }),
      });

      installFake(
        jobId: 'resumejob',
        replies: <String, List<Map<String, dynamic>>>{
          'resumejob': <Map<String, dynamic>>[
            <String, dynamic>{
              'status': 'running',
              'stage': 'Menyusun hook & memilih momen emas...',
              'progress': 0.66,
              'clips': <Object>[],
            },
          ],
        },
        done: <String, Map<String, dynamic>>{
          'resumejob': <String, dynamic>{
            'status': 'done',
            'stage': 'Selesai',
            'progress': 1.0,
            'clips': <Map<String, dynamic>>[
              fakeClipJson(jobId: 'resumejob'),
            ],
          },
        },
      );

      await _tallViewport(tester);
      await tester.pumpWidget(const OriontClipperApp());

      // Progress tersimpan langsung tampil (restore) — belum ada request job.
      await _pumpUntil(
        tester,
        () => find.byKey(kStatusKey).evaluate().isNotEmpty,
        maxPumps: 20,
        stepMs: 10,
        reason: 'kartu progress hasil restore',
      );
      expect(_statusText(tester), contains('Memulihkan job dari server'),
          reason: 'Stage dari active_job_v1 tidak dipulihkan ke UI');
      expect(JobTracker.instance.jobId, 'resumejob');
      expect(JobTracker.instance.progress, closeTo(0.42, 0.001));
      expect(fake.pollsFor('resumejob'), 0,
          reason: 'Restore tidak boleh memicu polling sebelum frame pertama');

      // ...lalu polling disambung dan maju sesuai server.
      await _pumpUntil(
        tester,
        () => (_statusText(tester) ?? '').contains('Menyusun hook'),
        reason: 'polling tidak disambung setelah restore',
      );
      expect(fake.pollsFor('resumejob'), greaterThan(0),
          reason: 'Resume harus benar-benar memanggil GET /v1/jobs/{id}');

      final prefs = await SharedPreferences.getInstance();
      fake.releaseDone('resumejob');
      await _pumpUntil(tester, () => !JobTracker.instance.isBusy,
          reason: 'job resume selesai');

      expect(prefs.getString(JobTracker.storageKey), isNull,
          reason: 'active_job_v1 harus dibersihkan setelah done');
      expect(_clipsFrom(prefs).map((c) => c.id), contains('resumejob_1'),
          reason: 'Klip hasil resume tidak diimpor ke katalog');
      expect((await ClipJobMap.load())['resumejob_1']?.jobId, 'resumejob');

      await _finish(tester);
    });

    testWidgets(
        '(c) reload dengan render tertinggal: RenderResume menyelesaikan klip '
        'dan tidak menyisakan poller ganda', (WidgetTester tester) async {
      _silenceAhemOverflow();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_clips_v1': jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'renderjob_1',
            'hook': 'Klip yang membeku di Merender...',
            'topic': 'Render Latar',
            'duration': '00:28',
            'score': 88,
            'caption': 'caption',
            'preset': 'HORMOZI IMPACT',
            'renderStatus': 'queued',
            'isRendered': false,
          },
        ]),
        'clip_job_map_v1':
            jsonEncode(<String, String>{'renderjob_1': 'renderjob'}),
      });
      await resetState(renderDelayMs: 30);

      installFake(
        jobId: 'renderjob',
        replies: <String, List<Map<String, dynamic>>>{
          'renderjob': <Map<String, dynamic>>[
            <String, dynamic>{
              'status': 'running',
              'stage': 'Merender klip 1...',
              'progress': 0.5,
              'clips': <Map<String, dynamic>>[
                fakeClipJson(jobId: 'renderjob', renderStatus: 'rendering'),
              ],
            },
          ],
        },
        done: <String, Map<String, dynamic>>{
          'renderjob': <String, dynamic>{
            'status': 'done',
            'stage': 'Selesai',
            'progress': 1.0,
            'clips': <Map<String, dynamic>>[
              fakeClipJson(
                jobId: 'renderjob',
                renderStatus: 'done',
                videoUrl: '/v1/media/renderjob/clip_1.mp4',
              ),
            ],
          },
        },
      );

      final prefs = await SharedPreferences.getInstance();

      await _tallViewport(tester);
      await tester.pumpWidget(const OriontClipperApp());

      // Klip masih tertunda → belum ada perubahan, tapi render di-poll lagi.
      await _pumpUntil(
        tester,
        () => fake.calls.contains('GET /v1/jobs/renderjob'),
        reason: 'RenderResume tidak menyambung poll render saat boot',
      );
      expect(_clipsFrom(prefs).single.renderStatus, 'queued',
          reason: 'Klip sudah dianggap selesai padahal server belum done');

      // Server menyelesaikan render → status, isRendered, videoUrl dipersisten.
      fake.releaseDone('renderjob');
      await _pumpUntil(
        tester,
        () {
          final clips = _clipsFrom(prefs);
          return clips.isNotEmpty &&
              clips.single.renderStatus == 'done' &&
              clips.single.isRendered &&
              (clips.single.videoUrl ?? '').isNotEmpty;
        },
        reason: 'update render latar dipersisten',
      );

      final updated = _clipsFrom(prefs).single;
      expect(updated.videoUrl, contains('/v1/media/renderjob/clip_1.mp4'),
          reason: 'videoUrl hasil render latar tidak dipersisten');

      // ── Tidak ada poller ganda/tersisa: call outstanding() berikutnya (klip
      //    sudah done) tidak boleh memicu request job baru, dan jobId harus
      //    sudah dilepas supaya RenderActions bisa claim lagi.
      final callsBefore = fake.jobPollCalls;
      await RenderResume.outstanding(clips: _clipsFrom(prefs), onUpdated: (_) {});
      expect(fake.jobPollCalls, callsBefore,
          reason: 'RenderResume membuat poller untuk klip yang sudah selesai');
      expect(RenderResume.claim('renderjob'), isTrue,
          reason: 'RenderResume tidak melepas claim → poller ganda di job sama');
      RenderResume.release('renderjob');

      await _finish(tester);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('Regresi: markup highlight di kanvas simulasi preview', () {
    testWidgets('(d) *KATA* / [KATA] tidak tampil sebagai karakter literal',
        (WidgetTester tester) async {
      _silenceAhemOverflow();
      const raw = 'KUNCINYA *VOLUME KERJA* mengalahkan [kesempurnaan] hari ini';
      expect(stripHookMarkup(raw),
          'KUNCINYA VOLUME KERJA mengalahkan kesempurnaan hari ini');

      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_clips_v1': '[]',
      });

      await tester.pumpWidget(const OriontClipperApp());
      await _settle(tester);

      final clip = ClipItem.fromJson(<String, dynamic>{
        'id': 'markup_1',
        'hook': 'RAHASIA *NGGAK PERNAH* DIBOCORIN',
        'topic': 'Markup',
        'duration': '00:20',
        'score': 90,
        'caption': 'caption',
        'preset': 'CAPCUT EDITORIAL',
        'script': raw,
      });

      // Konteks harus di bawah Navigator (sheet = route), jadi pakai elemen
      // salah satu layar, bukan elemen root aplikasi.
      ClipPreviewDialog.show(
        tester.element(find.textContaining('JENIS SUMBER VIDEO')),
        clip,
        true,
      );
      await _pump(tester, times: 6, ms: 100);
      final sheet = find.byType(ClipPreviewDialog);
      expect(sheet, findsOneWidget);
      expect(find.textContaining('Live Vertical Preview'), findsOneWidget,
          reason: 'Sheet preview 9:16 tidak terbuka');

      // Kumpulkan SEMUA teks dialog seiring kanvas kinetic maju (timer 350ms,
      // kata dipecah per 4). Scan HANYA di dalam dialog: kartu Studio di bawah
      // sheet masih menampilkan hook mentah (dengan marker) dan memang tidak
      // boleh di-strip di sana — yang dituntut regresi ini hanyalah kanvas.
      final seen = <String>{};
      final offenders = <String>[];
      for (var round = 0; round < 24; round++) {
        await tester.pump(const Duration(milliseconds: 100));
        for (final found in find
            .descendant(of: sheet, matching: find.byType(Text))
            .evaluate()) {
          final data = (found.widget as Text).data ?? '';
          seen.add(data);
          if (data.contains('*') || data.contains('[') || data.contains(']')) {
            offenders.add(data);
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'Markup highlight bocor ke kanvas simulasi: $offenders');
      // Kata hasil strip tetap tampil utuh (kanvas kinetic meng-caps tiap kata):
      // *VOLUME KERJA* → 'VOLUME' + 'KERJA', [kesempurnaan] → 'KESEMPURNAAN'.
      for (final word in <String>['VOLUME', 'KERJA', 'KESEMPURNAAN']) {
        expect(seen, contains(word),
            reason: 'Kata hasil strip "$word" hilang dari kanvas: $seen');
      }

      // Tutup sheet → Timer.periodic + AnimationController preview dibuang,
      // baru boleh settle.
      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await _finish(tester);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('Regresi UX fix spec (item 1-14)', () {
    testWidgets('(e) badge compliance NONE tampil netral, bukan oranye alarm',
        (WidgetTester tester) async {
      _silenceAhemOverflow();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_clips_v1': jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'nb_1',
            'hook': 'Klip tanpa aturan campaign',
            'topic': 'Bebas',
            'duration': '00:30',
            'score': 90,
            'caption': 'caption',
            'preset': 'CAPCUT EDITORIAL',
            'complianceStatus': 'NONE',
          },
        ]),
      });

      await _tallViewport(tester);
      await tester.pumpWidget(const OriontClipperApp());
      await _settle(tester);

      await tester.tap(find.text('CATALOG'));
      await _settle(tester, frames: 4);

      final badge = find.descendant(
        of: find.byType(ComplianceBadge),
        matching: find.text('BEBAS'),
      );
      expect(badge, findsOneWidget,
          reason: 'Status NONE harus jadi chip netral BEBAS');

      // '⚠ REVIEW' hanya untuk REVIEW sungguhan. (COCOKAN EKSAK: 'PREVIEW 9:16'
      // pada tombol katalog mengandung substring REVIEW, jadi textContaining
      // di sini akan mencari masalah, bukan memberi bukti.)
      expect(find.text('⚠ REVIEW'), findsNothing,
          reason: 'NONE tidak boleh tampil badge alarm REVIEW');

      // Warna: container badge harus bening (netral), BUKAN oranye statusWarning.
      final container = tester.widget<Container>(
        find.ancestor(
          of: badge,
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.child is Text,
          ),
        ),
      );
      final deco = container.decoration as BoxDecoration?;
      expect(deco?.color, isNot(equals(const Color(0xFFF59E0B))),
          reason: 'Badge NONE diwarnai oranye — itu alarm bohong');
      expect(deco?.color, Colors.transparent);

      // Kontrak warna tiga arah (satu sumber kebenaran untuk UI & gate).
      expect(complianceBadgeSpec('COMPLIANT')!.label, '✓ COMPLIANT');
      expect(complianceBadgeSpec('COMPLIANT')!.color, Colors.green);
      expect(complianceBadgeSpec('REVIEW')!.label, '⚠ REVIEW');
      expect(complianceBadgeSpec('REVIEW')!.color, AppColors.statusWarning);
      expect(complianceBadgeSpec('NONE')!.label, 'BEBAS');
      expect(complianceBadgeSpec('NONE')!.color, Colors.transparent);

      await _finish(tester);
    });

    testWidgets('(f) Batalkan: POST cancel, UI tahan sampai server konfirmasi, '
        'lalu bersih + snackbar jujur', (WidgetTester tester) async {
      _silenceAhemOverflow();
      final nowIso = DateTime.now().toIso8601String();
      await resetState(trackerDelayMs: 20);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_clips_v1': '[]',
        'active_job_v1': jsonEncode(<String, dynamic>{
          'jobId': 'canceljob',
          'sourceInputText': 'https://youtu.be/cancelme',
          'status': 'running',
          'stage': 'Membaca transkrip...',
          'progress': 0.3,
          'startedAt': nowIso,
          'updatedAt': nowIso,
        }),
      });

      installFake(
        jobId: 'canceljob',
        replies: <String, List<Map<String, dynamic>>>{
          'canceljob': <Map<String, dynamic>>[
            <String, dynamic>{
              'status': 'running',
              'stage': 'Membaca transkrip...',
              'progress': 0.3,
              'clips': <Object>[],
            },
          ],
        },
      );

      await _tallViewport(tester);
      await tester.pumpWidget(const OriontClipperApp());
      await _pumpUntil(
        tester,
        () => find.byKey(kStatusKey).evaluate().isNotEmpty,
        maxPumps: 40,
        reason: 'kartu progress restore',
      );
      expect(JobTracker.instance.isBusy, isTrue);

      await tester.tap(find.byKey(const ValueKey('studio_cancel_job')));
      await _pumpUntil(tester, () => fake.cancelCalls.contains('canceljob'),
          maxPumps: 40, reason: 'POST /v1/jobs/cancel terkirim');

      // Optimistis: setelah POST, UI MASIH menahan kartu (belum boleh klaim batal).
      expect(find.byKey(kStatusKey), findsOneWidget,
          reason: 'Pill progress tidak boleh hilang sebelum server konfirmasi');
      expect(JobTracker.instance.isBusy, isTrue);

      // Server mengonfirmasi 'cancelled' pada tick berikutnya.
      fake.repliesByJob['canceljob']!
        ..clear()
        ..add(<String, dynamic>{
          'status': 'cancelled',
          'stage': 'Job dibatalkan',
          'progress': 0.3,
          'clips': <Object>[],
        });
      await _pumpUntil(tester, () => !JobTracker.instance.isBusy,
          maxPumps: 200, reason: 'tracker membersihkan job setelah konfirmasi');
      await _pump(tester, times: 2);

      expect(find.byKey(kStatusKey), findsNothing,
          reason: 'Pill harus hilang setelah batal terkonfirmasi');
      expect(find.textContaining('dibatalkan', findRichText: true), findsWidgets,
          reason: 'Snackbar "Job dibatalkan" tidak tampil');

      await _finish(tester);
    });

    testWidgets('(g) reset dua opsi: "Hapus cache preferensi" menyimpan klip & '
        'token, tanpa DELETE job', (WidgetTester tester) async {
      _silenceAhemOverflow();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_clips_v1': jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'keep_1',
            'hook': 'Klip yang harus selamat',
            'topic': 'Tahan',
            'duration': '00:20',
            'score': 90,
            'caption': 'caption',
            'preset': 'CAPCUT EDITORIAL',
          },
        ]),
        'clip_job_map_v1': jsonEncode(
          <String, dynamic>{
            'keep_1': <String, dynamic>{'jobId': 'joba', 'index': 1},
          },
        ),
        'pref_auto_subtitles': false,
        'pref_high_bitrate': false,
        'pref_cache_transcripts': false,
        'pref_groq_model': 'model-lama',
        'api_base_url': 'http://127.0.0.1:8768',
        'api_token': 'tok-aman',
      });

      await _tallViewport(tester);
      await tester.pumpWidget(const OriontClipperApp());
      await _settle(tester);

      await tester.tap(find.text('ENGINE'));
      await _settle(tester, frames: 4);

      await _scrollInSettings(tester, find.textContaining('RESET CACHE'));
      await tester.tap(find.textContaining('RESET CACHE'));
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('reset_prefs_button')).evaluate().isNotEmpty,
        reason: 'dialog reset dua opsi muncul',
      );
      await tester.tap(find.byKey(const ValueKey('reset_prefs_button')));
      await _pump(tester, times: 6, ms: 80);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('saved_clips_v1'), contains('keep_1'),
          reason: 'Mode "cache preferensi" TIDAK boleh menghapus klip');
      expect(prefs.getString('api_token'), 'tok-aman',
          reason: 'token server harus tetap ada');
      expect(prefs.getString('api_base_url'), 'http://127.0.0.1:8768');
      expect(prefs.getBool('pref_auto_subtitles'), isNull,
          reason: 'pref pipeline tidak dibersihkan');
      // savePreferredModel('') menulis string kosong — yang penting model lama
      // hilang dan TIDAK ada pref lain yang ikut terhapus.
      expect(prefs.getString('pref_groq_model') ?? '', isEmpty);
      expect((await ClipJobMap.load()).containsKey('keep_1'), isTrue,
          reason: 'peta job tidak boleh hilang di mode cache-saja');
      expect(fake.deleteJobCalls, isEmpty,
          reason: 'mode ringan tidak boleh menghapus job server');

      await _finish(tester);
    });

    testWidgets('(h) reset "Hapus semua": klip + peta job hilang & DELETE '
        'dipanggil per jobId unik', (WidgetTester tester) async {
      _silenceAhemOverflow();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_clips_v1': jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'jobx_0',
            'hook': 'Klip satu',
            'topic': 'T',
            'duration': '00:20',
            'score': 90,
            'caption': 'c',
            'preset': 'CAPCUT EDITORIAL',
          },
          <String, dynamic>{
            'id': 'jobx_1',
            'hook': 'Klip dua',
            'topic': 'T',
            'duration': '00:20',
            'score': 90,
            'caption': 'c',
            'preset': 'CAPCUT EDITORIAL',
          },
          <String, dynamic>{
            'id': 'joby_0',
            'hook': 'Klip job lain',
            'topic': 'T',
            'duration': '00:20',
            'score': 90,
            'caption': 'c',
            'preset': 'CAPCUT EDITORIAL',
          },
        ]),
        'clip_job_map_v1': jsonEncode(<String, dynamic>{
          'jobx_0': <String, dynamic>{'jobId': 'jobx', 'index': 1},
          'jobx_1': <String, dynamic>{'jobId': 'jobx', 'index': 2},
          'joby_0': <String, dynamic>{'jobId': 'joby', 'index': 1},
        }),
        'api_token': 'tok-aman',
      });

      await _tallViewport(tester);
      await tester.pumpWidget(const OriontClipperApp());
      await _settle(tester);

      await tester.tap(find.text('ENGINE'));
      await _settle(tester, frames: 4);
      await _scrollInSettings(tester, find.textContaining('RESET CACHE'));
      await tester.tap(find.textContaining('RESET CACHE'));
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('reset_all_button')).evaluate().isNotEmpty,
        reason: 'dialog reset dua opsi muncul',
      );
      await tester.tap(find.byKey(const ValueKey('reset_all_button')));
      await _pump(tester, times: 8, ms: 80);

      final prefs = await SharedPreferences.getInstance();
      expect(_clipsFrom(prefs), isEmpty, reason: 'klip tidak dibersihkan');
      expect(prefs.getString('clip_job_map_v1'), isNull,
          reason: 'ClipJobMap.clearAll tidak dipanggil');
      expect(prefs.getString('api_token'), 'tok-aman',
          reason: 'token harus selamat bahkan di mode hapus semua');

      // Dua job unik → dua DELETE (jobx tercatat dua klip, tidak dobel).
      await _pumpUntil(
        tester,
        () => fake.deleteJobCalls.length >= 2,
        maxPumps: 60,
        reason: 'DELETE /v1/jobs per jobId unik',
      );
      expect(fake.deleteJobCalls.toSet(), <String>{'jobx', 'joby'});

      await _finish(tester);
    });

    testWidgets('(i) klip renderable=false: tombol render disabled + tooltip '
        'jujur di katalog', (WidgetTester tester) async {
      _silenceAhemOverflow();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_clips_v1': jsonEncode(<Map<String, dynamic>>[
          fakeClipJson(jobId: 'topicjob', renderable: false)
            ..['id'] = 'topicjob_0'
            ..['complianceStatus'] = 'NONE',
        ]),
      });

      await _tallViewport(tester);
      await tester.pumpWidget(const OriontClipperApp());
      await _settle(tester);

      await tester.tap(find.text('CATALOG'));
      await _settle(tester, frames: 4);

      final button = find.descendant(
        of: find.byKey(const ValueKey('catalog_render_topicjob_0')),
        matching: find.byType(ElevatedButton),
      );
      expect(button, findsOneWidget);
      final widget = tester.widget<ElevatedButton>(button);
      expect(widget.onPressed, isNull,
          reason: 'renderable=false harus disable, bukan error setelah tap');

      // Label jujur + badge TANPA VIDEO.
      expect(find.textContaining('TANPA VIDEO'), findsWidgets);

      await _finish(tester);
    });

    testWidgets('(j) batch terakhir tampil di Studio walau tanpa lompat tab, '
        'dan id-nya dipersisten untuk reload', (WidgetTester tester) async {
      _silenceAhemOverflow();
      final nowIso = DateTime.now().toIso8601String();
      await resetState(trackerDelayMs: 20);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_clips_v1': '[]',
        // Job sedang jalan saat user pindah tab → boot memulihkannya.
        'active_job_v1': jsonEncode(<String, dynamic>{
          'jobId': 'batchjob',
          'sourceInputText': 'https://youtu.be/batch',
          'status': 'running',
          'stage': 'Membaca transkrip...',
          'progress': 0.4,
          'startedAt': nowIso,
          'updatedAt': nowIso,
        }),
      });

      installFake(
        jobId: 'batchjob',
        replies: <String, List<Map<String, dynamic>>>{
          'batchjob': <Map<String, dynamic>>[
            <String, dynamic>{
              'status': 'running',
              'stage': 'Membaca transkrip...',
              'progress': 0.4,
              'clips': <Object>[],
            },
          ],
        },
        done: <String, Map<String, dynamic>>{
          'batchjob': <String, dynamic>{
            'status': 'done',
            'stage': 'Selesai',
            'progress': 1.0,
            'clips': <Map<String, dynamic>>[
              fakeClipJson(jobId: 'batchjob'),
            ],
          },
        },
      );

      await _tallViewport(tester);
      await tester.pumpWidget(const OriontClipperApp());
      await _settle(tester);

      // User SUDAH pindah tab sebelum job selesai → shell tidak boleh memaksa
      // lompat; Studio harus menampilkan "Batch terakhir (Job #batchjob)".
      await tester.tap(find.text('CATALOG'));
      await _settle(tester, frames: 4);

      final prefs = await SharedPreferences.getInstance();
      fake.releaseDone('batchjob');
      await _pumpUntil(tester, () => !JobTracker.instance.isBusy,
          maxPumps: 200, reason: 'job done');

      // Persist id batch (hanya id) untuk reload.
      await _pumpUntil(tester,
          () => (prefs.getStringList(JobTracker.lastBatchKey) ?? []).isNotEmpty,
          maxPumps: 60, reason: 'last_batch_v1 tersimpan');
      expect(prefs.getStringList(JobTracker.lastBatchKey), <String>['batchjob_1']);

      await tester.tap(find.text('STUDIO'));
      await _settle(tester, frames: 4);
      expect(find.textContaining('BATCH TERAKHIR (Job #batchjob'), findsOneWidget,
          reason: 'Studio tidak menampilkan batch terakhir');

      // ── Simulasi reload: pump app baru, hydrate dari prefs.
      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(tester, times: 4);
      // Kosongkan memori tracker TANPA menghapus prefs (reload sungguhan).
      JobTracker.instance.lastDeliveryClips = const [];
      JobTracker.instance.lastDeliveryJobId = null;

      await tester.pumpWidget(const OriontClipperApp());
      await _settle(tester);
      await tester.tap(find.text('STUDIO'));
      await _settle(tester, frames: 6);
      expect(find.textContaining('BATCH TERAKHIR (Job #batchjob'), findsOneWidget,
          reason: 'batch terakhir tidak dipulihkan dari last_batch_v1 saat boot');

      await _finish(tester);
    });

    testWidgets('(k) kontrak v1.1 clip: index & thumbnailUrl ter-decode; '
        'index server dipakai clipIndexOf', (WidgetTester tester) async {
      _silenceAhemOverflow();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_clips_v1': jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'thumbjob_0',
            'hook': 'Klip ber-thumbnail',
            'topic': 'T',
            'duration': '00:20',
            'score': 90,
            'caption': 'c',
            'preset': 'CAPCUT EDITORIAL',
            'index': 4,
            'renderable': true,
            'thumbnailUrl': '/v1/media/thumbjob/thumb_4.jpg',
          },
        ]),
      });

      await _tallViewport(tester);
      await tester.pumpWidget(const OriontClipperApp());
      await _settle(tester);

      final prefs = await SharedPreferences.getInstance();
      final clip = _clipsFrom(prefs).single;
      expect(clip.thumbnailUrl, contains('/v1/media/thumbjob/thumb_4.jpg'),
          reason: 'thumbnailUrl tidak didecode');
      expect(clip.renderIndex, 4, reason: 'index server (1-based) harus menang');
      expect(clip.renderable, isTrue,
          reason: 'tanpa field renderable default harus true');
      expect(clipIndexOf(clip), 4,
          reason: 'clipIndexOf harus memakai index server, bukan suffix id');

      await tester.tap(find.text('CATALOG'));
      await _settle(tester, frames: 4);
      // Jaringan test selalu gagal → errorBuilder placeholder (tidak crash,
      // tetap compact). Kehadiran slot thumbnail = Image.network ter-build.
      expect(find.byType(Image), findsWidgets,
          reason: 'thumbnailUrl tidak masuk slot 9:16 katalog');
      // Kegunaan jaringan test (400 dari HTTP mock) -> errorBuilder placeholder;
      // _silenceAhemOverflow sudah menuntut exception NON-overflow tetap kosong.

      await _finish(tester);
    });
  });
}
