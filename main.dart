import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:intl/intl.dart';

// ── Notifications setup ───────────────────────────────────────────────────────
final FlutterLocalNotificationsPlugin notifPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  tz.initializeTimeZones();
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const ios = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  await notifPlugin.initialize(
    const InitializationSettings(android: android, iOS: ios),
  );
  await notifPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

Future<void> scheduleNotif(int id, String title, String body,
    DateTime scheduledDate) async {
  await notifPlugin.zonedSchedule(
    id,
    title,
    body,
    tz.TZDateTime.from(scheduledDate, tz.local),
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'taskora_channel', 'Taskora Notifications',
        channelDescription: 'Task reminders and alerts',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: DarwinNotificationDetails(),
    ),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    uiLocalNotificationDateInterpretation:
        UILocalNotificationDateInterpretation.absoluteTime,
  );
}

Future<void> showInstantNotif(int id, String title, String body) async {
  await notifPlugin.show(
    id,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'taskora_channel', 'Taskora Notifications',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    ),
  );
}

// ── Main ──────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('tasksBox');
  await Hive.openBox('settingsBox');
  await initNotifications();
  runApp(const TaskoraApp());
}

// ── App ───────────────────────────────────────────────────────────────────────
class TaskoraApp extends StatelessWidget {
  const TaskoraApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Taskora',
      theme: ThemeData(
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B4BB8)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

// ── Colors ────────────────────────────────────────────────────────────────────
const kPrimary   = Color(0xFF3B4BB8);
const kAccent    = Color(0xFF6C8EFF);
const kBg        = Color(0xFFF0F2F8);
const kCard      = Colors.white;
const kDark      = Color(0xFF1A1B2E);

const priorityColors = {
  'High':   Color(0xFFEF4444),
  'Medium': Color(0xFFF59E0B),
  'Low':    Color(0xFF22C55E),
};
const categoryColors = {
  'Work':     Color(0xFF6C63FF),
  'Study':    Color(0xFF3B82F6),
  'Personal': Color(0xFFEC4899),
  'Health':   Color(0xFF10B981),
};

// ── Task Model ────────────────────────────────────────────────────────────────
class Task {
  int id;
  String title;
  bool done;
  String priority;
  String category;
  String dueDate;
  String dueTime;
  String notes;

  Task({
    required this.id,
    required this.title,
    this.done = false,
    this.priority = 'Medium',
    this.category = 'Work',
    this.dueDate = '',
    this.dueTime = '',
    this.notes = '',
  });

  Map<String, dynamic> toMap() => {
        'id': id, 'title': title, 'done': done,
        'priority': priority, 'category': category,
        'dueDate': dueDate, 'dueTime': dueTime, 'notes': notes,
      };

  static Task fromMap(Map m) => Task(
        id: m['id'], title: m['title'], done: m['done'],
        priority: m['priority'], category: m['category'],
        dueDate: m['dueDate'], dueTime: m['dueTime'], notes: m['notes'],
      );

  bool get isOverdue {
    if (done || dueDate.isEmpty) return false;
    try {
      final dateStr = dueTime.isNotEmpty ? '$dueDate $dueTime' : '$dueDate 23:59';
      final due = DateFormat('yyyy-MM-dd HH:mm').parse(dateStr);
      return due.isBefore(DateTime.now());
    } catch (_) { return false; }
  }

  DateTime? get dueDateTime {
    if (dueDate.isEmpty) return null;
    try {
      final dateStr = dueTime.isNotEmpty ? '$dueDate $dueTime' : '$dueDate 23:59';
      return DateFormat('yyyy-MM-dd HH:mm').parse(dateStr);
    } catch (_) { return null; }
  }
}

// ── Home Screen ───────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final box = Hive.box('tasksBox');
  final settingsBox = Hive.box('settingsBox');
  List<Task> tasks = [];
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _loadTasks();
    _scheduleDailySummary();
    _checkOverdue();
  }

  void _loadTasks() {
    final raw = box.get('tasks', defaultValue: []);
    setState(() {
      tasks = (raw as List).map((e) => Task.fromMap(Map<String, dynamic>.from(e))).toList();
    });
  }

  void _saveTasks() {
    box.put('tasks', tasks.map((t) => t.toMap()).toList());
  }

  void _scheduleDailySummary() async {
    final timeStr = settingsBox.get('summaryTime', defaultValue: '08:00') as String;
    final parts = timeStr.split(':');
    final h = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    var target = DateTime.now().copyWith(hour: h, minute: m, second: 0);
    if (target.isBefore(DateTime.now())) {
      target = target.add(const Duration(days: 1));
    }
    final pending = tasks.where((t) => !t.done).length;
    final overdue = tasks.where((t) => t.isOverdue).length;
    await notifPlugin.cancel(9999);
    await scheduleNotif(
      9999,
      '☀️ Taskora Daily Summary',
      '$pending tasks pending${overdue > 0 ? ", $overdue overdue" : ""}. Have a productive day!',
      target,
    );
  }

  void _checkOverdue() {
    for (final task in tasks) {
      if (task.isOverdue) {
        showInstantNotif(
          task.id + 10000,
          '⚠️ Task Overdue',
          '"${task.title}" is overdue! Please complete it.',
        );
      }
    }
  }

  void _scheduleTaskNotifs(Task task) async {
    if (task.dueDateTime == null) return;
    final due = task.dueDateTime!;
    final now = DateTime.now();
    if (due.isAfter(now)) {
      await scheduleNotif(task.id, '🔔 Task Due Now!',
          '"${task.title}" is due right now!', due);
    }
    final remind15 = due.subtract(const Duration(minutes: 15));
    if (remind15.isAfter(now)) {
      await scheduleNotif(task.id + 5000, '⏰ Due in 15 mins',
          '"${task.title}" is due at ${task.dueTime}', remind15);
    }
  }

  void _addTask(Task task) {
    setState(() { tasks.add(task); });
    _saveTasks();
    _scheduleTaskNotifs(task);
  }

  void _updateTask(Task task) {
    setState(() {
      final i = tasks.indexWhere((t) => t.id == task.id);
      if (i >= 0) tasks[i] = task;
    });
    _saveTasks();
    _scheduleTaskNotifs(task);
  }

  void _deleteTask(int id) async {
    await notifPlugin.cancel(id);
    await notifPlugin.cancel(id + 5000);
    setState(() { tasks.removeWhere((t) => t.id == id); });
    _saveTasks();
  }

  void _toggleTask(int id) {
    setState(() {
      final i = tasks.indexWhere((t) => t.id == id);
      if (i >= 0) tasks[i].done = !tasks[i].done;
    });
    _saveTasks();
  }

  double get progress {
    if (tasks.isEmpty) return 0;
    return tasks.where((t) => t.done).length / tasks.length;
  }

  String get greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good Morning';
    if (h < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      _buildTasksTab(),
      CalendarScreen(tasks: tasks),
      StatsScreen(tasks: tasks),
    ];

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(child: screens[_tab]),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Color(0x0F000000), blurRadius: 20, offset: Offset(0, -4))],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _NavItem(icon: const _TasksIcon(), label: 'Tasks',    active: _tab == 0, onTap: () => setState(() => _tab = 0)),
                _NavItem(icon: const _CalendarIcon(), label: 'Calendar', active: _tab == 1, onTap: () => setState(() => _tab = 1)),
                _NavItem(icon: const _StatsIcon(),    label: 'Stats',    active: _tab == 2, onTap: () => setState(() => _tab = 2)),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: _tab == 0
          ? FloatingActionButton(
              backgroundColor: kPrimary,
              onPressed: () => _showTaskModal(context, null),
              child: const Icon(Icons.add, color: Colors.white, size: 30),
            )
          : null,
    );
  }

  Widget _buildTasksTab() {
    final overdueCount = tasks.where((t) => t.isOverdue).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(DateFormat('EEEE, d MMM').format(DateTime.now()),
                    style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('$greeting, Himanshu',
                    style: const TextStyle(color: kDark, fontSize: 22, fontWeight: FontWeight.w900)),
              ]),
              Row(children: [
                _iconBtn(Icons.notifications_outlined, () => _showNotifSettings(context)),
                const SizedBox(width: 8),
                _iconBtn(Icons.settings_outlined, () => _showSummaryTimePicker(context)),
              ]),
            ],
          ),
        ),

        // Overdue banner
        if (overdueCount > 0)
          Container(
            margin: const EdgeInsets.fromLTRB(22, 12, 22, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF5F5),
              border: Border.all(color: const Color(0xFFFEE2E2)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(children: [
              const Text('⚠️', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$overdueCount Overdue Task${overdueCount > 1 ? "s" : ""}',
                    style: const TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.w800, fontSize: 13)),
                const Text('Please complete them soon!',
                    style: TextStyle(color: Color(0xFFF87171), fontSize: 11)),
              ])),
              TextButton(
                onPressed: () => _showDailySummary(context),
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFFEF4444),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('View', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
              )
            ]),
          ),

        // Progress Ring
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: SizedBox(
              width: 120, height: 120,
              child: Stack(alignment: Alignment.center, children: [
                CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 10,
                  backgroundColor: const Color(0xFFEEF0F7),
                  valueColor: const AlwaysStoppedAnimation<Color>(kPrimary),
                  strokeCap: StrokeCap.round,
                ),
                Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${(progress * 100).toInt()}',
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: kDark)),
                  const Text('%', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey)),
                ]),
              ]),
            ),
          ),
        ),

        // Daily Summary btn
        Center(
          child: TextButton.icon(
            onPressed: () => _showDailySummary(context),
            icon: const Text('☀️'),
            label: const Text('View Daily Summary',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
            style: TextButton.styleFrom(
              foregroundColor: kPrimary,
              backgroundColor: const Color(0xFFF5F3FF),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            ),
          ),
        ),
        const SizedBox(height: 10),

        // Task list
        Expanded(
          child: tasks.isEmpty
              ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('📋', style: TextStyle(fontSize: 40)),
                  SizedBox(height: 8),
                  Text('No tasks yet!', style: TextStyle(color: Colors.grey)),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  itemCount: tasks.length,
                  itemBuilder: (ctx, i) => _buildTaskTile(tasks[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildTaskTile(Task task) {
    return Dismissible(
      key: Key('${task.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Colors.red.shade100,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.red),
      ),
      onDismissed: (_) => _deleteTask(task.id),
      child: GestureDetector(
        onTap: () => _showTaskModal(context, task),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: task.isOverdue ? const Color(0xFFFEE2E2) : Colors.transparent,
            ),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8)],
          ),
          child: Row(children: [
            GestureDetector(
              onTap: () => _toggleTask(task.id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 22, height: 22,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: task.done ? kPrimary : task.isOverdue
                        ? const Color(0xFFEF4444) : const Color(0xFFD0D4E8),
                    width: 2,
                  ),
                  color: task.done ? kPrimary : Colors.transparent,
                ),
                child: task.done
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '${task.isOverdue ? "⚠️ " : ""}${task.title}',
                style: TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 14,
                  color: task.isOverdue ? const Color(0xFFEF4444) : kDark,
                  decoration: task.done ? TextDecoration.lineThrough : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (task.dueDate.isNotEmpty || task.category.isNotEmpty)
                const SizedBox(height: 4),
              Wrap(spacing: 6, children: [
                if (task.dueDate.isNotEmpty)
                  Text(
                    '📅 ${_dayLabel(task.dueDate)}${task.dueTime.isNotEmpty ? " ${task.dueTime}" : ""}',
                    style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w600,
                      color: task.isOverdue ? const Color(0xFFEF4444) : Colors.grey,
                    ),
                  ),
                if (task.category.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: (categoryColors[task.category] ?? kPrimary).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(task.category,
                        style: TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w700,
                          color: categoryColors[task.category] ?? kPrimary,
                        )),
                  ),
              ]),
            ])),
            const SizedBox(width: 8),
            Row(children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: priorityColors[task.priority] ?? Colors.grey,
                ),
              ),
              const SizedBox(width: 4),
              Text(task.priority,
                  style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700,
                    color: priorityColors[task.priority] ?? Colors.grey,
                  )),
            ]),
          ]),
        ),
      ),
    );
  }

  String _dayLabel(String dateStr) {
    try {
      final d = DateFormat('yyyy-MM-dd').parse(dateStr);
      final today = DateTime.now(); final todayOnly = DateTime(today.year, today.month, today.day);
      final diff = DateTime(d.year, d.month, d.day).difference(todayOnly).inDays;
      if (diff == 0) return 'Today';
      if (diff == 1) return 'Tomorrow';
      if (diff < 0) return '${diff.abs()}d ago';
      return DateFormat('d MMM').format(d);
    } catch (_) { return dateStr; }
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 20, color: Colors.grey.shade600),
      ),
    );
  }

  void _showTaskModal(BuildContext context, Task? task) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TaskModal(
        task: task,
        onSave: (t) { task == null ? _addTask(t) : _updateTask(t); },
      ),
    );
  }

  void _showDailySummary(BuildContext context) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DailySummaryModal(tasks: tasks),
    );
  }

  void _showNotifSettings(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Notifications are enabled! 🔔'), backgroundColor: kPrimary),
    );
  }

  void _showSummaryTimePicker(BuildContext context) async {
    final current = settingsBox.get('summaryTime', defaultValue: '08:00') as String;
    final parts = current.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
    );
    if (picked != null) {
      final timeStr = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      await settingsBox.put('summaryTime', timeStr);
      _scheduleDailySummary();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Daily summary set for $timeStr ⏰'), backgroundColor: kPrimary),
        );
      }
    }
  }
}

// ── Task Modal ────────────────────────────────────────────────────────────────
class TaskModal extends StatefulWidget {
  final Task? task;
  final Function(Task) onSave;
  const TaskModal({super.key, this.task, required this.onSave});
  @override State<TaskModal> createState() => _TaskModalState();
}

class _TaskModalState extends State<TaskModal> {
  late TextEditingController titleCtrl;
  late TextEditingController notesCtrl;
  String priority = 'Medium';
  String category = 'Work';
  DateTime? dueDate;
  TimeOfDay? dueTime;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    titleCtrl = TextEditingController(text: t?.title ?? '');
    notesCtrl = TextEditingController(text: t?.notes ?? '');
    priority = t?.priority ?? 'Medium';
    category = t?.category ?? 'Work';
    if (t?.dueDate.isNotEmpty == true) {
      try { dueDate = DateFormat('yyyy-MM-dd').parse(t!.dueDate); } catch (_) {}
    }
    if (t?.dueTime.isNotEmpty == true) {
      try {
        final p = t!.dueTime.split(':');
        dueTime = TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        left: 22, right: 22, top: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 36,
      ),
      child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(4)))),
          const SizedBox(height: 16),
          Text(widget.task != null ? 'Edit Task' : 'Add Task',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: kDark)),
          const SizedBox(height: 16),
          TextField(
            controller: titleCtrl,
            decoration: InputDecoration(
              hintText: 'Task Title',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFEEF0F8))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFEEF0F8))),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
          const SizedBox(height: 12),

          // Date + Time
          Row(children: [
            Expanded(child: _fieldBox('📅 Due Date', GestureDetector(
              onTap: () async {
                final d = await showDatePicker(context: context,
                    initialDate: dueDate ?? DateTime.now(),
                    firstDate: DateTime.now().subtract(const Duration(days: 365)),
                    lastDate: DateTime.now().add(const Duration(days: 365)));
                if (d != null) setState(() => dueDate = d);
              },
              child: Text(dueDate != null ? DateFormat('d MMM yyyy').format(dueDate!) : 'Select',
                  style: TextStyle(fontSize: 13, color: dueDate != null ? kDark : Colors.grey)),
            ))),
            const SizedBox(width: 10),
            Expanded(child: _fieldBox('🕐 Time', GestureDetector(
              onTap: () async {
                final t = await showTimePicker(context: context,
                    initialTime: dueTime ?? TimeOfDay.now());
                if (t != null) setState(() => dueTime = t);
              },
              child: Text(dueTime != null ? dueTime!.format(context) : 'Select',
                  style: TextStyle(fontSize: 13, color: dueTime != null ? kDark : Colors.grey)),
            ))),
          ]),
          const SizedBox(height: 10),

          // Priority
          _fieldBox('🔴 Priority', Wrap(spacing: 8, children:
            ['High', 'Medium', 'Low'].map((p) => GestureDetector(
              onTap: () => setState(() => priority = p),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: priority == p ? priorityColors[p] : const Color(0xFFF0F2F8),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(p, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13,
                    color: priority == p ? Colors.white : Colors.grey.shade600)),
              ),
            )).toList()
          )),
          const SizedBox(height: 10),

          // Category
          _fieldBox('🟡 Category', Wrap(spacing: 8, runSpacing: 8, children:
            ['Work', 'Study', 'Personal', 'Health'].map((c) => GestureDetector(
              onTap: () => setState(() => category = c),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: category == c ? categoryColors[c] : const Color(0xFFF0F2F8),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(c, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13,
                    color: category == c ? Colors.white : Colors.grey.shade600)),
              ),
            )).toList()
          )),
          const SizedBox(height: 10),

          // Notes
          _fieldBox('⚫ Notes', TextField(
            controller: notesCtrl,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Add a note...', border: InputBorder.none, isDense: true),
            style: const TextStyle(fontSize: 13),
          )),
          const SizedBox(height: 18),

          SizedBox(width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                if (titleCtrl.text.trim().isEmpty) return;
                final task = Task(
                  id: widget.task?.id ?? DateTime.now().millisecondsSinceEpoch,
                  title: titleCtrl.text.trim(),
                  done: widget.task?.done ?? false,
                  priority: priority, category: category,
                  dueDate: dueDate != null ? DateFormat('yyyy-MM-dd').format(dueDate!) : '',
                  dueTime: dueTime != null
                      ? '${dueTime!.hour.toString().padLeft(2, '0')}:${dueTime!.minute.toString().padLeft(2, '0')}' : '',
                  notes: notesCtrl.text,
                );
                widget.onSave(task);
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: kPrimary, foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              child: const Text('Save Task', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
          ),
        ],
      )),
    );
  }

  Widget _fieldBox(String label, Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFF7F8FD), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        const SizedBox(height: 8),
        child,
      ]),
    );
  }
}

// ── Daily Summary Modal ───────────────────────────────────────────────────────
class DailySummaryModal extends StatelessWidget {
  final List<Task> tasks;
  const DailySummaryModal({super.key, required this.tasks});

  @override
  Widget build(BuildContext context) {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final todayTasks = tasks.where((t) => t.dueDate == today).toList();
    final overdue = tasks.where((t) => t.isOverdue).toList();
    final done = tasks.where((t) => t.done).length;

    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      padding: const EdgeInsets.all(22),
      child: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(4)))),
          const SizedBox(height: 16),
          Row(children: [
            const Text('☀️', style: TextStyle(fontSize: 28)),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Daily Summary', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: kDark)),
              Text(DateFormat('EEEE, d MMMM').format(DateTime.now()),
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            _statCard('✅', '$done', 'Done', null),
            const SizedBox(width: 10),
            _statCard('📋', '${tasks.length - done}', 'Pending', null),
            const SizedBox(width: 10),
            _statCard('🔥', '${overdue.length}', 'Overdue',
                overdue.isNotEmpty ? const Color(0xFFEF4444) : const Color(0xFF22C55E)),
          ]),
          const SizedBox(height: 16),
          const Text("📅 Today's Tasks", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: kDark)),
          const SizedBox(height: 8),
          if (todayTasks.isEmpty) const Text('No tasks scheduled for today.', style: TextStyle(color: Colors.grey, fontSize: 13)),
          ...todayTasks.map((t) => _summaryTile(t.title, priorityColors[t.priority] ?? Colors.grey, t.dueTime, false)),
          if (overdue.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('⚠️ Overdue', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFFEF4444))),
            const SizedBox(height: 8),
            ...overdue.map((t) => _summaryTile(t.title, const Color(0xFFEF4444), t.dueDate, true)),
          ],
          const SizedBox(height: 16),
          SizedBox(width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: kPrimary, foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text('Got it! 👍', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            ),
          ),
        ],
      )),
    );
  }

  Widget _statCard(String icon, String val, String label, Color? color) {
    return Expanded(child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFF7F8FD), borderRadius: BorderRadius.circular(14)),
      child: Column(children: [
        Text(icon, style: const TextStyle(fontSize: 20)),
        const SizedBox(height: 4),
        Text(val, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: color ?? kDark)),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
      ]),
    ));
  }

  Widget _summaryTile(String title, Color color, String sub, bool isOverdue) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isOverdue ? const Color(0xFFFFF5F5) : const Color(0xFFF7F8FD),
        borderRadius: BorderRadius.circular(12),
        border: isOverdue ? Border.all(color: const Color(0xFFFEE2E2)) : null,
      ),
      child: Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13,
            color: isOverdue ? const Color(0xFFEF4444) : kDark))),
        if (sub.isNotEmpty) Text(sub, style: TextStyle(fontSize: 11, color: isOverdue ? const Color(0xFFEF4444) : Colors.grey, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

// ── Calendar Screen ───────────────────────────────────────────────────────────
class CalendarScreen extends StatefulWidget {
  final List<Task> tasks;
  const CalendarScreen({super.key, required this.tasks});
  @override State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _month;
  late DateTime _selected;

  @override
  void initState() {
    super.initState();
    _month = DateTime.now();
    _selected = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final firstDay = DateTime(_month.year, _month.month, 1).weekday % 7;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final selStr = DateFormat('yyyy-MM-dd').format(_selected);
    final dayTasks = widget.tasks.where((t) => t.dueDate == selStr).toList();

    return Container(
      color: const Color(0xFF0D0F1E),
      child: SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton(icon: const Icon(Icons.chevron_left, color: Colors.white), onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1))),
            Text(DateFormat('MMMM yyyy').format(_month), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
            IconButton(icon: const Icon(Icons.chevron_right, color: Colors.white), onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1))),
          ]),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: ['S','M','T','W','T','F','S'].map((d) =>
                Text(d, style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.w700))
              ).toList()),
          const SizedBox(height: 8),
          GridView.count(
            shrinkWrap: true, crossAxisCount: 7, mainAxisSpacing: 4,
            children: [
              ...List.generate(firstDay, (_) => const SizedBox()),
              ...List.generate(daysInMonth, (i) {
                final day = i + 1;
                final date = DateTime(_month.year, _month.month, day);
                final isToday = DateFormat('yyyy-MM-dd').format(date) == DateFormat('yyyy-MM-dd').format(DateTime.now());
                final isSel = DateFormat('yyyy-MM-dd').format(date) == selStr;
                return GestureDetector(
                  onTap: () => setState(() => _selected = date),
                  child: Container(
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: isSel ? kPrimary : isToday ? kPrimary.withOpacity(0.25) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(child: Text('$day',
                        style: TextStyle(color: isSel ? Colors.white : Colors.grey.shade400,
                            fontSize: 13, fontWeight: isSel ? FontWeight.w800 : FontWeight.w500))),
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: dayTasks.isEmpty
              ? const Center(child: Text('No tasks for this day', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: dayTasks.length,
                  itemBuilder: (_, i) {
                    final t = dayTasks[i];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(color: const Color(0xFF181B2E), borderRadius: BorderRadius.circular(14)),
                      child: Row(children: [
                        Container(width: 9, height: 9, decoration: BoxDecoration(shape: BoxShape.circle, color: priorityColors[t.priority])),
                        const SizedBox(width: 10),
                        Expanded(child: Text(t.title, style: TextStyle(color: t.isOverdue ? const Color(0xFFEF4444) : Colors.white, fontWeight: FontWeight.w600, fontSize: 14))),
                        if (t.dueTime.isNotEmpty) Text(t.dueTime, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                        if (t.isOverdue) Container(margin: const EdgeInsets.only(left: 8), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: const Color(0xFFEF444422), borderRadius: BorderRadius.circular(6)),
                            child: const Text('Overdue', style: TextStyle(color: Color(0xFFEF4444), fontSize: 10, fontWeight: FontWeight.w700))),
                      ]),
                    );
                  },
                )),
        ]),
      )),
    );
  }
}

// ── Stats Screen ──────────────────────────────────────────────────────────────
class StatsScreen extends StatelessWidget {
  final List<Task> tasks;
  const StatsScreen({super.key, required this.tasks});

  @override
  Widget build(BuildContext context) {
    final done = tasks.where((t) => t.done).length;
    final pct = tasks.isEmpty ? 0 : (done / tasks.length * 100).round();
    final weekData = [40, 55, 35, 70, 60, 80, pct];
    final maxVal = weekData.reduce((a, b) => a > b ? a : b).toDouble();

    return Container(
      color: const Color(0xFF0D0F1E),
      child: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Statistics', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20)),
          const Text('Weekly Progress', style: TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 20),

          // Bar chart
          SizedBox(height: 100, child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(7, (i) {
              final h = maxVal > 0 ? (weekData[i] / maxVal * 70) : 8.0;
              return Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Container(
                  height: h.toDouble(), margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    gradient: i == 6 ? const LinearGradient(colors: [Color(0xFF6C63FF), Color(0xFF48C9B0)], begin: Alignment.topCenter, end: Alignment.bottomCenter) : null,
                    color: i != 6 ? kPrimary.withOpacity(0.25) : null,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  ),
                ),
                const SizedBox(height: 4),
                Text(['S','M','T','W','T','F','S'][i], style: const TextStyle(color: Colors.grey, fontSize: 10)),
              ]));
            }),
          )),
          const SizedBox(height: 20),

          // Stats
          Row(children: [
            _statBox('●', '$pct%', 'Completed'),
            const SizedBox(width: 10),
            _statBox('👤', '5 Day', 'Day Streak'),
            const SizedBox(width: 10),
            _statBox('⏱', '3h 20m', 'Focus Time'),
          ]),
          const SizedBox(height: 20),

          const Text('BY CATEGORY', style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
          const SizedBox(height: 12),
          ...categoryColors.entries.map((e) {
            final cat = e.key; final color = e.value;
            final catTasks = tasks.where((t) => t.category == cat).toList();
            final catDone = catTasks.where((t) => t.done).length;
            final p = catTasks.isEmpty ? 0.0 : catDone / catTasks.length;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(cat, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                  Text('${catTasks.length} tasks', style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 6),
                ClipRRect(borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(value: p, minHeight: 5,
                      backgroundColor: Colors.white.withOpacity(0.08),
                      valueColor: AlwaysStoppedAnimation<Color>(color))),
              ]),
            );
          }),
        ]),
      )),
    );
  }

  Widget _statBox(String icon, String val, String label) {
    return Expanded(child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(14)),
      child: Column(children: [
        Text(icon, style: const TextStyle(fontSize: 18, color: kPrimary)),
        const SizedBox(height: 4),
        Text(val, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10), textAlign: TextAlign.center),
      ]),
    ));
  }
}

// ── Custom Nav Item ───────────────────────────────────────────────────────────
class _NavItem extends StatelessWidget {
  final Widget icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _NavItem({required this.icon, required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: active ? kPrimary.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ColorFiltered(
            colorFilter: ColorFilter.mode(active ? kPrimary : Colors.grey.shade400, BlendMode.srcIn),
            child: icon,
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(
            fontSize: 11, fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active ? kPrimary : Colors.grey.shade400,
          )),
        ]),
      ),
    );
  }
}

// ── Tasks SVG Icon ────────────────────────────────────────────────────────────
class _TasksIcon extends StatelessWidget {
  const _TasksIcon();
  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: const Size(22, 22), painter: _TasksPainter());
  }
}

class _TasksPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1.8..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    final r = size.width / 22;
    // Checkbox 1 - checked
    final rr = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, 9*r, 9*r), Radius.circular(2.5*r));
    canvas.drawRRect(rr, p);
    final cp = Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1.6..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    final path = Path()..moveTo(2*r, 4.5*r)..lineTo(4*r, 7*r)..lineTo(7*r, 2.5*r);
    canvas.drawPath(path, cp);
    // Lines for task 1
    canvas.drawLine(Offset(12*r, 3*r), Offset(22*r, 3*r), p);
    canvas.drawLine(Offset(12*r, 6.5*r), Offset(19*r, 6.5*r), p);
    // Checkbox 2 - unchecked
    final rr2 = RRect.fromRectAndRadius(Rect.fromLTWH(0, 13*r, 9*r, 9*r), Radius.circular(2.5*r));
    canvas.drawRRect(rr2, p);
    // Lines for task 2
    canvas.drawLine(Offset(12*r, 16*r), Offset(22*r, 16*r), p);
    canvas.drawLine(Offset(12*r, 19.5*r), Offset(17*r, 19.5*r), p);
  }
  @override bool shouldRepaint(_) => false;
}

// ── Calendar SVG Icon ─────────────────────────────────────────────────────────
class _CalendarIcon extends StatelessWidget {
  const _CalendarIcon();
  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: const Size(22, 22), painter: _CalendarPainter());
  }
}

class _CalendarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1.8..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    final r = size.width / 22;
    // Outer rect
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(1*r, 3*r, 20*r, 18*r), Radius.circular(3*r)), p);
    // Top bar line
    canvas.drawLine(Offset(1*r, 9*r), Offset(21*r, 9*r), p);
    // Left pin
    canvas.drawLine(Offset(7*r, 0.5*r), Offset(7*r, 5*r), p);
    // Right pin
    canvas.drawLine(Offset(15*r, 0.5*r), Offset(15*r, 5*r), p);
    // Dots (days)
    final dp = Paint()..color = Colors.black..style = PaintingStyle.fill;
    for (var row = 0; row < 2; row++) {
      for (var col = 0; col < 4; col++) {
        canvas.drawCircle(Offset((4 + col * 4.5)*r, (12.5 + row * 4)*r), 1.2*r, dp);
      }
    }
  }
  @override bool shouldRepaint(_) => false;
}

// ── Stats SVG Icon ────────────────────────────────────────────────────────────
class _StatsIcon extends StatelessWidget {
  const _StatsIcon();
  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: const Size(22, 22), painter: _StatsPainter());
  }
}

class _StatsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black..style = PaintingStyle.fill..strokeCap = StrokeCap.round;
    final r = size.width / 22;
    // Bar 1 - short
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(1*r, 14*r, 5*r, 7*r), Radius.circular(1.5*r)), p);
    // Bar 2 - tall
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(8.5*r, 6*r, 5*r, 15*r), Radius.circular(1.5*r)), p);
    // Bar 3 - medium
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(16*r, 10*r, 5*r, 11*r), Radius.circular(1.5*r)), p);
    // Trend line
    final lp = Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1.5..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(3.5*r, 13*r)..lineTo(11*r, 4.5*r)..lineTo(18.5*r, 9*r);
    canvas.drawPath(path, lp);
    // Dots on trend
    final dp = Paint()..color = Colors.black..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(3.5*r, 13*r), 1.5*r, dp);
    canvas.drawCircle(Offset(11*r, 4.5*r), 1.5*r, dp);
    canvas.drawCircle(Offset(18.5*r, 9*r), 1.5*r, dp);
  }
  @override bool shouldRepaint(_) => false;
}
