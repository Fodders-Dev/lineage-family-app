import '../utils/date_parser.dart';
import 'package:hive/hive.dart';
import '../models/family_person.dart';
import '../utils/url_utils.dart';

part 'user_profile.g.dart';

@HiveType(typeId: 0)
class UserProfile extends HiveObject {
  @HiveField(0)
  final String id;
  @HiveField(1)
  final String email;
  @HiveField(2)
  final String displayName;
  @HiveField(3)
  final String firstName;
  @HiveField(4)
  final String lastName;
  @HiveField(5)
  final String middleName;
  @HiveField(6)
  final String username;
  @HiveField(7)
  final String? _photoURL;
  @HiveField(8)
  final String phoneNumber;
  @HiveField(9)
  final bool isPhoneVerified;
  @HiveField(10)
  final Gender? gender;
  @HiveField(11)
  final DateTime? birthDate;
  @HiveField(12)
  final String? country;
  @HiveField(13)
  final String? city;
  @HiveField(14)
  final DateTime createdAt;
  @HiveField(15)
  final DateTime? updatedAt;
  @HiveField(16)
  final DateTime? lastLoginAt;
  @HiveField(17)
  final String? countryCode;
  @HiveField(18)
  final List<String>? creatorOfTreeIds;
  @HiveField(19)
  final List<String>? accessibleTreeIds;
  @HiveField(20)
  final List<String>? fcmTokens;

  String? get photoURL => _photoURL;

  UserProfile({
    required this.id,
    required this.email,
    this.displayName = '',
    this.firstName = '',
    this.lastName = '',
    this.middleName = '',
    required this.username,
    String? photoURL,
    required this.phoneNumber,
    this.isPhoneVerified = false,
    this.gender,
    this.birthDate,
    this.country,
    this.city,
    required this.createdAt,
    this.updatedAt,
    this.lastLoginAt,
    this.countryCode,
    this.creatorOfTreeIds,
    this.accessibleTreeIds,
    this.fcmTokens,
  }) : _photoURL = UrlUtils.normalizeImageUrl(photoURL);

  factory UserProfile.fromFirestore(dynamic doc) {
    final data =
        (doc.data != null ? (doc.data() as Map<String, dynamic>?) : null) ?? {};

    // Конвертируем строковое представление пола в enum
    Gender? userGender;
    if (data['gender'] != null) {
      switch (data['gender']) {
        case 'male':
          userGender = Gender.male;
          break;
        case 'female':
          userGender = Gender.female;
          break;
        case 'other':
          userGender = Gender.other;
          break;
        default:
          userGender = Gender.unknown;
      }
    }

    return UserProfile(
      id: doc.id,
      email: data['email'] ?? '',
      displayName: data['displayName'] ?? '',
      firstName: data['firstName'] ?? '',
      lastName: data['lastName'] ?? '',
      middleName: data['middleName'] ?? '',
      username: data['username'] ?? '',
      photoURL: data['photoURL'],
      phoneNumber: data['phoneNumber'] ?? '',
      isPhoneVerified: data['isPhoneVerified'] ?? false,
      gender: userGender,
      birthDate: data['birthDate'] != null
          ? parseDateTimeRequired(data['birthDate'])
          : null,
      country: data['country'] as String?,
      city: data['city'],
      createdAt: data['createdAt'] != null
          ? parseDateTimeRequired(data['createdAt'])
          : DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? parseDateTimeRequired(data['updatedAt'])
          : null,
      lastLoginAt: data['lastLoginAt'] != null
          ? parseDateTimeRequired(data['lastLoginAt'])
          : null,
      countryCode: data['countryCode'],
      creatorOfTreeIds: (data['creatorOfTreeIds'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      accessibleTreeIds: (data['accessibleTreeIds'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      fcmTokens: (data['fcmTokens'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'email': email,
      'displayName': displayName,
      'firstName': firstName,
      'lastName': lastName,
      'middleName': middleName,
      'username': username,
      'photoURL': photoURL,
      'phoneNumber': phoneNumber,
      'isPhoneVerified': isPhoneVerified,
      'gender': gender?.toString().split('.').last,
      'birthDate': birthDate?.toIso8601String(),
      'country': country,
      'city': city,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
      'lastLoginAt': lastLoginAt?.toIso8601String(),
      'countryCode': countryCode,
      if (creatorOfTreeIds != null) 'creatorOfTreeIds': creatorOfTreeIds,
      if (accessibleTreeIds != null) 'accessibleTreeIds': accessibleTreeIds,
      if (fcmTokens != null) 'fcmTokens': fcmTokens,
    };
  }

  String get fullName {
    if (firstName.isNotEmpty || lastName.isNotEmpty) {
      return [
        firstName,
        middleName,
        lastName,
      ].where((part) => part.isNotEmpty).join(' ');
    }
    return displayName;
  }

  UserProfile copyWith({
    String? id,
    String? email,
    String? displayName,
    String? firstName,
    String? lastName,
    String? middleName,
    String? username,
    String? photoURL,
    String? phoneNumber,
    bool? isPhoneVerified,
    Gender? gender,
    DateTime? birthDate,
    String? country,
    String? city,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastLoginAt,
    String? countryCode,
    List<String>? creatorOfTreeIds,
    List<String>? accessibleTreeIds,
    List<String>? fcmTokens,
  }) {
    return UserProfile(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      middleName: middleName ?? this.middleName,
      username: username ?? this.username,
      photoURL: photoURL ?? this.photoURL,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      isPhoneVerified: isPhoneVerified ?? this.isPhoneVerified,
      gender: gender ?? this.gender,
      birthDate: birthDate ?? this.birthDate,
      country: country ?? this.country,
      city: city ?? this.city,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
      countryCode: countryCode ?? this.countryCode,
      creatorOfTreeIds: creatorOfTreeIds ?? this.creatorOfTreeIds,
      accessibleTreeIds: accessibleTreeIds ?? this.accessibleTreeIds,
      fcmTokens: fcmTokens ?? this.fcmTokens,
    );
  }

  factory UserProfile.create({
    required String id,
    required String email,
    String displayName = '',
    String firstName = '',
    String lastName = '',
    String middleName = '',
    required String username,
    String? photoURL,
    required String phoneNumber,
    bool isPhoneVerified = false,
    Gender? gender,
    DateTime? birthDate,
    String? country,
    String? city,
    DateTime? updatedAt,
    DateTime? lastLoginAt,
    String? countryCode,
    List<String>? creatorOfTreeIds,
    List<String>? accessibleTreeIds,
    List<String>? fcmTokens,
  }) {
    return UserProfile(
      id: id,
      email: email,
      displayName: displayName,
      firstName: firstName,
      lastName: lastName,
      middleName: middleName,
      username: username,
      photoURL: photoURL,
      phoneNumber: phoneNumber,
      isPhoneVerified: isPhoneVerified,
      gender: gender,
      birthDate: birthDate,
      country: country,
      city: city,
      createdAt: DateTime.now(),
      updatedAt: updatedAt,
      lastLoginAt: lastLoginAt,
      countryCode: countryCode,
      creatorOfTreeIds: creatorOfTreeIds,
      accessibleTreeIds: accessibleTreeIds,
      fcmTokens: fcmTokens,
    );
  }

  static UserProfile fromMap(Map<String, dynamic> map, String id) {
    // Преобразование строкового пола в enum
    Gender? userGender;
    if (map['gender'] != null) {
      switch (map['gender']) {
        case 'male':
          userGender = Gender.male;
          break;
        case 'female':
          userGender = Gender.female;
          break;
        case 'other':
          userGender = Gender.other;
          break;
        default:
          userGender = Gender.unknown;
      }
    }

    return UserProfile(
      id: id,
      displayName: map['displayName'] ?? '',
      email: map['email'] ?? '',
      photoURL: map['photoURL'],
      firstName: map['firstName'] ?? '',
      lastName: map['lastName'] ?? '',
      middleName: map['middleName'],
      birthDate: map['birthDate'] != null
          ? parseDateTimeRequired(map['birthDate'])
          : null,
      gender: userGender,
      phoneNumber: map['phoneNumber'] ?? '',
      country: map['country'] as String?,
      city: map['city'],
      createdAt: map['createdAt'] != null
          ? parseDateTimeRequired(map['createdAt'])
          : DateTime.now(),
      updatedAt: map['updatedAt'] != null
          ? parseDateTimeRequired(map['updatedAt'])
          : DateTime.now(),
      username: map['username'] ?? '',
      isPhoneVerified: map['isPhoneVerified'] ?? false,
      creatorOfTreeIds: (map['creatorOfTreeIds'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      accessibleTreeIds: (map['accessibleTreeIds'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      fcmTokens: (map['fcmTokens'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}
