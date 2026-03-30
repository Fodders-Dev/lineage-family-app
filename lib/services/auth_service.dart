import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../models/user_profile.dart';
import '../models/family_person.dart';
import '../services/analytics_service.dart';
import '../services/invitation_service.dart';
import '../services/family_service.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/auth_service_interface.dart';

class AuthService implements AuthServiceInterface {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();
  final AnalyticsService _analytics = AnalyticsService();

  // Получение текущего пользователя
  User? get currentUser => _auth.currentUser;
  @override
  String? get currentUserId => _auth.currentUser?.uid;
  @override
  String? get currentUserEmail => _auth.currentUser?.email;
  @override
  String? get currentUserDisplayName => _auth.currentUser?.displayName;
  @override
  String? get currentUserPhotoUrl => _auth.currentUser?.photoURL;
  @override
  List<String> get currentProviderIds =>
      _auth.currentUser?.providerData.map((info) => info.providerId).toList() ??
      const [];

  // Стрим для отслеживания изменений в состоянии аутентификации
  @override
  Stream<String?> get authStateChanges =>
      _auth.authStateChanges().map((user) => user?.uid);

  // Регистрация с email и паролем
  Future<UserCredential> registerWithEmail({
    required String email,
    required String password,
    required String name,
  }) async {
    try {
      final userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      await userCredential.user?.updateDisplayName(name);

      // Создаем ТОЛЬКО базовую запись в Firestore
      await _firestore.collection('users').doc(userCredential.user!.uid).set({
        'email': email,
        'displayName': name,
        'createdAt': FieldValue.serverTimestamp(),
        'authProvider': 'email',
      });

      await _analytics.logSignUp(signUpMethod: 'email');

      // Опционально: отправить верификационное письмо
      await userCredential.user!.sendEmailVerification();
      print('Verification email sent to ${userCredential.user!.email}');

      // --- NEW: Проверяем и связываем приглашение после регистрации ---
      await checkAndLinkInvitationIfNeeded(userCredential.user!.uid);
      // --- END NEW ---

      // Возвращаем UserCredential, как и ожидается сигнатурой функции
      return userCredential;
    } on FirebaseAuthException catch (e) {
      print('Ошибка при регистрации: $e');
      rethrow;
    }
  }

  // Вход с email и паролем
  Future<UserCredential> loginWithEmail(String email, String password) async {
    try {
      final result = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Логируем событие входа
      await _analytics.logLogin(loginMethod: 'email');

      await checkAndLinkInvitationIfNeeded(result.user!.uid);

      return result;
    } catch (e) {
      print('Ошибка при входе: $e');
      rethrow;
    }
  }

  // Вход через Google
  Future<UserCredential> signInWithGoogle() async {
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) throw Exception('Аутентификация Google отменена');

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential = await _auth.signInWithCredential(
        credential,
      );

      // Создаем или ОБНОВЛЯЕМ базовый профиль (не устанавливаем завершенность)
      await _handleUserAfterAuth(userCredential.user!);

      await checkAndLinkInvitationIfNeeded(userCredential.user!.uid);

      return userCredential;
    } catch (e) {
      print('Ошибка при входе через Google: $e');
      rethrow;
    }
  }

  // Выход из аккаунта
  Future<void> signOut() async {
    await _googleSignIn.signOut(); // Выход из Google, если использовался
    await _auth.signOut();
  }

  // Обработка пользователя после ЛЮБОЙ аутентификации
  Future<void> _handleUserAfterAuth(User user) async {
    try {
      final docRef = _firestore.collection('users').doc(user.uid);
      final docSnapshot = await docRef.get();

      final Map<String, dynamic> userData = {
        'lastLoginAt': FieldValue.serverTimestamp(),
      };

      // Если документа нет, создаем базовые поля
      if (!docSnapshot.exists) {
        String? firstNameFromDisplay = user.displayName?.split(' ').first;
        final nameParts = user.displayName?.split(' ') ?? [];
        String? lastNameFromDisplay =
            nameParts.length > 1 ? nameParts.sublist(1).join(' ') : null;

        userData.addAll({
          'email': user.email,
          'displayName': user.displayName ?? '',
          'firstName': firstNameFromDisplay ?? '',
          'lastName': lastNameFromDisplay ?? '',
          'photoUrl': user.photoURL,
          'createdAt': FieldValue.serverTimestamp(),
          'authProvider': user.providerData.first.providerId,
        });
        print('Creating initial user profile for ${user.uid}');
        await docRef.set(userData);
      } else {
        print('Updating last login for user ${user.uid}');
        await docRef.update(userData);
      }
    } catch (e) {
      print('Ошибка при _handleUserAfterAuth: $e');
    }
  }

  // Восстановление пароля
  Future<void> resetPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } catch (e) {
      print('Ошибка при отправке ссылки для сброса пароля: $e');
      rethrow;
    }
  }

  // Метод для повторной аутентификации пользователя перед удалением
  Future<UserCredential> reauthenticateUser(String password) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }

    // Создаем учетные данные
    AuthCredential credential = EmailAuthProvider.credential(
      email: user.email!,
      password: password,
    );

    // Повторно аутентифицируем пользователя
    return await user.reauthenticateWithCredential(credential);
  }

  // Обновленный метод удаления аккаунта
  Future<void> deleteAccount([String? password]) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }

    try {
      // Проверяем, как пользователь вошел в систему
      final providerData = user.providerData;
      final isEmailProvider = providerData.any(
        (info) => info.providerId == 'password',
      );

      // Если пользователь вошел через email/пароль, требуется повторная аутентификация
      if (isEmailProvider) {
        if (password == null || password.isEmpty) {
          throw Exception('Для удаления аккаунта требуется пароль');
        }

        // Повторная аутентификация
        await reauthenticateUser(password);
      } else {
        // Для других провайдеров (Google и т.д.) может потребоваться другой подход
        // В некоторых случаях Firebase может позволить удалить аккаунт без повторной аутентификации
        // или может потребоваться другой механизм повторной аутентификации
      }

      // Удаление данных из Firestore
      await _firestore.collection('users').doc(user.uid).delete();

      // Удаление аккаунта
      await user.delete();
    } catch (e) {
      print('Ошибка при удалении аккаунта: $e');
      rethrow;
    }
  }

  // НОВАЯ проверка завершенности профиля
  Future<Map<String, dynamic>> checkProfileCompletenessForUser(
    User user,
  ) async {
    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();

      if (!doc.exists) {
        // Такого быть не должно после рефакторинга _handleUserAfterAuth
        // но на всякий случай возвращаем статус неполного профиля
        print(
          'Warning: User document not found during completeness check for ${user.uid}',
        );
        return {
          'isComplete': false,
          'missingFields': ['firstName', 'lastName', 'phoneNumber', 'username'],
        };
      }

      final data = doc.data()!;
      List<String> missingFields = [];

      // Проверяем обязательные поля
      if (data['firstName'] == null || data['firstName'].isEmpty) {
        missingFields.add('firstName');
      }
      if (data['lastName'] == null || data['lastName'].isEmpty) {
        missingFields.add('lastName');
      }
      if (data['phoneNumber'] == null || data['phoneNumber'].isEmpty) {
        missingFields.add('phoneNumber');
      }
      if (data['username'] == null || data['username'].isEmpty) {
        missingFields.add('username');
      }

      // Возвращаем результат
      if (missingFields.isEmpty) {
        print('Profile is complete for ${user.uid}');
        return {'isComplete': true};
      } else {
        print(
          'Profile is incomplete for ${user.uid}. Missing: ${missingFields.join(', ')}',
        );
        return {'isComplete': false, 'missingFields': missingFields};
      }
    } catch (e) {
      print('Error checking profile completeness: $e');
      // В случае ошибки считаем профиль неполным, чтобы пользователь мог его исправить
      return {
        'isComplete': false,
        'missingFields': ['error'],
      };
    }
  }

  @override
  Future<Map<String, dynamic>> checkProfileCompleteness() async {
    final user = _auth.currentUser;
    if (user == null) {
      return {
        'isComplete': false,
        'missingFields': ['auth'],
      };
    }
    return checkProfileCompletenessForUser(user);
  }

  @override
  Future<void> processPendingInvitation() async {
    final userId = currentUserId;
    if (userId == null) {
      return;
    }
    await checkAndLinkInvitationIfNeeded(userId);
  }

  // Добавим метод для добавления информации в существующий профиль
  Future<void> updateProfile(UserProfile profile) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      throw Exception('Пользователь не авторизован');
    }

    try {
      await _firestore.collection('users').doc(userId).update({
        if (profile.displayName.isNotEmpty) 'displayName': profile.displayName,
        if (profile.username != null && profile.username!.isNotEmpty)
          'username': profile.username,
        if (profile.phoneNumber != null && profile.phoneNumber!.isNotEmpty)
          'phoneNumber': profile.phoneNumber,
        if (profile.gender != null) 'gender': _genderToString(profile.gender!),
        if (profile.birthDate != null)
          'birthDate': Timestamp.fromDate(profile.birthDate!),
        if (profile.country != null && profile.country!.isNotEmpty)
          'country': profile.country,
        if (profile.city != null && profile.city!.isNotEmpty)
          'city': profile.city,
        'updatedAt': Timestamp.now(),
      });
    } catch (e) {
      print('Error updating profile: $e');
      throw Exception('Ошибка при обновлении профиля: $e');
    }
  }

  @override
  Future<void> updateDisplayName(String displayName) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }
    await user.updateDisplayName(displayName);
  }

  // Добавляем методы проверки уникальности
  Future<bool> isEmailAvailable(String email) async {
    try {
      final querySnapshot = await _firestore
          .collection('users')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();

      return querySnapshot.docs.isEmpty;
    } catch (e) {
      print('Ошибка при проверке email: $e');
      return false;
    }
  }

  Future<bool> isPhoneAvailable(String phone) async {
    try {
      final querySnapshot = await _firestore
          .collection('users')
          .where('phoneNumber', isEqualTo: phone)
          .limit(1)
          .get();

      return querySnapshot.docs.isEmpty;
    } catch (e) {
      print('Ошибка при проверке телефона: $e');
      return false;
    }
  }

  Future<bool> isUsernameAvailable(String username) async {
    try {
      final querySnapshot = await _firestore
          .collection('users')
          .where('username', isEqualTo: username)
          .limit(1)
          .get();

      return querySnapshot.docs.isEmpty;
    } catch (e) {
      print('Ошибка при проверке никнейма: $e');
      return false;
    }
  }

  // Добавляем преобразование Gender в строку
  String _genderToString(Gender gender) {
    switch (gender) {
      case Gender.male:
        return 'male';
      case Gender.female:
        return 'female';
      case Gender.other:
        return 'other';
      case Gender.unknown:
      default:
        return 'unknown';
    }
  }

  // --- NEW: Публичный метод для проверки и связывания приглашения ---
  Future<void> checkAndLinkInvitationIfNeeded(String userId) async {
    final invitationService = GetIt.I<InvitationService>(); // Получаем из GetIt
    if (invitationService.hasPendingInvitation) {
      final treeId = invitationService.pendingTreeId!;
      final personId = invitationService.pendingPersonId!;
      print(
        'Found pending invitation after auth. Attempting to link user $userId to person $personId in tree $treeId',
      );
      try {
        final familyService = GetIt.I<FamilyService>();
        await familyService.linkInvitedUser(treeId, personId, userId);
        print('Link attempt finished.');
        // Опционально: показать пользователю сообщение об успехе
        // Например, через какой-то глобальный сервис уведомлений или EventBus
      } catch (linkError) {
        print('Error during post-auth linking: $linkError');
        // Логируем, но не прерываем основной поток
      } finally {
        invitationService.clearPendingInvitation();
      }
    }
  }
  // --- END NEW ---

  // <<< НОВЫЙ МЕТОД: Обновление FCM токена пользователя >>>
  Future<void> updateUserFcmToken(String userId, String? token) async {
    if (token == null || userId.isEmpty)
      return; // Не сохраняем null токен или для пустого userId

    print('[AuthService] Updating FCM token for user $userId');
    final userRef = _firestore.collection('users').doc(userId);

    try {
      // Используем arrayUnion, чтобы добавить токен, если его еще нет
      await userRef.update({
        'fcmTokens': FieldValue.arrayUnion([token]),
        // Обновляем время последнего обновления профиля, если нужно
        // 'updatedAt': FieldValue.serverTimestamp(),
      });
      print('[AuthService] FCM token updated via arrayUnion for user $userId');
    } catch (e) {
      // Если поле fcmTokens еще не существует или другая ошибка при update
      if (e
          is FirebaseException /* && (e.code == 'not-found' || e.code == ...) */) {
        // Проверка кода ошибки может быть не универсальной
        print(
          '[AuthService] Field fcmTokens might not exist for $userId or update failed. Trying set with merge...',
        );
        try {
          await userRef.set(
            {
              'fcmTokens': [token], // Создаем массив с одним токеном
              // 'updatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          ); // Используем merge, чтобы не затереть другие поля
          print(
            '[AuthService] FCM token field created/updated via set(merge:true) for user $userId',
          );
        } catch (setErr) {
          print(
            '[AuthService] Error setting FCM token field for user $userId: $setErr',
          );
        }
      } else {
        // Другая ошибка при обновлении
        print('[AuthService] Error updating FCM token for user $userId: $e');
      }
    }
  }
  // <<< КОНЕЦ НОВОГО МЕТОДА >>>

  @override
  String describeError(Object error) {
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'user-not-found':
          return 'Пользователь не найден';
        case 'wrong-password':
          return 'Неверный пароль';
        case 'email-already-in-use':
          return 'Этот email уже используется';
        case 'weak-password':
          return 'Слишком простой пароль';
        case 'invalid-email':
          return 'Неверный формат email';
        default:
          return error.message ?? 'Ошибка авторизации';
      }
    }

    final message = error.toString();
    if (message.startsWith('Exception: ')) {
      return message.substring('Exception: '.length);
    }
    return message;
  }
}
