class CustomApiSession {
  const CustomApiSession({
    required this.accessToken,
    this.refreshToken,
    required this.userId,
    this.email,
    this.displayName,
    this.photoUrl,
    this.providerIds = const [],
    this.isProfileComplete = false,
    this.missingFields = const [],
  });

  final String accessToken;
  final String? refreshToken;
  final String userId;
  final String? email;
  final String? displayName;
  final String? photoUrl;
  final List<String> providerIds;
  final bool isProfileComplete;
  final List<String> missingFields;

  CustomApiSession copyWith({
    String? accessToken,
    String? refreshToken,
    String? userId,
    String? email,
    String? displayName,
    String? photoUrl,
    List<String>? providerIds,
    bool? isProfileComplete,
    List<String>? missingFields,
  }) {
    return CustomApiSession(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      userId: userId ?? this.userId,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      photoUrl: photoUrl ?? this.photoUrl,
      providerIds: providerIds ?? this.providerIds,
      isProfileComplete: isProfileComplete ?? this.isProfileComplete,
      missingFields: missingFields ?? this.missingFields,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'userId': userId,
      'email': email,
      'displayName': displayName,
      'photoUrl': photoUrl,
      'providerIds': providerIds,
      'isProfileComplete': isProfileComplete,
      'missingFields': missingFields,
    };
  }

  factory CustomApiSession.fromJson(Map<String, dynamic> json) {
    return CustomApiSession(
      accessToken: json['accessToken']?.toString() ?? '',
      refreshToken: json['refreshToken']?.toString(),
      userId: json['userId']?.toString() ?? '',
      email: json['email']?.toString(),
      displayName: json['displayName']?.toString(),
      photoUrl: json['photoUrl']?.toString(),
      providerIds: (json['providerIds'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .toList(),
      isProfileComplete: json['isProfileComplete'] == true,
      missingFields: (json['missingFields'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .toList(),
    );
  }
}
