import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:hive_test/hive_test.dart';
import 'package:lineage/models/family_person.dart';

import 'package:lineage/models/family_person.dart' as lineage_models;

class FakeNotificationService {
  final List<lineage_models.FamilyPerson> shownBirthdays = [];

  Future<void> showBirthdayNotification(
      lineage_models.FamilyPerson person) async {
    shownBirthdays.add(person);
  }
}

void main() {
  setUp(() async {
    await setUpTestHive();
    if (!Hive.isAdapterRegistered(FamilyPersonAdapter().typeId)) {
      Hive.registerAdapter(FamilyPersonAdapter());
    }
    if (!Hive.isAdapterRegistered(GenderAdapter().typeId)) {
      Hive.registerAdapter(GenderAdapter());
    }
  });

  tearDown(() async {
    await tearDownTestHive();
  });

  test(
    'birthdayCheckTask should show notification for person with birthday today',
    () async {
      final notificationService = FakeNotificationService();
      final personsBox = await Hive.openBox<lineage_models.FamilyPerson>(
        'testPersonsBox',
      );

      final today = DateTime.now();
      final personWithBirthday = lineage_models.FamilyPerson(
        id: '1',
        treeId: 't1',
        name: 'Сегодняшний Именинник',
        gender: Gender.unknown,
        birthDate: DateTime(
          today.year - 30,
          today.month,
          today.day,
        ),
        isAlive: true,
        createdAt: today,
        updatedAt: today,
      );
      final personWithoutBirthday = lineage_models.FamilyPerson(
        id: '2',
        treeId: 't1',
        name: 'Вчерашний Не Именинник',
        gender: Gender.unknown,
        birthDate: DateTime(
          today.year - 25,
          today.month,
          today.day - 1,
        ),
        isAlive: true,
        createdAt: today,
        updatedAt: today,
      );
      final personWithNullBirthday = lineage_models.FamilyPerson(
        id: '3',
        treeId: 't1',
        name: 'Без Даты',
        gender: Gender.unknown,
        birthDate: null,
        isAlive: true,
        createdAt: today,
        updatedAt: today,
      );

      await personsBox.put(personWithBirthday.id, personWithBirthday);
      await personsBox.put(personWithoutBirthday.id, personWithoutBirthday);
      await personsBox.put(personWithNullBirthday.id, personWithNullBirthday);

      final List<lineage_models.FamilyPerson> relatives =
          personsBox.values.toList();
      for (final person in relatives) {
        if (person.birthDate != null &&
            person.birthDate!.day == today.day &&
            person.birthDate!.month == today.month) {
          await notificationService.showBirthdayNotification(person);
        }
      }

      expect(notificationService.shownBirthdays, hasLength(1));
      expect(
          notificationService.shownBirthdays.single.id, personWithBirthday.id);
      expect(
        notificationService.shownBirthdays.any(
          (person) => person.id == personWithoutBirthday.id,
        ),
        isFalse,
      );
    },
  );
}
