import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:usage_stats/usage_stats.dart';

import 'firebase_options.dart';

final AppStore store = AppStore();
late final Future<void> appBootstrap;
bool firebaseReady = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  appBootstrap = _bootstrap();
  runApp(const BeOfflineApp());
}

Future<void> _bootstrap() async {
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
}

String dayKey(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

String formatDuration(int seconds) {
  if (seconds <= 0) return '0 min';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours > 0) {
    return '$hours godz. ${minutes.toString().padLeft(2, '0')} min';
  }
  if (minutes > 0) return '$minutes min';
  return '$seconds sek.';
}

String cleanPackageName(String packageName) {
  final parts = packageName.split('.');
  return parts.isEmpty ? packageName : parts.last;
}

// ============================================================
//  LOGO
// ============================================================

class _AppLogo extends StatelessWidget {
  final double height;
  const _AppLogo({this.height = 80});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Image.asset(
      isDark ? 'assets/logo_biale.png' : 'assets/logo.png',
      height: height,
      errorBuilder: (context, error, stackTrace) => Icon(
        Icons.spa_outlined,
        size: height * 0.8,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

// ============================================================
//  POWIADOMIENIA
// ============================================================

class AppNotifications {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        ),
      );
      await _plugin.initialize(settings);
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _ready = true;
    } catch (error) {
      debugPrint('Powiadomienia - błąd: $error');
    }
  }

  static Future<void> show(String title, String body) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        DateTime.now().millisecondsSinceEpoch.remainder(100000),
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'beoffline_channel',
            'Powiadomienia beOFFline',
            channelDescription: 'Przypomnienia o cyfrowym balansie',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (error) {
      debugPrint('Powiadomienie - błąd: $error');
    }
  }
}

// ============================================================
//  MODELE
// ============================================================

class Goal {
  final String id;
  final String title;
  final String description;
  final int targetDays;
  final Set<String> completedDays;

  Goal({
    required this.id,
    required this.title,
    required this.description,
    required this.targetDays,
    Set<String>? completedDays,
  }) : completedDays = completedDays ?? <String>{};

  int get completedCount => completedDays.length;
  double get progress => targetDays <= 0
      ? 0
      : (completedCount / targetDays).clamp(0.0, 1.0).toDouble();
  bool get isDoneToday => completedDays.contains(dayKey(DateTime.now()));

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'targetDays': targetDays,
        'completedDays': completedDays.toList(),
      };

  factory Goal.fromJson(Map<String, dynamic> json) => Goal(
        id: json['id'] as String,
        title: json['title'] as String,
        description: (json['description'] ?? '') as String,
        targetDays: json['targetDays'] as int,
        completedDays: Set<String>.from(json['completedDays'] as List<dynamic>),
      );

  Goal copyWith({
    String? title,
    String? description,
    int? targetDays,
    Set<String>? completedDays,
  }) =>
      Goal(
        id: id,
        title: title ?? this.title,
        description: description ?? this.description,
        targetDays: targetDays ?? this.targetDays,
        completedDays: completedDays ?? this.completedDays,
      );
}

class AppUsageEntry {
  final String packageName;
  final String appName;
  final int seconds;
  final Uint8List? icon;
  const AppUsageEntry({
    required this.packageName,
    required this.appName,
    required this.seconds,
    this.icon,
  });
}

class InstalledAppMeta {
  final String name;
  final Uint8List? icon;
  const InstalledAppMeta({required this.name, this.icon});
}

class PhotoQuizItem {
  final String path;
  final bool isAi;
  const PhotoQuizItem({required this.path, required this.isAi});
}

class AppLimit {
  final String packageName;
  final String appName;
  final int dailyLimitMinutes;
  final int sessionMinutes;
  final int waitSeconds;

  const AppLimit({
    required this.packageName,
    required this.appName,
    required this.dailyLimitMinutes,
    required this.sessionMinutes,
    required this.waitSeconds,
  });

  int get totalSessions =>
      sessionMinutes <= 0 ? 0 : (dailyLimitMinutes / sessionMinutes).ceil();

  int get dailyLimitSeconds => dailyLimitMinutes * 60;
  int get sessionSeconds => sessionMinutes * 60;

  int sessionsUsed(int usedSec) {
    if (sessionSeconds <= 0) return 0;
    return (usedSec / sessionSeconds).floor().clamp(0, totalSessions);
  }

  int sessionsRemaining(int usedSec) {
    return (totalSessions - sessionsUsed(usedSec)).clamp(0, totalSessions);
  }

  int timeRemainingSeconds(int usedSec) {
    return (dailyLimitSeconds - usedSec).clamp(0, dailyLimitSeconds);
  }

  Map<String, dynamic> toJson() => {
        'dailyLimitMinutes': dailyLimitMinutes,
        'sessionMinutes': sessionMinutes,
        'waitSeconds': waitSeconds,
      };

  factory AppLimit.fromJson(
          String pkg, String name, Map<String, dynamic> json) =>
      AppLimit(
        packageName: pkg,
        appName: name,
        dailyLimitMinutes: (json['dailyLimitMinutes'] ?? 60) as int,
        sessionMinutes: (json['sessionMinutes'] ?? 10) as int,
        waitSeconds: (json['waitSeconds'] ?? 30) as int,
      );
}

class StreakInfo {
  int currentStreak = 0;
  int bestStreak = 0;
  Set<String> activeDays = {};

  StreakInfo({
    this.currentStreak = 0,
    this.bestStreak = 0,
    Set<String>? activeDays,
  }) : activeDays = activeDays ?? <String>{};

  StreakInfo.empty()
      : currentStreak = 0,
        bestStreak = 0,
        activeDays = <String>{};

  Map<String, dynamic> toJson() => {
        'currentStreak': currentStreak,
        'bestStreak': bestStreak,
        'activeDays': activeDays.toList(),
      };

  factory StreakInfo.fromJson(Map<String, dynamic> json) => StreakInfo()
    ..currentStreak = (json['currentStreak'] ?? 0) as int
    ..bestStreak = (json['bestStreak'] ?? 0) as int
    ..activeDays = Set<String>.from(
      (json['activeDays'] as List<dynamic>?)?.map((e) => e.toString()) ??
          <String>[],
    );
}

// ============================================================
//  PLATFORM CHANNEL
// ============================================================

const _sessionChannel = MethodChannel('beoffline/sessions');

Future<String> _sessionCall(String method, [dynamic args]) async {
  try {
    final result = await _sessionChannel.invokeMethod(method, args);
    if (result == null) return '{}';
    return result.toString();
  } catch (_) {
    return '{}';
  }
}

// ============================================================
//  DANE STATYCZNE
// ============================================================

const List<String> ideas = [
  'Zagraj w planszówkę lub w karty.',
  'Przygotuj coś do jedzenia z bliską osobą.',
  'Narysuj miejsce, które lubisz.',
  'Wybierz się na spacer nową trasą.',
  'Napisz krótkie opowiadanie.',
  'Posadź roślinę i obserwuj, jak rośnie.',
  'Zrób papierowe origami.',
  'Przeczytaj rozdział książki.',
  'Odwiedź bibliotekę.',
  'Ułóż własną zagadkę dla znajomych.',
];

const List<String> motivationalQuotes = [
  'Najlepsze rzeczy dzieją się wtedy, gdy podnosisz wzrok znad ekranu.',
  'Telefon może poczekać. Twoje życie dzieje się teraz.',
  'Mniej scrollowania, więcej wspomnień.',
  'Każda minuta offline to mały krok do większego spokoju.',
  'Nie musisz być ciągle dostępny, żeby być ważny.',
  'Odpoczynek od ekranu to nie strata czasu. To odzyskiwanie siebie.',
  'Świat poza telefonem też ma powiadomienia: wiatr, rozmowy i ciszę.',
  'Nie licz tylko lajków. Licz chwile, które naprawdę pamiętasz.',
  'Technologia ma Ci pomagać, nie prowadzić za rękę cały dzień.',
  'Czas offline to przestrzeń na pomysły, relacje i odpoczynek.',
];

const List<String> balanceTips = [
  'Zostaw telefon poza biurkiem podczas nauki.',
  'Ustal godzinę wieczorem, po której nie sprawdzasz social mediów.',
  'Wyłącz powiadomienia z aplikacji, które nie są naprawdę ważne.',
  'Zamiast telefonu przed snem wybierz książkę, muzykę albo rozmowę.',
  'Raz dziennie zrób krótką przerwę bez żadnego ekranu.',
  'Usuń z ekranu głównego aplikacje, które najbardziej Cię wciągają.',
  'Nie zaczynaj dnia od telefonu. Najpierw śniadanie, ruch albo rozmowa.',
];

// ============================================================
//  MAGAZYN DANYCH
// ============================================================

class AppStore extends ChangeNotifier {
  static const String _settingsKey = 'beoffline_settings_v4';
  static const MethodChannel _metadataChannel =
      MethodChannel('beoffline/app_metadata');

  SharedPreferences? _prefs;
  ThemeMode themeMode = ThemeMode.system;
  int limitMinutes = 120;
  bool notificationsEnabled = true;
  DateTime firstRun = DateTime.now();
  List<Goal> goals = [];
  bool isRegistered = false;
  String userName = '';
  String nickname = '';
  String heardFrom = '';
  bool usagePermission = false;
  bool usageLoading = false;
  bool usageAvailable = false;
  String? usageError;

  int todayUsageSeconds = 0;
  int totalUsageSeconds = 0;
  List<AppUsageEntry> todayApps = [];
  List<AppUsageEntry> allTimeApps = [];
  Map<String, int> last7Days = {};
  Map<String, int> rawUsageMap = {};
  final Map<String, InstalledAppMeta> _installedApps = {};

  Timer? _usageTimer;
  bool focusRunning = false;
  int focusMinutes = 25;
  Duration focusRemaining = Duration.zero;
  DateTime? _focusEnd;
  Timer? _focusTimer;

  int get limitSeconds => limitMinutes * 60;
  double get usageProgress => limitSeconds <= 0
      ? 0
      : (todayUsageSeconds / limitSeconds).clamp(0.0, 1.0).toDouble();
  String get quoteOfTheDay =>
      motivationalQuotes[DateTime.now().day % motivationalQuotes.length];
  String get publicName => nickname.isNotEmpty
      ? nickname
      : (userName.isNotEmpty ? userName : 'Anonim');

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs?.getString(_settingsKey);
    if (raw != null) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final savedLimit = data['limitMinutes'];
        if (savedLimit is int) limitMinutes = savedLimit.clamp(30, 480);
        notificationsEnabled = data['notificationsEnabled'] != false;
        final savedTheme = data['themeMode'];
        if (savedTheme is int &&
            savedTheme >= 0 &&
            savedTheme < ThemeMode.values.length) {
          themeMode = ThemeMode.values[savedTheme];
        }
        final firstRunRaw = data['firstRun'];
        if (firstRunRaw is String) {
          firstRun = DateTime.tryParse(firstRunRaw) ?? DateTime.now();
        }
        final savedGoals = data['goals'];
        if (savedGoals is List) {
          goals = savedGoals
              .map((item) =>
                  Goal.fromJson(Map<String, dynamic>.from(item as Map)))
              .toList();
        }
      } catch (error) {
        debugPrint('Nie udało się odczytać ustawień: $error');
      }
    } else {
      firstRun = DateTime.now();
      await save();
    }

    isRegistered = _prefs?.getBool('profile_done') ?? false;
    userName = _prefs?.getString('profile_name') ?? '';
    nickname = _prefs?.getString('profile_nickname') ?? '';
    heardFrom = _prefs?.getString('profile_source') ?? '';

    notifyListeners();
  }

  Future<void> save() async {
    await _prefs?.setString(
      _settingsKey,
      jsonEncode({
        'themeMode': themeMode.index,
        'limitMinutes': limitMinutes,
        'notificationsEnabled': notificationsEnabled,
        'firstRun': firstRun.toIso8601String(),
        'goals': goals.map((goal) => goal.toJson()).toList(),
      }),
    );
  }

  Future<String?> registerProfile({
    required String name,
    required String source,
    required String chosenNickname,
  }) async {
    if (!firebaseReady) return 'Najpierw uruchom flutterfire configure.';
    final cleanName = name.trim();
    final cleanNick = chosenNickname.trim();
    final nickKey = cleanNick.toLowerCase();
    if (cleanName.length < 2) return 'Podaj swoje imię.';
    if (cleanNick.length < 3 || cleanNick.length > 16) {
      return 'Nickname musi mieć od 3 do 16 znaków.';
    }
    if (cleanNick.contains(' ')) return 'Nickname nie może zawierać spacji.';

    try {
      final current = FirebaseAuth.instance.currentUser;
      final credential = current == null
          ? await FirebaseAuth.instance.signInAnonymously()
          : null;
      final uid = current?.uid ?? credential!.user!.uid;
      final database = FirebaseFirestore.instance;
      final nicknameRef = database.collection('nicknames').doc(nickKey);
      final existing = await nicknameRef.get();
      if (existing.exists && existing.data()?['uid'] != uid) {
        return 'Ten nickname jest już zajęty.';
      }
      final batch = database.batch();
      batch.set(nicknameRef, {'uid': uid});
      batch.set(database.collection('users').doc(uid), {
        'name': cleanName,
        'nickname': cleanNick,
        'heardFrom': source,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await batch.commit();
      userName = cleanName;
      nickname = cleanNick;
      heardFrom = source;
      isRegistered = true;
      await _prefs?.setBool('profile_done', true);
      await _prefs?.setString('profile_name', cleanName);
      await _prefs?.setString('profile_nickname', cleanNick);
      await _prefs?.setString('profile_source', source);
      notifyListeners();
      return null;
    } on FirebaseAuthException catch (error) {
      return 'Logowanie: ${error.code}';
    } on FirebaseException catch (error) {
      return 'Firestore: ${error.code}';
    } catch (error) {
      debugPrint('Rejestracja nie powiodła się: $error');
      return 'Nie udało się zapisać profilu.';
    }
  }

  Future<String?> submitQuizScore(int score, int total) async {
    if (!firebaseReady) return 'Ranking wymaga Firebase.';
    try {
      var user = FirebaseAuth.instance.currentUser;
      user ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (user == null) return 'Brak zalogowanego użytkownika.';
      final ref =
          FirebaseFirestore.instance.collection('quiz_rankings').doc(user.uid);
      final existing = await ref.get();
      final previous = (existing.data()?['bestScore'] as num?)?.toInt() ?? 0;
      await ref.set({
        'nickname': publicName,
        'score': score,
        'bestScore': math.max(previous, score),
        'total': total,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return null;
    } on FirebaseException catch (error) {
      return 'Nie udało się zapisać rankingu: ${error.code}';
    } catch (error) {
      debugPrint('Ranking - błąd: $error');
      return 'Nie udało się zapisać rankingu.';
    }
  }

  void setTheme(ThemeMode mode) {
    themeMode = mode;
    notifyListeners();
    unawaited(save());
  }

  void setLimit(int minutes) {
    limitMinutes = minutes.clamp(30, 480);
    notifyListeners();
    unawaited(save());
  }

  void setNotifications(bool enabled) {
    notificationsEnabled = enabled;
    notifyListeners();
    unawaited(save());
  }

  Future<void> requestUsagePermission() async {
    if (!Platform.isAndroid) return;
    try {
      await UsageStats.grantUsagePermission();
    } catch (error) {
      debugPrint('Nie udało się otworzyć uprawnień: $error');
    }
  }

  Future<void> firstPermissionFlow() async {
    if (!Platform.isAndroid) return;
    usagePermission = await UsageStats.checkUsagePermission() == true;
    if (!usagePermission) {
      notifyListeners();
      await requestUsagePermission();
    }
  }

  Future<void> _loadInstalledApps(Iterable<String> packages) async {
    if (!Platform.isAndroid) return;
    final missing = packages
        .where((packageName) => !_installedApps.containsKey(packageName))
        .toSet()
        .toList();
    if (missing.isEmpty) return;
    try {
      final rows = await _metadataChannel.invokeListMethod<dynamic>(
        'getAppMetadata',
        missing,
      );
      for (final row in rows ?? const []) {
        if (row is! Map || row['packageName'] is! String) continue;
        final packageName = row['packageName'] as String;
        final name = row['name'];
        final icon = row['icon'];
        _installedApps[packageName] = InstalledAppMeta(
          name: name is String && name.trim().isNotEmpty
              ? name
              : cleanPackageName(packageName),
          icon: icon is Uint8List ? icon : null,
        );
      }
    } catch (error) {
      debugPrint('Nie udało się pobrać nazw i ikon aplikacji: $error');
    }
  }

  // Precyzyjne odczytanie czasu w sekundach z natywnego analizatora Androida
  Future<Map<String, int>> _queryUsage(DateTime start, DateTime end) async {
    if (!Platform.isAndroid) return {};
    try {
      final jsonStr = await _sessionChannel.invokeMethod<String>(
        'queryUsageRange',
        {
          'start': start.millisecondsSinceEpoch,
          'end': end.millisecondsSinceEpoch,
        },
      );
      if (jsonStr == null || jsonStr.isEmpty) return {};
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      // Natywny kod zwraca już czyste sekundy!
      return data.map((key, value) => MapEntry(key, (value as num).toInt()));
    } catch (e) {
      debugPrint('Błąd odczytu queryUsageRange: $e');
      return {};
    }
  }

  Future<List<AppUsageEntry>> _buildUsageEntries(
      DateTime start, DateTime end) async {
    final raw = await _queryUsage(start, end);
    await _loadInstalledApps(raw.keys);
    final entries = raw.entries.map((entry) {
      final meta = _installedApps[entry.key];
      return AppUsageEntry(
        packageName: entry.key,
        appName: meta?.name ?? cleanPackageName(entry.key),
        icon: meta?.icon,
        seconds: entry.value,
      );
    }).toList()
      ..sort((a, b) => b.seconds.compareTo(a.seconds));
    return entries;
  }

  Future<void> refreshUsage() async {
    if (!Platform.isAndroid) {
      usageAvailable = false;
      usageError = 'Odczyt statystyk wymaga Androida.';
      notifyListeners();
      return;
    }
    if (usageLoading) return;
    usageLoading = true;
    usageError = null;
    notifyListeners();
    try {
      usagePermission = await UsageStats.checkUsagePermission() == true;
      if (!usagePermission) {
        usageAvailable = false;
        todayUsageSeconds = 0;
        totalUsageSeconds = 0;
        todayApps = [];
        allTimeApps = [];
        usageError = 'Włącz dostęp do danych użycia w ustawieniach telefonu.';
        return;
      }
      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);

      rawUsageMap = await _queryUsage(todayStart, now);
      todayApps = await _buildUsageEntries(todayStart, now);
      allTimeApps = await _buildUsageEntries(firstRun, now);

      todayUsageSeconds = todayApps.fold<int>(0, (acc, app) => acc + app.seconds);
      totalUsageSeconds = allTimeApps.fold<int>(0, (acc, app) => acc + app.seconds);

      final week = <String, int>{};
      for (var i = 6; i >= 0; i--) {
        final day = todayStart.subtract(Duration(days: i));
        final raw = await _queryUsage(day, day.add(const Duration(days: 1)));
        week[dayKey(day)] = raw.values.fold<int>(0, (acc, value) => acc + value);
      }
      last7Days = week;
      usageAvailable = true;
    } catch (error) {
      usageAvailable = false;
      usageError = 'Nie udało się pobrać statystyk.';
      debugPrint('Błąd statystyk użycia: $error');
    } finally {
      usageLoading = false;
      notifyListeners();
    }
  }

  void startUsageRefresh() {
    _usageTimer?.cancel();
    _usageTimer = Timer.periodic(
      const Duration(seconds: 15),
      (timer) => unawaited(refreshUsage()),
    );
  }

  void stopUsageRefresh() {
    _usageTimer?.cancel();
    _usageTimer = null;
  }

  void addGoal(String title, String description, int targetDays) {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) return;
    goals.add(Goal(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: cleanTitle,
      description: description.trim(),
      targetDays: targetDays,
    ));
    notifyListeners();
    unawaited(save());
  }

  void updateGoal(Goal goal, String title, String description, int targetDays) {
    final index = goals.indexWhere((item) => item.id == goal.id);
    if (index == -1) return;
    goals[index] = goal.copyWith(
      title: title.trim().isEmpty ? goal.title : title.trim(),
      description: description.trim(),
      targetDays: targetDays,
    );
    notifyListeners();
    unawaited(save());
  }

  void markGoalToday(Goal goal) {
    final index = goals.indexWhere((item) => item.id == goal.id);
    if (index == -1) return;
    final today = dayKey(DateTime.now());
    final days = Set<String>.from(goal.completedDays);
    days.contains(today) ? days.remove(today) : days.add(today);
    goals[index] = goal.copyWith(completedDays: days);
    notifyListeners();
    unawaited(save());
  }

  void deleteGoal(Goal goal) {
    goals.removeWhere((item) => item.id == goal.id);
    notifyListeners();
    unawaited(save());
  }

  void startFocus(int minutes) {
    _focusTimer?.cancel();
    focusMinutes = minutes;
    focusRunning = true;
    focusRemaining = Duration(minutes: minutes);
    _focusEnd = DateTime.now().add(Duration(minutes: minutes));
    notifyListeners();
    _focusTimer = Timer.periodic(const Duration(seconds: 1), (timer) => _tickFocus());
  }

  void _tickFocus() {
    final end = _focusEnd;
    if (end == null || !focusRunning) return;
    final remaining = end.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _focusTimer?.cancel();
      focusRunning = false;
      focusRemaining = Duration.zero;
      _focusEnd = null;
      notifyListeners();
      if (notificationsEnabled) {
        unawaited(AppNotifications.show(
          'Sesja zakończona',
          'Dobra robota. Udało Ci się wytrzymać $focusMinutes min.',
        ));
      }
    } else {
      focusRemaining = remaining;
      notifyListeners();
    }
  }

  void cancelFocus() {
    _focusTimer?.cancel();
    focusRunning = false;
    focusRemaining = Duration.zero;
    _focusEnd = null;
    notifyListeners();
  }

  Future<void> resetData() async {
    await _prefs?.remove(_settingsKey);
    goals.clear();
    limitMinutes = 120;
    themeMode = ThemeMode.system;
    notificationsEnabled = true;
    firstRun = DateTime.now();
    cancelFocus();
    await save();
    await refreshUsage();
    notifyListeners();
  }

  @override
  void dispose() {
    _usageTimer?.cancel();
    _focusTimer?.cancel();
    super.dispose();
  }
}

// ============================================================
//  APLIKACJA - CZYSTY BIAŁY / CZARNY DESIGN
// ============================================================

class BeOfflineApp extends StatelessWidget {
  const BeOfflineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: appBootstrap,
      builder: (context, snapshot) {
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
                  color: Colors.black,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
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
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            home: store.isRegistered
                ? const HomeShell()
                : const RegistrationPage(),
          ),
        );
      },
    );
  }
}

// ============================================================
//  HOME SHELL
// ============================================================

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int currentPage = 0;

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
    TodayPage(),
    StatsPage(),
    GoalsPage(),
    QuizPage(),
    BalancePage(),
    SessionLimitsPage(),
    StreakPage(),
    EventsPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.startUsageRefresh();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await store.firstPermissionFlow();
      await store.refreshUsage();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store.stopUsageRefresh();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      store.stopUsageRefresh();
      if (store.focusRunning) store.cancelFocus();
    }
    if (state == AppLifecycleState.resumed) {
      store.startUsageRefresh();
      unawaited(store.refreshUsage());
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

// ============================================================
//  EKRAN 1: DZIŚ
// ============================================================

class TodayPage extends StatelessWidget {
  const TodayPage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Cześć, ${store.userName.isEmpty ? 'tu jesteś' : store.userName}',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(store.quoteOfTheDay, style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 24),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.grey.withOpacity(0.2)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text(
                    store.usageAvailable
                        ? formatDuration(store.todayUsageSeconds)
                        : 'Brak danych',
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text('Dzienny limit: ${formatDuration(store.limitSeconds)}'),
                  const SizedBox(height: 20),
                  LinearProgressIndicator(
                    value: store.usageAvailable ? store.usageProgress : 0,
                    minHeight: 10,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    store.usageAvailable
                        ? (store.todayUsageSeconds >= store.limitSeconds
                            ? 'Osiągnięto ustawiony limit.'
                            : 'Do limitu pozostało ${formatDuration(store.limitSeconds - store.todayUsageSeconds)}.')
                        : store.usageError ??
                            'Statystyki będą dostępne po przyznaniu uprawnień.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: store.usageLoading ? null : store.refreshUsage,
                    icon: const Icon(Icons.refresh),
                    label: Text(store.usageLoading ? 'Pobieranie...' : 'Odśwież dane'),
                  ),
                ],
              ),
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
          if (store.usageAvailable && store.todayApps.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Użycie aplikacji dziś',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            AppUsageList(entries: store.todayApps.take(8).toList()),
          ],
        ],
      ),
    );
  }
}

// ============================================================
//  EKRAN 2: STATYSTYKI
// ============================================================

class StatsPage extends StatelessWidget {
  const StatsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final maxValue = store.last7Days.values.isEmpty
            ? 1
            : store.last7Days.values.reduce(math.max).clamp(1, 999999);
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Statystyki', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Od instalacji: ${formatDuration(store.totalUsageSeconds)}'),
            const SizedBox(height: 20),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.grey.withOpacity(0.2)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  height: 160,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: store.last7Days.entries.map((entry) {
                      final barHeight =
                          (120.0 * entry.value / maxValue).clamp(6.0, 120.0);
                      return Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(entry.value == 0 ? '' : '${entry.value ~/ 60}m',
                                style: const TextStyle(fontSize: 10)),
                            const SizedBox(height: 4),
                            Container(
                              height: barHeight,
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(entry.key.substring(5),
                                style: const TextStyle(fontSize: 10)),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('Najczęściej używane aplikacje od instalacji',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            store.allTimeApps.isEmpty
                ? const Text('Brak danych.')
                : AppUsageList(entries: store.allTimeApps.take(20).toList()),
          ],
        );
      },
    );
  }
}

class AppUsageList extends StatelessWidget {
  final List<AppUsageEntry> entries;
  const AppUsageList({super.key, required this.entries});
  @override
  Widget build(BuildContext context) => Column(
        children: entries.map((entry) {
          return Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.grey.withOpacity(0.15)),
            ),
            child: ListTile(
              leading: entry.icon == null
                  ? CircleAvatar(
                      child: Text(entry.appName.isEmpty
                          ? '?'
                          : entry.appName.characters.first.toUpperCase()))
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(entry.icon!,
                          width: 42, height: 42, fit: BoxFit.cover),
                    ),
              title: Text(entry.appName, style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: Text(formatDuration(entry.seconds), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          );
        }).toList(),
      );
}

// ============================================================
//  EKRAN 3: CELE
// ============================================================

class GoalsPage extends StatelessWidget {
  const GoalsPage({super.key});

  Future<void> _addOrEditGoal(BuildContext context, {Goal? goal}) async {
    final titleController = TextEditingController(text: goal?.title ?? '');
    final descriptionController =
        TextEditingController(text: goal?.description ?? '');
    var days = goal?.targetDays ?? 7;
    final result = await showDialog<(String, String, int)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(goal == null ? 'Nowy cel' : 'Edytuj cel'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  maxLength: 60,
                  decoration: const InputDecoration(labelText: 'Nazwa celu'),
                ),
                TextField(
                  controller: descriptionController,
                  maxLength: 140,
                  decoration: const InputDecoration(labelText: 'Opis'),
                ),
                Text('Czas trwania: $days dni'),
                Slider(
                  value: days.toDouble(),
                  min: 1,
                  max: 60,
                  divisions: 59,
                  onChanged: (value) =>
                      setDialogState(() => days = value.round()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () {
                final title = titleController.text.trim();
                if (title.isEmpty) return;
                Navigator.pop(dialogContext, (
                  title,
                  descriptionController.text.trim(),
                  days,
                ));
              },
              child: const Text('Zapisz'),
            ),
          ],
        ),
      ),
    );
    titleController.dispose();
    descriptionController.dispose();
    if (result == null) return;
    goal == null
        ? store.addGoal(result.$1, result.$2, result.$3)
        : store.updateGoal(goal, result.$1, result.$2, result.$3);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Cele', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _addOrEditGoal(context),
            icon: const Icon(Icons.add),
            label: const Text('Dodaj cel'),
          ),
          const SizedBox(height: 20),
          if (store.goals.isEmpty)
            const Center(child: Text('Nie masz jeszcze żadnych celów.'))
          else
            ...store.goals.map((goal) => Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Colors.grey.withOpacity(0.2)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(child: Text(goal.title,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
                          IconButton(
                            onPressed: () =>
                                _addOrEditGoal(context, goal: goal),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            onPressed: () => store.deleteGoal(goal),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ]),
                        if (goal.description.isNotEmpty) Text(goal.description),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(value: goal.progress, minHeight: 8, borderRadius: BorderRadius.circular(4)),
                        const SizedBox(height: 8),
                        Text('${goal.completedCount} / ${goal.targetDays} dni', style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () => store.markGoalToday(goal),
                          icon: Icon(goal.isDoneToday ? Icons.undo : Icons.check),
                          label: Text(goal.isDoneToday
                              ? 'Cofnij dzisiejszy dzień'
                              : 'Zaznacz dzisiejszy dzień'),
                        ),
                      ],
                    ),
                  ),
                )),
        ],
      ),
    );
  }
}

// ============================================================
//  EKRAN 4: QUIZ
// ============================================================

class QuizPage extends StatefulWidget {
  const QuizPage({super.key});
  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  final List<PhotoQuizItem> questions = [];
  int index = 0;
  int score = 0;
  bool? correct;
  bool loading = true;
  String? rankingMessage;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  bool _isImage(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.jfif') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp');
  }

  Future<void> _loadPhotos() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final loaded = manifest.listAssets().where(_isImage).map((path) {
      if (path.startsWith('assets/quiz/ai/')) {
        return PhotoQuizItem(path: path, isAi: true);
      }
      if (path.startsWith('assets/quiz/real/')) {
        return PhotoQuizItem(path: path, isAi: false);
      }
      return null;
    }).whereType<PhotoQuizItem>().toList()
      ..shuffle();
    if (loaded.length > 20) loaded.removeRange(20, loaded.length);
    if (!mounted) return;
    setState(() {
      questions
        ..clear()
        ..addAll(loaded);
      loading = false;
    });
  }

  void answer(bool selectedAi) {
    if (correct != null || questions.isEmpty) return;
    final isCorrect = selectedAi == questions[index].isAi;
    setState(() {
      correct = isCorrect;
      if (isCorrect) score++;
    });
  }

  Future<void> finish() async {
    setState(() {
      index = questions.length;
      rankingMessage = 'Zapisywanie wyniku...';
    });
    final error = await store.submitQuizScore(score, questions.length);
    if (!mounted) return;
    setState(() {
      rankingMessage = error ?? 'Wynik zapisany w publicznym rankingu.';
    });
  }

  Future<void> restart() async {
    setState(() {
      loading = true;
      index = 0;
      score = 0;
      correct = null;
      rankingMessage = null;
    });
    await _loadPhotos();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (questions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Dodaj zdjęcia do folderów assets/quiz/real i assets/quiz/ai.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (index >= questions.length) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Koniec quizu',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text('Wynik: $score / ${questions.length}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(rankingMessage ?? '', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const QuizRankingPage(),
                  ),
                ),
                child: const Text('Zobacz ranking'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: restart,
                child: const Text('Zagraj jeszcze raz'),
              ),
            ],
          ),
        ),
      );
    }

    final item = questions[index];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Prawda czy AI?',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Czy to zdjęcie jest prawdziwe, czy wygenerowane przez AI?'),
        const SizedBox(height: 20),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: AspectRatio(
            aspectRatio: 1,
            child: Image.asset(
              item.path,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  const Center(child: Text('Nie udało się wczytać zdjęcia.')),
            ),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: correct == null ? () => answer(false) : null,
          child: const Text('Prawdziwe zdjęcie'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: correct == null ? () => answer(true) : null,
          child: const Text('Wygenerowane przez AI'),
        ),
        if (correct != null) ...[
          const SizedBox(height: 20),
          Text(correct! ? 'Dobra odpowiedź' : 'Tym razem nie',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(item.isAi
              ? 'To obraz wygenerowany przez AI.'
              : 'To prawdziwe zdjęcie.'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              if (index + 1 >= questions.length) {
                finish();
              } else {
                setState(() {
                  index++;
                  correct = null;
                });
              }
            },
            child: Text(index + 1 >= questions.length ? 'Zakończ' : 'Dalej'),
          ),
        ],
        const SizedBox(height: 20),
        Text('Zdjęcie ${index + 1} z ${questions.length}'),
      ],
    );
  }
}

class QuizRankingPage extends StatelessWidget {
  const QuizRankingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('quiz_rankings')
        .orderBy('bestScore', descending: true)
        .limit(50)
        .snapshots();

    return Scaffold(
      appBar: AppBar(title: const Text('Ranking quizu')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nie udało się wczytać rankingu. Sprawdź reguły Firestore.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('Ranking jest jeszcze pusty.'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final data = docs[index].data();
              final nickname = (data['nickname'] ?? 'Anonim').toString();
              final best = (data['bestScore'] as num?)?.toInt() ?? 0;
              final total = (data['total'] as num?)?.toInt() ?? 20;
              return Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.withOpacity(0.15)),
                ),
                child: ListTile(
                  leading: CircleAvatar(child: Text('${index + 1}')),
                  title: Text(nickname, style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: Text(
                    '$best / $total',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ============================================================
//  EKRAN 5: BALANS
// ============================================================

class BalancePage extends StatelessWidget {
  const BalancePage({super.key});
  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Cyfrowy balans',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          ...balanceTips.asMap().entries.map((entry) => Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.withOpacity(0.15)),
                ),
                child: ListTile(
                  leading: CircleAvatar(child: Text('${entry.key + 1}')),
                  title: Text(entry.value),
                ),
              )),
        ],
      );
}

// ============================================================
//  EKRAN 6: LIMITY APLIKACJI I SESJE
// ============================================================

class SessionLimitsPage extends StatefulWidget {
  const SessionLimitsPage({super.key});

  @override
  State<SessionLimitsPage> createState() => _SessionLimitsPageState();
}

class _SessionLimitsPageState extends State<SessionLimitsPage>
    with WidgetsBindingObserver {
  List<AppLimit> limits = [];
  bool loading = true;
  List<Map<String, dynamic>> installedApps = [];
  Map<String, Uint8List?> appIcons = {};

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
    final jsonStr = await _sessionCall('getAppLimits');
    final appsStr = await _sessionCall('getInstalledApps');

    final loaded = <AppLimit>[];
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      for (final entry in data.entries) {
        final config = Map<String, dynamic>.from(entry.value as Map);
        loaded.add(AppLimit.fromJson(
          entry.key,
          cleanPackageName(entry.key),
          config,
        ));
      }
    } catch (_) {}

    final apps = <Map<String, dynamic>>[];
    try {
      final list = jsonDecode(appsStr) as List<dynamic>;
      for (final item in list) {
        if (item is Map) {
          apps.add(Map<String, dynamic>.from(item));
        }
      }
    } catch (_) {}

    if (apps.isNotEmpty) {
      final pkgs = apps.map((a) => a['packageName'] as String).toList();
      try {
        final rows = await const MethodChannel('beoffline/app_metadata')
            .invokeListMethod<dynamic>('getAppMetadata', pkgs);
        for (final row in rows ?? const []) {
          if (row is Map && row['packageName'] is String) {
            appIcons[row['packageName'] as String] = row['icon'] as Uint8List?;
          }
        }
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        limits = loaded;
        installedApps = apps;
        loading = false;
      });
    }
  }

  Future<void> _save() async {
    final data = <String, dynamic>{};
    for (final limit in limits) {
      data[limit.packageName] = limit.toJson();
    }
    await _sessionCall('setAppLimits', jsonEncode(data));
  }

  Future<Map<String, dynamic>?> _pickApp() async {
    final searchCtrl = TextEditingController();

    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final query = searchCtrl.text.trim().toLowerCase();
          final filtered = installedApps.where((app) {
            final name = (app['name'] ?? '').toString().toLowerCase();
            final pkg = (app['packageName'] ?? '').toString().toLowerCase();
            return name.contains(query) || pkg.contains(query);
          }).toList();

          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.8,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Wybierz aplikację do ograniczenia',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: searchCtrl,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Szukaj aplikacji...',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('Nie znaleziono aplikacji'))
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final app = filtered[index];
                            final name = (app['name'] ?? '') as String;
                            final pkg = (app['packageName'] ?? '') as String;
                            final icon = appIcons[pkg];

                            return ListTile(
                              leading: icon != null
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: Image.memory(icon, width: 40, height: 40, fit: BoxFit.cover),
                                    )
                                  : const CircleAvatar(child: Icon(Icons.apps)),
                              title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text(pkg, maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () => Navigator.pop(ctx, app),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showConfigDialog(Map<String, dynamic> app, {AppLimit? existing}) async {
    final name = (app['name'] ?? '') as String;
    final pkg = (app['packageName'] ?? '') as String;
    var daily = existing?.dailyLimitMinutes ?? 60;
    var session = existing?.sessionMinutes ?? 10;
    var wait = existing?.waitSeconds ?? 30;

    final result = await showDialog<AppLimit>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final totalSessions = session <= 0 ? 0 : (daily / session).ceil();

          return AlertDialog(
            title: Text(existing == null ? 'Ogranicz $name' : 'Edytuj: $name'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Liczba sesji: $totalSessions dziennie ($session min każda)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Dzienny limit: $daily min'),
                  Slider(
                    value: daily.toDouble(),
                    min: 15,
                    max: 240,
                    divisions: 15,
                    label: '$daily min',
                    onChanged: (v) => setDialogState(() => daily = v.round()),
                  ),
                  Text('Długość jednej sesji: $session min'),
                  Slider(
                    value: session.toDouble(),
                    min: 5,
                    max: 60,
                    divisions: 11,
                    label: '$session min',
                    onChanged: (v) => setDialogState(() => session = v.round()),
                  ),
                  Text('Czas oczekiwania przed wejściem: $wait s'),
                  Slider(
                    value: wait.toDouble(),
                    min: 0,
                    max: 120,
                    divisions: 12,
                    label: '$wait s',
                    onChanged: (v) => setDialogState(() => wait = v.round()),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
              FilledButton(
                onPressed: () => Navigator.pop(
                  ctx,
                  AppLimit(
                    packageName: pkg,
                    appName: name,
                    dailyLimitMinutes: daily,
                    sessionMinutes: session,
                    waitSeconds: wait,
                  ),
                ),
                child: const Text('Zapisz'),
              ),
            ],
          );
        },
      ),
    );

    if (result != null) {
      setState(() {
        if (existing != null) {
          limits.removeWhere((l) => l.packageName == existing.packageName);
        }
        limits.removeWhere((l) => l.packageName == result.packageName);
        limits.add(result);
      });
      await _save();
    }
  }

  Future<void> _addOrEditLimit({AppLimit? existing}) async {
    if (existing != null) {
      final appInfo = installedApps.firstWhere(
        (a) => a['packageName'] == existing.packageName,
        orElse: () => {'name': existing.appName, 'packageName': existing.packageName},
      );
      await _showConfigDialog(appInfo, existing: existing);
    } else {
      final app = await _pickApp();
      if (app != null) {
        await _showConfigDialog(app);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  FilledButton.icon(
                    onPressed: () => _addOrEditLimit(),
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
                            Icon(Icons.timer_off_outlined, size: 64, color: Colors.grey.withOpacity(0.4)),
                            const SizedBox(height: 12),
                            const Text('Brak aktywnych ograniczeń', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            const SizedBox(height: 4),
                            Text('Wybierz aplikację i ustal dla niej limit sesji', style: TextStyle(color: Colors.grey.shade600)),
                          ],
                        ),
                      ),
                    )
                  else
                    ...limits.map((limit) {
                      final icon = appIcons[limit.packageName];
                      final usedSec = store.rawUsageMap[limit.packageName] ?? 0;
                      final usedSessions = limit.sessionsUsed(usedSec);
                      final remainingSessions = limit.sessionsRemaining(usedSec);
                      final remainingSec = limit.timeRemainingSeconds(usedSec);
                      final progress = (usedSec / limit.dailyLimitSeconds).clamp(0.0, 1.0);

                      return Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: Colors.grey.withOpacity(0.2)),
                        ),
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  icon != null
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(10),
                                          child: Image.memory(icon, width: 44, height: 44, fit: BoxFit.cover),
                                        )
                                      : const CircleAvatar(child: Icon(Icons.apps)),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(limit.appName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                        Text('Limit: ${limit.dailyLimitMinutes} min dziennie (${limit.sessionMinutes}m/sesja)',
                                            style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: () => _addOrEditLimit(existing: limit),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () async {
                                      setState(() => limits.removeWhere((l) => l.packageName == limit.packageName));
                                      await _save();
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 8,
                                  backgroundColor: Colors.grey.withOpacity(0.15),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Czas dzisiaj:', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                                      Text('${formatDuration(usedSec)} / ${limit.dailyLimitMinutes}m',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                    ],
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      Text('Pozostało czasu:', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                                      Text(formatDuration(remainingSec),
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                            color: remainingSec == 0 ? Colors.red : null,
                                          )),
                                    ],
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text('Sesje:', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                                      Text('$usedSessions / ${limit.totalSessions} (zostało: $remainingSessions)',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              );
      },
    );
  }
}

// ============================================================
//  EKRAN 7: SERIA DNI (STREAK)
// ============================================================

class StreakPage extends StatefulWidget {
  const StreakPage({super.key});

  @override
  State<StreakPage> createState() => _StreakPageState();
}

class _StreakPageState extends State<StreakPage> with WidgetsBindingObserver {
  StreakInfo streak = StreakInfo.empty();

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
    final jsonStr = await _sessionCall('getStreak');
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (mounted) {
        setState(() => streak = StreakInfo.fromJson(data));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
  
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.grey.withOpacity(0.2)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Text('🔥', style: TextStyle(fontSize: 32)),
                      const SizedBox(height: 8),
                      Text('${streak.currentStreak}',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                      const Text('aktualna seria'),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.grey.withOpacity(0.2)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Text('🏆', style: TextStyle(fontSize: 32)),
                      const SizedBox(height: 8),
                      Text('${streak.bestStreak}',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                      const Text('najlepsza seria'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('Odznaki', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final threshold in [3, 7, 14, 30, 50, 100])
              Chip(
                label: Text('$threshold dni'),
                avatar: Text(streak.bestStreak >= threshold ? '✅' : '🔒'),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Text('Kalendarz aktywności', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.grey.withOpacity(0.2)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: List.generate(30, (i) {
                final date = DateTime.now().subtract(Duration(days: 29 - i));
                final key = dayKey(date);
                final active = streak.activeDays.contains(key);
                return Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: active ? Theme.of(context).colorScheme.primary : Colors.grey.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      '${date.day}',
                      style: TextStyle(
                        fontSize: 11,
                        color: active ? Theme.of(context).colorScheme.onPrimary : Colors.grey,
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
//  EKRAN 8: WYDARZENIA
// ============================================================

class EventsPage extends StatelessWidget {
  const EventsPage({super.key});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.event_outlined, size: 64, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('Warsztaty i wydarzenia', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Na razie nie ma żadnych wydarzeń.'),
            ],
          ),
        ),
      );
}

// ============================================================
//  EKRAN 9: USTAWIENIA
// ============================================================

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Wyczyścić dane aplikacji?'),
        content: const Text(
          'Usunięte zostaną cele i ustawienia. Profil oraz wynik quizu zostaną zachowane.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Wyczyść')),
        ],
      ),
    );
    if (confirmed == true) await store.resetData();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Wygląd', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('System')),
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode), label: Text('Jasny')),
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode), label: Text('Ciemny')),
            ],
            selected: {store.themeMode},
            onSelectionChanged: (selection) => store.setTheme(selection.first),
          ),
          const Divider(height: 32),
          Text('Dzienny limit urządzenia', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(formatDuration(store.limitSeconds), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          Slider(
            value: store.limitMinutes.toDouble(),
            min: 30,
            max: 480,
            divisions: 30,
            label: '${store.limitMinutes} min',
            onChanged: (value) => store.setLimit(value.round()),
          ),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Powiadomienia w tle'),
            subtitle: const Text('Wysyłaj alerty po przekroczeniu 50%, 80% i 100% limitów'),
            value: store.notificationsEnabled,
            onChanged: store.setNotifications,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Wyślij testowe powiadomienie'),
            onTap: () => AppNotifications.show('beOFFline', 'To jest testowe powiadomienie.'),
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_outline),
            title: Text(store.userName.isEmpty ? 'Profil' : store.userName, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('@${store.nickname}'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('Wyczyść dane aplikacji', style: TextStyle(color: Colors.red)),
            onTap: () => _confirmReset(context),
          ),
        ],
      ),
    );
  }
}

// ============================================================
//  FOCUS PAGE
// ============================================================

class FocusPage extends StatelessWidget {
  const FocusPage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final remaining = store.focusRemaining;
        final text = store.focusRunning
            ? '${remaining.inMinutes.toString().padLeft(2, '0')}:${remaining.inSeconds.remainder(60).toString().padLeft(2, '0')}'
            : 'Gotowe?';
        return Scaffold(
          appBar: AppBar(title: const Text('Tryb skupienia')),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('Pozostaw aplikację na ekranie. Wyjście z niej przerwie sesję.'),
              const SizedBox(height: 40),
              Center(child: Text(text, style: Theme.of(context).textTheme.displayMedium)),
              const SizedBox(height: 40),
              if (!store.focusRunning)
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  children: [10, 15, 25, 45].map((minutes) => ActionChip(
                    label: Text('$minutes min'),
                    onPressed: () => store.startFocus(minutes),
                  )).toList(),
                )
              else
                OutlinedButton.icon(
                  onPressed: store.cancelFocus,
                  icon: const Icon(Icons.stop),
                  label: const Text('Przerwij sesję'),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ============================================================
//  IDEAS PAGE
// ============================================================

class IdeasPage extends StatefulWidget {
  const IdeasPage({super.key});
  @override
  State<IdeasPage> createState() => _IdeasPageState();
}

class _IdeasPageState extends State<IdeasPage> {
  final random = math.Random();
  late String currentIdea = ideas[random.nextInt(ideas.length)];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Generator pomysłów')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lightbulb_outline, size: 72, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 24),
                Text(currentIdea, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => setState(() => currentIdea = ideas[random.nextInt(ideas.length)]),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Losuj kolejny pomysł'),
                ),
              ],
            ),
          ),
        ),
      );
}

// ============================================================
//  REGISTRATION
// ============================================================

class RegistrationPage extends StatefulWidget {
  const RegistrationPage({super.key});
  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

class _RegistrationPageState extends State<RegistrationPage> {
  final pageController = PageController();
  final nameController = TextEditingController();
  final nicknameController = TextEditingController();
  final otherController = TextEditingController();
  static const sources = [
    'Szkoła',
    'Znajomi',
    'Rodzina',
    'Social media',
    'Plakat lub wydarzenie',
    'Inne',
  ];
  int step = 0;
  String? selectedSource;
  bool saving = false;
  String? errorText;

  @override
  void dispose() {
    pageController.dispose();
    nameController.dispose();
    nicknameController.dispose();
    otherController.dispose();
    super.dispose();
  }

  bool get canContinue {
    if (step == 0) return nameController.text.trim().length >= 2;
    if (step == 1) {
      return selectedSource != null &&
          (selectedSource != 'Inne' || otherController.text.trim().length >= 2);
    }
    final nick = nicknameController.text.trim();
    return nick.length >= 3 && nick.length <= 16 && !nick.contains(' ');
  }

  Future<void> next() async {
    if (!canContinue || saving) return;
    if (step < 2) {
      await pageController.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    setState(() => saving = true);
    final error = await store.registerProfile(
      name: nameController.text,
      source: selectedSource == 'Inne' ? 'Inne: ${otherController.text.trim()}' : selectedSource!,
      chosenNickname: nicknameController.text,
    );
    if (mounted) {
      setState(() {
        saving = false;
        errorText = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const questions = [
      'Cześć!\nJak się nazywasz?',
      'Gdzie o nas\nusłyszałeś?',
      'Wybierz swój\nnickname',
    ];
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const _AppLogo(height: 72),
              const SizedBox(height: 28),
              Expanded(
                child: PageView(
                  controller: pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (value) => setState(() => step = value),
                  children: [
                    _Question(
                      title: questions[0],
                      child: TextField(
                        controller: nameController,
                        onChanged: (value) => setState(() {}),
                        decoration: const InputDecoration(hintText: 'Twoje imię', border: OutlineInputBorder()),
                      ),
                    ),
                    _Question(
                      title: questions[1],
                      child: Column(
                        children: [
                          ...sources.map((source) => ListTile(
                                title: Text(source),
                                selected: selectedSource == source,
                                onTap: () => setState(() => selectedSource = source),
                              )),
                          if (selectedSource == 'Inne')
                            TextField(
                              controller: otherController,
                              onChanged: (value) => setState(() {}),
                              decoration: const InputDecoration(hintText: 'Napisz skąd', border: OutlineInputBorder()),
                            ),
                        ],
                      ),
                    ),
                    _Question(
                      title: questions[2],
                      child: TextField(
                        controller: nicknameController,
                        onChanged: (value) => setState(() {}),
                        decoration: const InputDecoration(hintText: 'np. oliwia_13', border: OutlineInputBorder()),
                      ),
                    ),
                  ],
                ),
              ),
              if (errorText != null)
                Text(errorText!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: canContinue && !saving ? next : null,
                  child: Text(saving ? 'Zapisywanie...' : step == 2 ? 'Zaczynamy' : 'Dalej'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Question extends StatelessWidget {
  final String title;
  final Widget child;
  const _Question({required this.title, required this.child});
  @override
  Widget build(BuildContext context) => ListView(
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 24),
          child,
        ],
      );
}