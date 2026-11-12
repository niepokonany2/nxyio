import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'firebase_options.dart';
import 'main.dart' hide main;

// ============================================================
//  START (iOS)
// ============================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firebaseReady = true;
  } catch (error) {
    debugPrint('Firebase nie jest skonfigurowany: $error');
  }
  await AppNotifications.init();
  await store.load();
  await IosScreenTime.refreshStatus();
  await IosScreenTime.setDeviceSettings(
      store.limitMinutes, store.notificationsEnabled);
  runApp(const BeOfflineIosApp());
}

// ============================================================
//  MOST DO SWIFT (Screen Time)
// ============================================================

class IosLimit {
  final String id;
  final int daily;
  final int session;
  final int wait;
  final int apps;
  final int categories;
  final int sessionsUsed;
  final bool dailyReached;

  const IosLimit({
    required this.id,
    required this.daily,
    required this.session,
    required this.wait,
    required this.apps,
    required this.categories,
    required this.sessionsUsed,
    required this.dailyReached,
  });

  int get totalSessions => session <= 0 ? 0 : (daily / session).ceil();

  factory IosLimit.fromMap(Map<dynamic, dynamic> m) => IosLimit(
        id: m['id'] as String,
        daily: (m['daily'] as num).toInt(),
        session: (m['session'] as num).toInt(),
        wait: (m['wait'] as num).toInt(),
        apps: (m['apps'] as num? ?? 0).toInt(),
        categories: (m['categories'] as num? ?? 0).toInt(),
        sessionsUsed: (m['sessionsUsed'] as num? ?? 0).toInt(),
        dailyReached: m['dailyReached'] == true,
      );
}

class IosScreenTime {
  static const _ch = MethodChannel('beoffline/ios_screentime');
  static final authorized = ValueNotifier<bool>(false);
  static final hasDeviceSelection = ValueNotifier<bool>(false);
  static final revision = ValueNotifier<int>(0);

  static Future<T?> _call<T>(String method, [dynamic args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } catch (e) {
      debugPrint('ScreenTime $method: $e');
      return null;
    }
  }

  static void reloadReports() => revision.value++;

  static Future<void> refreshStatus() async {
    authorized.value = await _call<bool>('authStatus') ?? false;
    hasDeviceSelection.value = await _call<bool>('hasDeviceSelection') ?? false;
  }

  static Future<void> requestAuthorization() async {
    await _call('requestAuth');
    await refreshStatus();
    reloadReports();
  }

  static Future<void> pickDeviceSelection() async {
    await _call('pickDeviceSelection');
    await refreshStatus();
    reloadReports();
  }

  static Future<void> setDeviceSettings(int minutes, bool notifications) =>
      _call('setDeviceSettings', {
        'limitMinutes': minutes,
        'notifications': notifications,
      });

  static Future<String?> pickLimitApps({String? id}) =>
      _call<String>('pickLimitApps', {'id': id});

  static Future<void> saveLimit(String id, int daily, int session, int wait) =>
      _call('saveLimit', {
        'id': id,
        'daily': daily,
        'session': session,
        'wait': wait,
      });

  static Future<void> removeLimit(String id) =>
      _call('removeLimit', {'id': id});

  static Future<List<IosLimit>> getLimits() async {
    final raw = await _call<List<dynamic>>('getLimits') ?? const [];
    return raw.whereType<Map>().map(IosLimit.fromMap).toList();
  }
}

/// Natywny raport Screen Time osadzony we Flutterze.
class ScreenTimeReport extends StatelessWidget {
  final String kind;
  final double height;
  final String? limitId;
  const ScreenTimeReport({
    super.key,
    required this.kind,
    required this.height,
    this.limitId,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ValueListenableBuilder<int>(
      valueListenable: IosScreenTime.revision,
      builder: (context, rev, _) => SizedBox(
        height: height,
        child: UiKitView(
          key: ValueKey('$kind-$limitId-$rev-${store.limitMinutes}-$dark'),
          viewType: 'beoffline/report',
          creationParams: {
            'kind': kind,
            'limitId': limitId,
            'firstRun': store.firstRun.millisecondsSinceEpoch,
            'dark': dark,
          },
          creationParamsCodec: const StandardMessageCodec(),
        ),
      ),
    );
  }
}

// ============================================================
//  APLIKACJA
// ============================================================

class BeOfflineIosApp extends StatelessWidget {
  const BeOfflineIosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => MaterialApp(
        title: 'beOFFline',
        debugShowCheckedModeBanner: false,
        themeMode: store.themeMode,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          scaffoldBackgroundColor: const Color(0xFFFBFBFB),
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.black,
            primary: Colors.black,
            onPrimary: Colors.white,
            surface: Colors.white,
            brightness: Brightness.light,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            titleTextStyle: TextStyle(
                color: Colors.black, fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0D0D0D),
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.white,
            primary: Colors.white,
            onPrimary: Colors.black,
            brightness: Brightness.dark,
            surface: const Color(0xFF1E1E1E),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            titleTextStyle: TextStyle(
                color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        home: store.isRegistered
            ? const IosHomeShell()
            : const RegistrationPage(),
      ),
    );
  }
}

// ============================================================
//  HOME SHELL (iOS)
// ============================================================

class IosHomeShell extends StatefulWidget {
  const IosHomeShell({super.key});
  @override
  State<IosHomeShell> createState() => _IosHomeShellState();
}

class _IosHomeShellState extends State<IosHomeShell>
    with WidgetsBindingObserver {
  int currentPage = 0;
  int _lastLimit = store.limitMinutes;
  bool _lastNotif = store.notificationsEnabled;

  static const titles = [
    'Dziś',
    'Statystyki',
    'Cele',
    'Prawda czy AI?',
    'Cyfrowy balans',
    'Limity aplikacji',
    'Seria dni',
    'Wydarzenia',
    'Ustawienia',
  ];

  static const icons = [
    Icons.home_outlined,
    Icons.bar_chart_outlined,
    Icons.flag_outlined,
    Icons.psychology_outlined,
    Icons.self_improvement_outlined,
    Icons.timer_outlined,
    Icons.local_fire_department_outlined,
    Icons.event_outlined,
    Icons.settings_outlined,
  ];

  static const pages = [
    IosTodayPage(),
    IosStatsPage(),
    GoalsPage(),
    QuizPage(),
    BalancePage(),
    IosLimitsPage(),
    StreakPage(), // działa 1:1 – Swift obsługuje kanał beoffline/sessions
    EventsPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_syncSettings);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!IosScreenTime.authorized.value) {
        await IosScreenTime.requestAuthorization();
      }
    });
  }

  void _syncSettings() {
    if (_lastLimit != store.limitMinutes ||
        _lastNotif != store.notificationsEnabled) {
      _lastLimit = store.limitMinutes;
      _lastNotif = store.notificationsEnabled;
      unawaited(IosScreenTime.setDeviceSettings(
          store.limitMinutes, store.notificationsEnabled));
      IosScreenTime.reloadReports();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store.removeListener(_syncSettings);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && store.focusRunning) {
      store.cancelFocus();
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(IosScreenTime.refreshStatus());
      IosScreenTime.reloadReports();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[currentPage]),
        actions: [
          if (currentPage == 3)
            IconButton(
              tooltip: 'Ranking',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const QuizRankingPage()),
              ),
              icon: const Icon(Icons.leaderboard_outlined),
            ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Image.asset(
                  isDark ? 'assets/logo_biale.png' : 'assets/logo.png',
                  height: 78,
                  errorBuilder: (context, error, stackTrace) => Icon(
                    Icons.spa_outlined,
                    size: 68,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: titles.length,
                  itemBuilder: (context, index) => ListTile(
                    leading: Icon(icons[index]),
                    title: Text(titles[index]),
                    selected: currentPage == index,
                    onTap: () {
                      setState(() => currentPage = index);
                      Navigator.pop(context);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: IndexedStack(index: currentPage, children: pages),
    );
  }
}

RoundedRectangleBorder _cardShape([double r = 16]) => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(r),
      side: BorderSide(color: Colors.grey.withOpacity(0.2)),
    );

// ============================================================
//  DZIŚ (iOS)
// ============================================================

class IosTodayPage extends StatelessWidget {
  const IosTodayPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        store,
        IosScreenTime.authorized,
        IosScreenTime.hasDeviceSelection,
      ]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Cześć, ${store.userName.isEmpty ? 'tu jesteś' : store.userName}',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(store.quoteOfTheDay,
              style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 24),
          Card(
            elevation: 0,
            shape: _cardShape(),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: !IosScreenTime.authorized.value
                  ? Column(children: [
                      const Text(
                        'Statystyki będą dostępne po przyznaniu dostępu do „Czasu przed ekranem”.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: IosScreenTime.requestAuthorization,
                        child: const Text('Przyznaj dostęp'),
                      ),
                    ])
                  : Column(children: [
                      const ScreenTimeReport(kind: 'today', height: 200),
                      if (!IosScreenTime.hasDeviceSelection.value) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'Aby dostawać powiadomienia 50/80/100% limitu, wybierz co ma się liczyć (najlepiej zaznacz wszystkie kategorie).',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: IosScreenTime.pickDeviceSelection,
                        icon: const Icon(Icons.tune),
                        label: const Text('Co liczy się do limitu'),
                      ),
                      OutlinedButton.icon(
                        onPressed: IosScreenTime.reloadReports,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Odśwież dane'),
                      ),
                    ]),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute<void>(builder: (_) => const FocusPage())),
            icon: const Icon(Icons.timer_outlined),
            label: const Text('Tryb skupienia'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute<void>(builder: (_) => const IdeasPage())),
            icon: const Icon(Icons.lightbulb_outline),
            label: const Text('Generator pomysłów'),
          ),
          if (IosScreenTime.authorized.value) ...[
            const SizedBox(height: 24),
            Text('Użycie aplikacji dziś',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const ScreenTimeReport(kind: 'todayApps', height: 520),
          ],
        ],
      ),
    );
  }
}

// ============================================================
//  STATYSTYKI (iOS)
// ============================================================

class IosStatsPage extends StatelessWidget {
  const IosStatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: IosScreenTime.authorized,
      builder: (context, ok, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Statystyki',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          if (!ok)
            FilledButton(
              onPressed: IosScreenTime.requestAuthorization,
              child: const Text('Przyznaj dostęp do Czasu przed ekranem'),
            )
          else ...[
            Card(
              elevation: 0,
              shape: _cardShape(),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: ScreenTimeReport(kind: 'week', height: 170),
              ),
            ),
            const SizedBox(height: 20),
            Text('Najczęściej używane aplikacje od instalacji',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const ScreenTimeReport(kind: 'allTime', height: 1250),
          ],
        ],
      ),
    );
  }
}

// ============================================================
//  LIMITY APLIKACJI (iOS)
// ============================================================

class IosLimitsPage extends StatefulWidget {
  const IosLimitsPage({super.key});
  @override
  State<IosLimitsPage> createState() => _IosLimitsPageState();
}

class _IosLimitsPageState extends State<IosLimitsPage>
    with WidgetsBindingObserver {
  List<IosLimit> limits = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final loaded = await IosScreenTime.getLimits();
    if (mounted) {
      setState(() {
        limits = loaded;
        loading = false;
      });
    }
  }

  Future<void> _addOrEdit({IosLimit? existing}) async {
    if (!IosScreenTime.authorized.value) {
      await IosScreenTime.requestAuthorization();
      if (!IosScreenTime.authorized.value) return;
    }
    String? id = existing?.id;
    if (existing == null) {
      id = await IosScreenTime.pickLimitApps();
      if (id == null) return;
    }
    if (!mounted) return;

    var daily = existing?.daily ?? 60;
    var session = existing?.session ?? 10;
    var wait = existing?.wait ?? 30;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final total = session <= 0 ? 0 : (daily / session).ceil();
          return AlertDialog(
            title: Text(existing == null
                ? 'Ogranicz wybrane aplikacje'
                : 'Edytuj ograniczenie'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceVariant
                          .withOpacity(0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Liczba sesji: $total dziennie ($session min każda)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (existing != null)
                    TextButton.icon(
                      onPressed: () =>
                          IosScreenTime.pickLimitApps(id: existing.id),
                      icon: const Icon(Icons.apps),
                      label: const Text('Zmień wybrane aplikacje'),
                    ),
                  const SizedBox(height: 16),
                  Text('Dzienny limit: $daily min'),
                  Slider(
                    value: daily.toDouble(),
                    min: 15,
                    max: 240,
                    divisions: 15,
                    label: '$daily min',
                    onChanged: (v) => setD(() => daily = v.round()),
                  ),
                  Text('Długość jednej sesji: $session min'),
                  Slider(
                    value: session.toDouble(),
                    min: 5,
                    max: 60,
                    divisions: 11,
                    label: '$session min',
                    onChanged: (v) => setD(() => session = v.round()),
                  ),
                  Text('Czas oczekiwania przed wejściem: $wait s'),
                  Slider(
                    value: wait.toDouble(),
                    min: 0,
                    max: 120,
                    divisions: 12,
                    label: '$wait s',
                    onChanged: (v) => setD(() => wait = v.round()),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Anuluj')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Zapisz')),
            ],
          );
        },
      ),
    );

    if (saved == true && id != null) {
      await IosScreenTime.saveLimit(id, daily, session, wait);
    }
    IosScreenTime.reloadReports();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        FilledButton.icon(
          onPressed: () => _addOrEdit(),
          icon: const Icon(Icons.add),
          label: const Text('Dodaj aplikację do ograniczenia'),
        ),
        const SizedBox(height: 16),
        if (limits.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.timer_off_outlined,
                      size: 64, color: Colors.grey.withOpacity(0.4)),
                  const SizedBox(height: 12),
                  const Text('Brak aktywnych ograniczeń',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text('Wybierz aplikację i ustal dla niej limit sesji',
                      style: TextStyle(color: Colors.grey.shade600)),
                ],
              ),
            ),
          )
        else
          ...limits.map((limit) => Card(
                elevation: 0,
                shape: _cardShape(),
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              limit.dailyReached
                                  ? 'Limit na dziś wykorzystany'
                                  : 'Aktywne ograniczenie',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: limit.dailyReached ? Colors.red : null,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _addOrEdit(existing: limit),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await IosScreenTime.removeLimit(limit.id);
                              await _load();
                            },
                          ),
                        ],
                      ),
                      ScreenTimeReport(
                          kind: 'limit', limitId: limit.id, height: 170),
                    ],
                  ),
                ),
              )),
      ],
    );
  }
}