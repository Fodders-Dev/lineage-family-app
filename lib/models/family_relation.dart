import 'package:hive/hive.dart'; // Импорт Hive
import 'package:cloud_firestore/cloud_firestore.dart';
import 'family_person.dart'; // Добавляем импорт для доступа к типу Gender

part 'family_relation.g.dart'; // Директива для генерации кода

@HiveType(typeId: 101) // Аннотация для enum
enum RelationType {
  @HiveField(0)
  parent, // Родитель
  @HiveField(1)
  child, // Ребенок
  @HiveField(2)
  spouse, // Супруг(а)
  @HiveField(3)
  partner, // Партнер (для небрачных союзов)
  @HiveField(4)
  sibling, // Брат/сестра
  @HiveField(5)
  cousin, // Двоюродный брат/сестра
  @HiveField(6)
  uncle, // Дядя
  @HiveField(7)
  aunt, // Тетя
  @HiveField(8)
  nephew, // Племянник
  @HiveField(9)
  niece, // Племянница
  @HiveField(10)
  nibling, // Племянник/племянница (гендерно-нейтральный термин)
  @HiveField(11)
  grandparent, // Дедушка/бабушка
  @HiveField(12)
  grandchild, // Внук/внучка
  @HiveField(13)
  greatGrandparent, // Прадедушка/прабабушка
  @HiveField(14)
  greatGrandchild, // Правнук/правнучка
  @HiveField(15)
  parentInLaw, // Свекор/свекровь/тесть/теща
  @HiveField(16)
  childInLaw, // Зять/невестка
  @HiveField(17)
  siblingInLaw, // Деверь/золовка/шурин/свояченица
  @HiveField(18)
  inlaw, // Родственник по браку (общий)
  @HiveField(19)
  stepparent, // Приемный родитель
  @HiveField(20)
  stepchild, // Приемный ребенок
  @HiveField(21)
  ex_spouse, // Бывший супруг(а)
  @HiveField(22)
  ex_partner, // Бывший партнер
  @HiveField(23)
  friend, // Друг
  @HiveField(24)
  colleague, // Коллега
  @HiveField(25)
  other, // Другое родство
}

/// Класс для хранения родственной связи между двумя людьми
@HiveType(typeId: 3) // Аннотация для класса
class FamilyRelation extends HiveObject {
  // Наследуемся от HiveObject
  @HiveField(0)
  final String id;
  @HiveField(1)
  final String treeId; // ID семейного дерева
  @HiveField(2)
  final String person1Id; // ID первого человека
  @HiveField(3)
  final String person2Id; // ID второго человека
  @HiveField(4)
  final RelationType relation1to2; // Отношение от person1 к person2
  @HiveField(5)
  final RelationType relation2to1; // Отношение от person2 к person1
  @HiveField(6)
  final bool isConfirmed; // Подтверждена ли связь (для онлайн-пользователей)
  @HiveField(7)
  final DateTime createdAt; // Дата создания связи
  @HiveField(8)
  final DateTime? updatedAt; // Дата обновления связи
  @HiveField(9)
  final String? createdBy; // Кто создал связь

  FamilyRelation({
    required this.id,
    required this.treeId,
    required this.person1Id,
    required this.person2Id,
    required this.relation1to2,
    required this.relation2to1,
    required this.isConfirmed,
    required this.createdAt,
    this.updatedAt,
    this.createdBy,
  });

  factory FamilyRelation.fromFirestore(DocumentSnapshot doc) {
    final data =
        doc.data() as Map<String, dynamic>? ?? {}; // Добавим проверку на null
    return FamilyRelation(
      id: doc.id,
      treeId: data['treeId'] ?? '',
      person1Id: data['person1Id'] ?? '',
      person2Id: data['person2Id'] ?? '',
      relation1to2: _stringToRelationType(data['relation1to2']),
      relation2to1: _stringToRelationType(data['relation2to1']),
      isConfirmed: data['isConfirmed'] ?? true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'treeId': treeId,
      'person1Id': person1Id,
      'person2Id': person2Id,
      'relation1to2': relationTypeToString(relation1to2),
      'relation2to1': relationTypeToString(relation2to1),
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'createdBy': createdBy,
      'isConfirmed': isConfirmed,
    };
  }

  // Метод для получения противоположной (зеркальной) связи
  static RelationType getMirrorRelation(RelationType relationType) {
    switch (relationType) {
      case RelationType.parent:
        return RelationType.child;
      case RelationType.child:
        return RelationType.parent;
      case RelationType.spouse:
        return RelationType.spouse; // Супруги - симметричное отношение
      case RelationType.partner:
        return RelationType.partner;
      case RelationType.sibling:
        return RelationType.sibling; // Брат/сестра - симметричное отношение
      case RelationType.grandparent:
        return RelationType.grandchild;
      case RelationType.grandchild:
        return RelationType.grandparent;
      case RelationType.cousin:
        return RelationType.cousin; // Двоюродные - симметричное отношение
      case RelationType.uncle:
        return RelationType.nibling; // Или niece/nibling? Зависит от контекста
      case RelationType.aunt:
        return RelationType.nibling; // Или nephew/nibling?
      case RelationType.nephew:
        return RelationType.uncle; // Или aunt?
      case RelationType.niece:
        return RelationType.uncle; // Или uncle?
      case RelationType.nibling:
        return RelationType
            .uncle; // Или aunt? Нужно больше логики или упрощение
      case RelationType.parentInLaw:
        return RelationType.childInLaw;
      case RelationType.childInLaw:
        return RelationType.parentInLaw;
      case RelationType.siblingInLaw:
        return RelationType.siblingInLaw; // Тоже симметричное
      case RelationType.greatGrandparent:
        return RelationType.greatGrandchild;
      case RelationType.greatGrandchild:
        return RelationType.greatGrandparent;
      case RelationType.inlaw:
        return RelationType.inlaw;
      case RelationType.stepparent:
        return RelationType.stepchild;
      case RelationType.stepchild:
        return RelationType.stepparent;
      case RelationType.ex_spouse:
        return RelationType.ex_spouse;
      case RelationType.ex_partner:
        return RelationType.ex_partner;
      case RelationType.friend:
        return RelationType.friend;
      case RelationType.colleague:
        return RelationType.colleague;
      default:
        return RelationType.other;
    }
  }

  // Конвертация типа отношения из строки (публичный метод)
  static RelationType stringToRelationType(String? value) {
    // Сделаем value nullable
    if (value == null) return RelationType.other;
    try {
      return RelationType.values.firstWhere(
        (e) => e.toString().split('.').last == value,
      );
    } catch (e) {
      return RelationType.other; // Если не найдено, вернуть other
    }
  }

  // Конвертация типа отношения в строку (публичный метод)
  static String relationTypeToString(RelationType type) {
    return type
        .toString()
        .split('.')
        .last; // Простой способ конвертации enum в строку
  }

  // <<< НОВЫЙ МЕТОД: Получение общего русского названия типа связи для диалогов >>>
  static String getGenericRelationTypeStringRu(RelationType type) {
    switch (type) {
      case RelationType.parent:
        return 'Родитель';
      case RelationType.child:
        return 'Ребенок';
      case RelationType.spouse:
        return 'Супруг(а)';
      case RelationType.partner:
        return 'Партнер';
      case RelationType.sibling:
        return 'Брат/Сестра';
      case RelationType.grandparent:
        return 'Дедушка/Бабушка';
      case RelationType.grandchild:
        return 'Внук/Внучка';
      case RelationType.cousin:
        return 'Двоюродный брат/сестра';
      case RelationType.uncle:
        return 'Дядя';
      case RelationType.aunt:
        return 'Тетя';
      case RelationType.nephew:
        return 'Племянник';
      case RelationType.niece:
        return 'Племянница';
      case RelationType.nibling:
        return 'Племянник(ца)';
      case RelationType.parentInLaw:
        return 'Родитель супруга(и)';
      case RelationType.childInLaw:
        return 'Ребенок супруга(и)';
      case RelationType.siblingInLaw:
        return 'Брат/Сестра супруга(и)';
      case RelationType.stepparent:
        return 'Отчим/Мачеха';
      case RelationType.stepchild:
        return 'Пасынок/Падчерица';
      case RelationType.ex_spouse:
        return 'Бывший супруг(а)';
      case RelationType.ex_partner:
        return 'Бывший партнер';
      case RelationType.friend:
        return 'Друг';
      case RelationType.colleague:
        return 'Коллега';
      // Добавим великих предков/потомков, если нужно
      case RelationType.greatGrandparent:
        return 'Прадедушка/Прабабушка';
      case RelationType.greatGrandchild:
        return 'Правнук/Правнучка';
      case RelationType.inlaw:
        return 'Родственник по браку';
      default:
        return 'Другое'; // Используем 'Другое' для RelationType.other
    }
  }

  // Метод для получения названия родственной связи с учетом пола
  static String getRelationName(RelationType relationType, Gender? gender) {
    switch (relationType) {
      case RelationType.parent:
        return gender == Gender.male
            ? 'Отец'
            : (gender == Gender.female ? 'Мать' : 'Родитель');
      case RelationType.child:
        return gender == Gender.male
            ? 'Сын'
            : (gender == Gender.female ? 'Дочь' : 'Ребенок');
      case RelationType.spouse:
        return gender == Gender.male
            ? 'Муж'
            : (gender == Gender.female ? 'Жена' : 'Супруг(а)');
      case RelationType.partner:
        return 'Партнер';
      case RelationType.sibling:
        return gender == Gender.male
            ? 'Брат'
            : (gender == Gender.female ? 'Сестра' : 'Родной брат/сестра');
      case RelationType.grandparent:
        return gender == Gender.male
            ? 'Дедушка'
            : (gender == Gender.female ? 'Бабушка' : 'Дедушка/Бабушка');
      case RelationType.grandchild:
        return gender == Gender.male
            ? 'Внук'
            : (gender == Gender.female ? 'Внучка' : 'Внук/Внучка');
      case RelationType.cousin:
        if (gender == Gender.female) return 'Двоюродная сестра';
        if (gender == Gender.male) return 'Двоюродный брат';
        return 'Двоюродный родственник';
      case RelationType.uncle:
        return gender == Gender.female ? 'Тётя' : 'Дядя';
      case RelationType.nephew:
        return gender == Gender.female ? 'Племянница' : 'Племянник';
      case RelationType.nibling:
        return gender == Gender.female
            ? 'Племянница'
            : (gender == Gender.male ? 'Племянник' : 'Племянник(ца)');
      case RelationType.parentInLaw:
        return gender == Gender.female ? 'Свекровь/Тёща' : 'Свёкор/Тесть';
      case RelationType.childInLaw:
        return gender == Gender.female ? 'Невестка' : 'Зять';
      case RelationType.siblingInLaw:
        return gender == Gender.female ? 'Свояченица' : 'Свояк';
      case RelationType.greatGrandparent:
        return gender == Gender.male
            ? 'Прадедушка'
            : (gender == Gender.female ? 'Прабабушка' : 'Прародитель');
      case RelationType.greatGrandchild:
        return gender == Gender.male
            ? 'Правнук'
            : (gender == Gender.female ? 'Правнучка' : 'Правнук(чка)');
      case RelationType.inlaw:
        return 'Родственник по браку';
      case RelationType.stepparent:
        return gender == Gender.female ? 'Мачеха' : 'Отчим';
      case RelationType.stepchild:
        return gender == Gender.female ? 'Падчерица' : 'Пасынок';
      case RelationType.ex_spouse:
        return 'Бывший супруг(а)';
      case RelationType.ex_partner:
        return 'Бывший партнер';
      case RelationType.friend:
        return 'Друг';
      case RelationType.colleague:
        return 'Коллега';
      default:
        return getGenericRelationTypeStringRu(relationType);
    }
  }

  // Приватный метод для конвертации строки в RelationType, используемый в fromFirestore
  static RelationType _stringToRelationType(String? typeString) {
    return stringToRelationType(
      typeString,
    ); // Используем обновленный публичный метод
  }

  /// Статический метод для получения описания отношения с учетом пола
  /// [targetGender] - пол человека, К КОТОРОМУ относится данная связь
  static String getRelationDescription(
    RelationType type,
    Gender? targetGender,
  ) {
    // Можно использовать getRelationName или оставить эту логику
    return getRelationName(type, targetGender);
  }

  /// Статический метод для получения списка доступных типов связей,
  /// отфильтрованных по полу [anchorGender] (пол человека, к которому добавляем).
  static List<RelationType> getAvailableRelationTypes(Gender? anchorGender) {
    // Возвращаем все типы, кроме некоторых специфичных,
    // и фильтруем однополые связи, если пол anchorPerson известен
    return RelationType.values.where((type) {
      // Основные прямые связи
      if (type == RelationType.parent ||
          type == RelationType.child ||
          type == RelationType.sibling) {
        return true;
      }
      // Супруг/Партнер - фильтруем по полу, если он известен
      if (type == RelationType.spouse || type == RelationType.partner) {
        return true; // Пока разрешаем для всех, фильтрация будет при выборе пола нового
      }
      // Бывшие - аналогично
      if (type == RelationType.ex_spouse || type == RelationType.ex_partner) {
        return true;
      }
      // Остальные (дяди, тети, племянники, дедушки и т.д.)
      if (type == RelationType.uncle ||
          type == RelationType.aunt ||
          type == RelationType.nephew ||
          type == RelationType.niece ||
          type == RelationType.nibling ||
          type == RelationType.grandparent ||
          type == RelationType.grandchild ||
          type == RelationType.cousin) {
        return true;
      }
      // Связи по браку
      if (type == RelationType.parentInLaw ||
          type == RelationType.childInLaw ||
          type == RelationType.siblingInLaw ||
          type == RelationType.inlaw) {
        return true;
      }
      // Приемные
      if (type == RelationType.stepparent || type == RelationType.stepchild) {
        return true;
      }
      // Другие
      if (type == RelationType.friend ||
          type == RelationType.colleague ||
          type == RelationType.other) {
        return true;
      }

      // Скрываем великих бабушек/дедушек по умолчанию
      if (type == RelationType.greatGrandparent ||
          type == RelationType.greatGrandchild) {
        return false;
      }

      return false; // По умолчанию скрываем
    }).toList();
  }
}

// Добавляем расширение для RelationType
extension RelationTypeExtension on RelationType {
  // Получение комплементарного отношения (opposite relation)
  RelationType getComplementary() {
    switch (this) {
      case RelationType.parent:
        return RelationType.child;
      case RelationType.child:
        return RelationType.parent;
      case RelationType.spouse:
        return RelationType.spouse;
      // Добавить остальные типы отношений соответственно
      default:
        return RelationType.other;
    }
  }

  // Получить обратный тип связи с учетом пола "другого" человека
  RelationType getReciprocalType(Gender? otherPersonGender) {
    // Добавляем пол
    switch (this) {
      case RelationType.parent:
        return RelationType.child;
      case RelationType.child:
        return RelationType.parent;
      case RelationType.sibling:
        return RelationType.sibling; // Добавляем
      case RelationType.spouse:
        return RelationType.spouse;
      case RelationType.ex_spouse:
        return RelationType.ex_spouse;
      case RelationType.uncle:
        return RelationType.nibling; // Обратный для дяди - племянник(ца)
      case RelationType.aunt:
        return RelationType.nibling; // Обратный для тети - племянник(ца)
      case RelationType.nephew: // Я - племянник, мой обратный - дядя или тетя?
        // Возвращаем общий термин, т.к. не знаем пол того, к кому обращаемся
        return RelationType.uncle;
      case RelationType.niece: // Я - племянница...
        return RelationType.uncle;
      case RelationType.nibling: // Я - племянник(ца)...
        return RelationType.uncle;
      case RelationType.cousin:
        return RelationType.cousin;
      // Добавляем
      case RelationType.grandparent:
        return RelationType.grandchild;
      case RelationType.grandchild:
        return RelationType.grandparent;
      // Добавить обработку остальных _in_law, step_, god_
      case RelationType.siblingInLaw:
        return RelationType.siblingInLaw;
      case RelationType.parentInLaw:
        return RelationType.childInLaw;
      case RelationType.childInLaw:
        return RelationType.parentInLaw;
      case RelationType.stepparent:
        return RelationType.stepchild;
      case RelationType.stepchild:
        return RelationType.stepparent;
      case RelationType.ex_partner:
        return RelationType.ex_partner;
      case RelationType.friend:
        return RelationType.friend;
      case RelationType.colleague:
        return RelationType.colleague;
      case RelationType.other:
        return RelationType.other;
      default:
        return RelationType.other; // По умолчанию
    }
  }
}
