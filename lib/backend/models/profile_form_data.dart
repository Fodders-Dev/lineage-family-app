import '../../models/family_person.dart';

class ProfileFormData {
  const ProfileFormData({
    required this.userId,
    this.email,
    this.firstName = '',
    this.lastName = '',
    this.middleName = '',
    this.displayName = '',
    this.username = '',
    this.phoneNumber = '',
    this.countryCode,
    this.countryName,
    this.city = '',
    this.photoUrl,
    this.isPhoneVerified = false,
    this.gender = Gender.unknown,
    this.maidenName = '',
    this.birthDate,
  });

  final String userId;
  final String? email;
  final String firstName;
  final String lastName;
  final String middleName;
  final String displayName;
  final String username;
  final String phoneNumber;
  final String? countryCode;
  final String? countryName;
  final String city;
  final String? photoUrl;
  final bool isPhoneVerified;
  final Gender gender;
  final String maidenName;
  final DateTime? birthDate;

  ProfileFormData copyWith({
    String? userId,
    String? email,
    String? firstName,
    String? lastName,
    String? middleName,
    String? displayName,
    String? username,
    String? phoneNumber,
    String? countryCode,
    String? countryName,
    String? city,
    String? photoUrl,
    bool? isPhoneVerified,
    Gender? gender,
    String? maidenName,
    DateTime? birthDate,
  }) {
    return ProfileFormData(
      userId: userId ?? this.userId,
      email: email ?? this.email,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      middleName: middleName ?? this.middleName,
      displayName: displayName ?? this.displayName,
      username: username ?? this.username,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      countryCode: countryCode ?? this.countryCode,
      countryName: countryName ?? this.countryName,
      city: city ?? this.city,
      photoUrl: photoUrl ?? this.photoUrl,
      isPhoneVerified: isPhoneVerified ?? this.isPhoneVerified,
      gender: gender ?? this.gender,
      maidenName: maidenName ?? this.maidenName,
      birthDate: birthDate ?? this.birthDate,
    );
  }
}
