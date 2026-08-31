class ScheduleSlot {
  final bool enabled;
  final int hour;
  final int minute;
  final int portions;

  ScheduleSlot({
    required this.enabled,
    required this.hour,
    required this.minute,
    required this.portions,
  });

  factory ScheduleSlot.fromJson(Map<String, dynamic> json) => ScheduleSlot(
        enabled: json['enabled'] == true,
        hour: (json['hour'] ?? 8) as int,
        minute: (json['minute'] ?? 0) as int,
        portions: (json['portions'] ?? 1) as int,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'hour': hour,
        'minute': minute,
        'portions': portions,
      };

  ScheduleSlot copyWith({bool? enabled, int? hour, int? minute, int? portions}) =>
      ScheduleSlot(
        enabled: enabled ?? this.enabled,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
        portions: portions ?? this.portions,
      );
}

class Schedule {
  final ScheduleSlot morning;
  final ScheduleSlot evening;

  Schedule({required this.morning, required this.evening});

  factory Schedule.fromJson(Map<String, dynamic>? json) => Schedule(
        morning: ScheduleSlot.fromJson(
            (json?['morning'] as Map<String, dynamic>?) ?? const {}),
        evening: ScheduleSlot.fromJson(
            (json?['evening'] as Map<String, dynamic>?) ?? const {}),
      );

  Map<String, dynamic> toJson() => {
        'morning': morning.toJson(),
        'evening': evening.toJson(),
      };
}

class Device {
  final String id;
  final String name;
  final String? createdAt;
  final String? lastSeenAt;
  final bool online;
  final Schedule schedule;

  Device({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.lastSeenAt,
    required this.online,
    required this.schedule,
  });

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? 'PetFeeder',
        createdAt: json['createdAt'] as String?,
        lastSeenAt: json['lastSeenAt'] as String?,
        online: json['online'] == true,
        schedule: Schedule.fromJson(json['schedule'] as Map<String, dynamic>?),
      );
}

class HistoryEntry {
  final String feedingId;
  final String? status;
  final String? message;
  final String ts;

  HistoryEntry({
    required this.feedingId,
    this.status,
    this.message,
    required this.ts,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        feedingId: (json['feedingId'] as String?) ?? '',
        status: json['status'] as String?,
        message: json['message'] as String?,
        ts: (json['ts'] as String?) ?? '',
      );
}
