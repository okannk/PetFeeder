class ScheduleSlot {
  final String id;
  final String label;
  final bool enabled;
  final int hour;
  final int minute;
  final int portions;

  const ScheduleSlot({
    required this.id,
    required this.label,
    required this.enabled,
    required this.hour,
    required this.minute,
    required this.portions,
  });

  factory ScheduleSlot.fromJson(Map<String, dynamic> j) => ScheduleSlot(
        id: j['id'] as String? ?? 'slot',
        label: j['label'] as String? ?? 'Öğün',
        enabled: j['enabled'] as bool? ?? false,
        hour: j['hour'] as int? ?? 8,
        minute: j['minute'] as int? ?? 0,
        portions: j['portions'] as int? ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'enabled': enabled,
        'hour': hour,
        'minute': minute,
        'portions': portions,
      };

  ScheduleSlot copyWith({bool? enabled, int? hour, int? minute, int? portions}) => ScheduleSlot(
        id: id,
        label: label,
        enabled: enabled ?? this.enabled,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
        portions: portions ?? this.portions,
      );
}

class Schedule {
  final List<ScheduleSlot> slots;
  const Schedule({required this.slots});

  static List<ScheduleSlot> _defaultSlots() => [
        const ScheduleSlot(id: 'slot1', label: 'Sabah', enabled: false, hour: 8, minute: 0, portions: 1),
        const ScheduleSlot(id: 'slot2', label: 'Öğle', enabled: false, hour: 12, minute: 0, portions: 1),
        const ScheduleSlot(id: 'slot3', label: 'Akşam', enabled: false, hour: 18, minute: 0, portions: 1),
        const ScheduleSlot(id: 'slot4', label: 'Gece', enabled: false, hour: 22, minute: 0, portions: 1),
      ];

  factory Schedule.fromJson(Map<String, dynamic>? j) {
    if (j == null) return Schedule(slots: _defaultSlots());

    // Yeni slots formatı
    if (j['slots'] is List) {
      final slots = (j['slots'] as List)
          .map((s) => ScheduleSlot.fromJson(s as Map<String, dynamic>))
          .toList();
      return Schedule(slots: slots);
    }

    // Eski morning/evening formatı — migrate et
    final m = j['morning'] as Map<String, dynamic>?;
    final e = j['evening'] as Map<String, dynamic>?;
    return Schedule(slots: [
      ScheduleSlot(id: 'slot1', label: 'Sabah', enabled: m?['enabled'] as bool? ?? false, hour: m?['hour'] as int? ?? 8, minute: m?['minute'] as int? ?? 0, portions: m?['portions'] as int? ?? 1),
      const ScheduleSlot(id: 'slot2', label: 'Öğle', enabled: false, hour: 12, minute: 0, portions: 1),
      ScheduleSlot(id: 'slot3', label: 'Akşam', enabled: e?['enabled'] as bool? ?? false, hour: e?['hour'] as int? ?? 18, minute: e?['minute'] as int? ?? 0, portions: e?['portions'] as int? ?? 1),
      const ScheduleSlot(id: 'slot4', label: 'Gece', enabled: false, hour: 22, minute: 0, portions: 1),
    ]);
  }

  Map<String, dynamic> toJson() => {'slots': slots.map((s) => s.toJson()).toList()};
}

class Device {
  final String id;
  final String name;
  final bool online;
  final String? lastSeenAt;
  final Schedule schedule;

  const Device({
    required this.id,
    required this.name,
    required this.online,
    this.lastSeenAt,
    required this.schedule,
  });

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'] as String,
        name: j['name'] as String,
        online: j['online'] as bool? ?? false,
        lastSeenAt: j['lastSeenAt'] as String?,
        schedule: Schedule.fromJson(j['schedule'] as Map<String, dynamic>?),
      );
}

class HistoryEntry {
  final String deviceId;
  final String? feedingId;
  final String? status;
  final String? message;
  final String ts;

  const HistoryEntry({
    required this.deviceId,
    this.feedingId,
    this.status,
    this.message,
    required this.ts,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        deviceId: j['deviceId'] as String,
        feedingId: j['feedingId'] as String?,
        status: j['status'] as String?,
        message: j['message'] as String?,
        ts: j['ts'] as String,
      );
}
