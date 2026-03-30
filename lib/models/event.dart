import 'package:cloud_firestore/cloud_firestore.dart';

enum EventType {
  birthday, // День рождения
  anniversary, // Годовщина
  memorial, // Памятная дата
  wedding, // Свадьба
  death, // Смерть (9 дней, 40 дней, годовщины)
  funeral, // Похороны
  holiday, // Праздник
  custom, // Произвольное событие
}

enum EventRecurrence {
  none, // Не повторяется
  daily, // Ежедневно
  weekly, // Еженедельно
  monthly, // Ежемесячно
  annually, // Ежегодно
  custom, // Пользовательское расписание
}

class FamilyEvent {
  final String id;
  final String title;
  final String? description;
  final EventType type;
  final DateTime date;
  final List<String> relatedPersonIds; // ID людей, связанных с событием
  final String? familyTreeId; // ID семейного дерева
  final EventRecurrence recurrence;
  final String? customRecurrenceRule; // Правило повторения для custom
  final String? creatorId; // Кто создал событие
  final DateTime createdAt;
  final String? color; // Цвет события (HEX-код)
  final bool isPublic; // Видимо для всех или только для семьи

  FamilyEvent({
    required this.id,
    required this.title,
    this.description,
    required this.type,
    required this.date,
    this.relatedPersonIds = const [],
    this.familyTreeId,
    this.recurrence = EventRecurrence.none,
    this.customRecurrenceRule,
    this.creatorId,
    required this.createdAt,
    this.color,
    this.isPublic = false,
  });

  factory FamilyEvent.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return FamilyEvent(
      id: doc.id,
      title: data['title'] ?? '',
      description: data['description'],
      type: _stringToEventType(data['type'] ?? 'custom'),
      date: (data['date'] as Timestamp).toDate(),
      relatedPersonIds: data['relatedPersonIds'] != null
          ? List<String>.from(data['relatedPersonIds'])
          : [],
      familyTreeId: data['familyTreeId'],
      recurrence: _stringToEventRecurrence(data['recurrence'] ?? 'none'),
      customRecurrenceRule: data['customRecurrenceRule'],
      creatorId: data['creatorId'],
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      color: data['color'],
      isPublic: data['isPublic'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'description': description,
      'type': _eventTypeToString(type),
      'date': Timestamp.fromDate(date),
      'relatedPersonIds': relatedPersonIds,
      'familyTreeId': familyTreeId,
      'recurrence': _eventRecurrenceToString(recurrence),
      'customRecurrenceRule': customRecurrenceRule,
      'creatorId': creatorId,
      'createdAt': Timestamp.fromDate(createdAt),
      'color': color,
      'isPublic': isPublic,
    };
  }

  // Получение цвета по типу события
  static String getDefaultColorForType(EventType type) {
    switch (type) {
      case EventType.birthday:
        return '#4CAF50'; // Зеленый
      case EventType.anniversary:
        return '#2196F3'; // Синий
      case EventType.memorial:
        return '#9C27B0'; // Фиолетовый
      case EventType.wedding:
        return '#E91E63'; // Розовый
      case EventType.death:
        return '#607D8B'; // Серый
      case EventType.funeral:
        return '#795548'; // Коричневый
      case EventType.holiday:
        return '#FF9800'; // Оранжевый
      case EventType.custom:
        return '#03A9F4'; // Голубой
    }
  }

  // Получение следующей даты события с учетом повторяемости
  DateTime getNextOccurrence() {
    final now = DateTime.now();
    if (recurrence == EventRecurrence.none || date.isAfter(now)) {
      return date;
    }

    DateTime nextDate = date;

    switch (recurrence) {
      case EventRecurrence.annually:
        while (nextDate.isBefore(now)) {
          nextDate = DateTime(
            nextDate.year + 1,
            nextDate.month,
            nextDate.day,
            nextDate.hour,
            nextDate.minute,
          );
        }
        break;
      case EventRecurrence.monthly:
        while (nextDate.isBefore(now)) {
          int month = nextDate.month + 1;
          int year = nextDate.year;
          if (month > 12) {
            month = 1;
            year++;
          }
          nextDate = DateTime(
            year,
            month,
            nextDate.day,
            nextDate.hour,
            nextDate.minute,
          );
        }
        break;
      case EventRecurrence.weekly:
        while (nextDate.isBefore(now)) {
          nextDate = nextDate.add(Duration(days: 7));
        }
        break;
      case EventRecurrence.daily:
        while (nextDate.isBefore(now)) {
          nextDate = nextDate.add(Duration(days: 1));
        }
        break;
      default:
        break;
    }

    return nextDate;
  }

  // Конвертация типа события из строки
  static EventType _stringToEventType(String value) {
    switch (value) {
      case 'birthday':
        return EventType.birthday;
      case 'anniversary':
        return EventType.anniversary;
      case 'memorial':
        return EventType.memorial;
      case 'wedding':
        return EventType.wedding;
      case 'death':
        return EventType.death;
      case 'funeral':
        return EventType.funeral;
      case 'holiday':
        return EventType.holiday;
      default:
        return EventType.custom;
    }
  }

  // Конвертация типа события в строку
  static String _eventTypeToString(EventType type) {
    switch (type) {
      case EventType.birthday:
        return 'birthday';
      case EventType.anniversary:
        return 'anniversary';
      case EventType.memorial:
        return 'memorial';
      case EventType.wedding:
        return 'wedding';
      case EventType.death:
        return 'death';
      case EventType.funeral:
        return 'funeral';
      case EventType.holiday:
        return 'holiday';
      case EventType.custom:
        return 'custom';
    }
  }

  // Конвертация типа повторяемости из строки
  static EventRecurrence _stringToEventRecurrence(String value) {
    switch (value) {
      case 'daily':
        return EventRecurrence.daily;
      case 'weekly':
        return EventRecurrence.weekly;
      case 'monthly':
        return EventRecurrence.monthly;
      case 'annually':
        return EventRecurrence.annually;
      case 'custom':
        return EventRecurrence.custom;
      default:
        return EventRecurrence.none;
    }
  }

  // Конвертация типа повторяемости в строку
  static String _eventRecurrenceToString(EventRecurrence recurrence) {
    switch (recurrence) {
      case EventRecurrence.daily:
        return 'daily';
      case EventRecurrence.weekly:
        return 'weekly';
      case EventRecurrence.monthly:
        return 'monthly';
      case EventRecurrence.annually:
        return 'annually';
      case EventRecurrence.custom:
        return 'custom';
      case EventRecurrence.none:
        return 'none';
    }
  }
}
