import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';

const String appUrl = 'http://45.133.251.193/habits/';
const String apiBase = 'http://45.133.251.193/habits-api';

final FlutterLocalNotificationsPlugin notificationsPlugin = FlutterLocalNotificationsPlugin();

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Дела',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark),
      home: const WebScreen(),
    );
  }
}

class WebScreen extends StatefulWidget {
  const WebScreen({super.key});

  @override
  State<WebScreen> createState() => _WebScreenState();
}

class _WebScreenState extends State<WebScreen> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (_) => setState(() => _loading = false),
        ),
      )
      ..loadRequest(Uri.parse(appUrl));

    _setupNotifications();
  }

  Future<void> _setupNotifications() async {
    try {
      await initNotifications();
      await scheduleAllReminders();
    } catch (_) {
      // Notifications are a bonus feature — never let a failure block the app.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loading) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}

Future<void> initNotifications() async {
  tzdata.initializeTimeZones();
  try {
    final String currentTimeZone = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(currentTimeZone));
  } catch (_) {
    tz.setLocalLocation(tz.getLocation('Europe/Moscow'));
  }

  const iosSettings = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const initSettings = InitializationSettings(iOS: iosSettings);
  await notificationsPlugin.initialize(initSettings);
  await notificationsPlugin
      .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
      ?.requestPermissions(alert: true, badge: true, sound: true);
}

Future<void> scheduleWeekly({
  required int id,
  required String title,
  required String body,
  required int weekday, // 1 = Monday ... 7 = Sunday
  required int hour,
  required int minute,
}) async {
  final now = tz.TZDateTime.now(tz.local);
  var scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
  while (scheduled.weekday != weekday || scheduled.isBefore(now)) {
    scheduled = scheduled.add(const Duration(days: 1));
  }
  await notificationsPlugin.zonedSchedule(
    id,
    title,
    body,
    scheduled,
    const NotificationDetails(
      iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
    ),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
  );
}

/// Fetches habits from the backend and (re)schedules local reminders for the
/// times set on each habit. Safe to call every time the app opens — it wipes
/// and rebuilds the notification queue so edits made on the website are picked up.
Future<void> scheduleAllReminders() async {
  await notificationsPlugin.cancelAll();

  try {
    final habitsResp = await http.get(Uri.parse('$apiBase/habits')).timeout(const Duration(seconds: 10));
    if (habitsResp.statusCode == 200) {
      final data = jsonDecode(habitsResp.body) as Map<String, dynamic>;
      final habits = (data['habits'] as List? ?? []).cast<Map<String, dynamic>>();
      for (final h in habits) {
        final reminder = (h['reminderTime'] as String?) ?? '';
        if (reminder.isEmpty) continue;
        final parts = reminder.split(':');
        if (parts.length != 2) continue;
        final hour = int.tryParse(parts[0]);
        final minute = int.tryParse(parts[1]);
        if (hour == null || minute == null) continue;
        final targetDays = (h['targetDays'] as String?) ?? '1111111';
        final name = (h['name'] as String?) ?? 'Дело';
        final id = h['id'] as int;
        for (int i = 0; i < 7 && i < targetDays.length; i++) {
          if (targetDays[i] != '1') continue;
          await scheduleWeekly(
            id: 1000 + id * 10 + i,
            title: 'Пора: $name',
            body: 'Не забудь отметить выполнение в приложении.',
            weekday: i + 1,
            hour: hour,
            minute: minute,
          );
        }
      }
    }
  } catch (_) {
    // ignore — will retry next launch
  }
}
