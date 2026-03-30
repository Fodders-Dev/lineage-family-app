import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../models/app_event.dart';

class EventService {
  EventService({FamilyTreeServiceInterface? familyTreeService})
      : _familyTreeService =
            familyTreeService ?? GetIt.I<FamilyTreeServiceInterface>();

  final FamilyTreeServiceInterface _familyTreeService;

  Future<List<AppEvent>> getUpcomingEvents(
    String treeId, {
    int limit = 5,
  }) async {
    print('[EventService] Запрос событий для дерева $treeId...');
    List<AppEvent> allEvents = [];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    try {
      // 1. Получаем всех родственников для дерева
      final relatives = await _familyTreeService.getRelatives(treeId);
      print('[EventService] Найдено ${relatives.length} родственников.');

      for (final person in relatives) {
        // 2. Вычисляем дни рождения
        if (person.birthDate != null) {
          // Определяем дату следующего дня рождения
          DateTime nextBirthday = DateTime(
            now.year,
            person.birthDate!.month,
            person.birthDate!.day,
          );
          // Если ДР в этом году уже прошел, берем следующий год
          if (nextBirthday.isBefore(today)) {
            nextBirthday = DateTime(
              now.year + 1,
              person.birthDate!.month,
              person.birthDate!.day,
            );
          }
          allEvents.add(
            AppEvent(
              id: '${person.id}_birthday',
              type: AppEventType.birthday,
              date: nextBirthday,
              title: 'День рождения',
              personName: person.name,
              personId: person.id,
              icon: Icons.cake_outlined,
            ),
          );
        }

        // 3. Вычисляем дни памяти (для умерших)
        if (!person.isAlive && person.deathDate != null) {
          final deathDate = person.deathDate!;
          // 9 дней
          final memorial9 = deathDate.add(
            const Duration(days: 8),
          ); // +8, т.к. день смерти считается первым
          // Проверяем, не прошел ли уже этот день в текущем году/цикле расчета
          // (Простая проверка - если дата < сегодня, то событие в прошлом)
          if (memorial9.isAfter(today) || memorial9.isAtSameMomentAs(today)) {
            allEvents.add(
              AppEvent(
                id: '${person.id}_memorial9',
                type: AppEventType.memorial9days,
                date: memorial9,
                title: '9 дней',
                personName: person.name,
                personId: person.id,
                icon: Icons.church_outlined, // Пример иконки
              ),
            );
          }

          // 40 дней
          final memorial40 = deathDate.add(const Duration(days: 39));
          if (memorial40.isAfter(today) || memorial40.isAtSameMomentAs(today)) {
            allEvents.add(
              AppEvent(
                id: '${person.id}_memorial40',
                type: AppEventType.memorial40days,
                date: memorial40,
                title: '40 дней',
                personName: person.name,
                personId: person.id,
                icon: Icons.church_outlined, // Пример иконки
              ),
            );
          }
        }

        // TODO: Добавить годовщины свадеб, когда появится поле marriageDate
      }

      // 4. Сортируем события по дате
      allEvents.sort((a, b) => a.date.compareTo(b.date));

      print('[EventService] Всего вычислено ${allEvents.length} событий.');

      // 5. Отфильтровываем прошедшие события (на всякий случай, хотя выше уже есть проверка)
      final upcomingEvents = allEvents.where((event) {
        final eventDay = DateTime(
          event.date.year,
          event.date.month,
          event.date.day,
        );
        return eventDay.isAfter(today) || eventDay.isAtSameMomentAs(today);
      }).toList();

      print(
        '[EventService] Найдено ${upcomingEvents.length} предстоящих событий.',
      );

      // 6. Возвращаем запрошенное количество
      return upcomingEvents.take(limit).toList();
    } catch (e, s) {
      print('[EventService] Ошибка при получении событий: $e\n$s');
      // Логирование ошибки
      return []; // Возвращаем пустой список в случае ошибки
    }
  }
}
