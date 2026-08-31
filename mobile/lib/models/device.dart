// Cihaz modelleri — backend yok, ESP'ye direkt HTTP

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

  ScheduleSlot copyWith({bool? enabled, int? hour, int? minute, int? portions}) =>
      ScheduleSlot(
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

  static List<ScheduleSlot> _defaults() => [
        const ScheduleSlot(id: 'slot1', label: 'Sabah', enabled: false, hour: 8,  minute: 0, portions: 1),
        const ScheduleSlot(id: 'slot2', label: 'Öğle',  enabled: false, hour: 12, minute: 0, portions: 1),
        const ScheduleSlot(id: 'slot3', label: 'Akşam', enabled: false, hour: 18, minute: 0, portions: 1),
        const ScheduleSlot(id: 'slot4', label: 'Gece',  enabled: false, hour: 22, minute: 0, portions: 1),
      ];

  factory Schedule.fromJson(dynamic j) {
    if (j == null) return Schedule(slots: _defaults());
    if (j is List) {
      return Schedule(slots: j.map((s) => ScheduleSlot.fromJson(s as Map<String, dynamic>)).toList());
    }
    if (j is Map<String, dynamic> && j['slots'] is List) {
      return Schedule(
          slots: (j['slots'] as List)
              .map((s) => ScheduleSlot.fromJson(s as Map<String, dynamic>))
              .toList());
    }
    return Schedule(slots: _defaults());
  }

  Map<String, dynamic> toJson() => {'slots': slots.map((s) => s.toJson()).toList()};
}

/// ESP'den /status ile alınan cihaz durumu
class DeviceStatus {
  final String name;
  final bool online;
  final String? ip;
  final Schedule schedule;

  const DeviceStatus({
    required this.name,
    required this.online,
    this.ip,
    required this.schedule,
  });

  factory DeviceStatus.fromJson(Map<String, dynamic> j) => DeviceStatus(
        name: j['name'] as String? ?? 'PetFeeder',
        online: j['online'] as bool? ?? true,
        ip: j['ip'] as String?,
        schedule: Schedule.fromJson(j['slots'] ?? j['schedule']),
      );
}

/// SharedPreferences'ta saklanan cihaz bilgisi
class StoredDevice {
  final String id;    // mdns adı, örn. "petfeeder-a1b2"
  final String name;  // kullanıcının verdiği ad
  final String host;  // "petfeeder-a1b2.local" veya IP

  const StoredDevice({required this.id, required this.name, required this.host});

  factory StoredDevice.fromJson(Map<String, dynamic> j) => StoredDevice(
        id: j['id'] as String,
        name: j['name'] as String,
        host: j['host'] as String,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'host': host};

  StoredDevice copyWith({String? name}) =>
      StoredDevice(id: id, name: name ?? this.name, host: host);
}

/// UI'da kullanılan birleşik model
class Device {
  final StoredDevice stored;
  final bool online;
  final Schedule schedule;

  const Device({required this.stored, required this.online, required this.schedule});

  String get id   => stored.id;
  String get name => stored.name;
  String get host => stored.host;
}

class HistoryEntry {
  final String ts;
  final int portions;
  final String? msg;

  const HistoryEntry({required this.ts, required this.portions, this.msg});

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        ts: j['ts'] as String? ?? '',
        portions: j['portions'] as int? ?? 0,
        msg: j['msg'] as String?,
      );
}
