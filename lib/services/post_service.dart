import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:get_it/get_it.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../backend/interfaces/storage_service_interface.dart';
import '../models/comment.dart';
import '../models/post.dart';
import '../models/user_profile.dart';
import '../services/local_storage_service.dart'; // Для получения профиля из кеша

class PostService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final StorageServiceInterface _storageService =
      GetIt.I<StorageServiceInterface>();
  final LocalStorageService _localStorageService =
      GetIt.I<LocalStorageService>();

  // Коллекция постов
  CollectionReference get _postsCollection => _firestore.collection('posts');

  // Получение потока постов для конкретного дерева
  Stream<List<Post>> getPostsStream(String treeId) {
    print('[PostService] Запрос потока постов для дерева $treeId');
    return _postsCollection
        .where('treeId', isEqualTo: treeId) // Фильтруем по дереву
        .orderBy(
          'createdAt',
          descending: true,
        ) // Сортируем по дате (новые сверху)
        .snapshots()
        .map((snapshot) {
      print(
        '[PostService] Получено ${snapshot.docs.length} постов для $treeId',
      );
      return snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList();
    }).handleError((error) {
      print('[PostService] Ошибка в потоке постов для $treeId: $error');
      return []; // Возвращаем пустой список при ошибке
    });
  }

  // Создание нового поста
  Future<void> createPost({
    required String treeId,
    required String content,
    List<XFile>? images,
    bool isPublic = false,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String>? anchorPersonIds,
  }) async {
    final user = _auth.currentUser;
    UserProfile? userProfile;
    if (user != null) {
      try {
        userProfile = await _localStorageService.getUser(user.uid);
        if (userProfile == null) {
          // Если в кеше нет, идем в Firestore
          final userDoc =
              await _firestore.collection('users').doc(user.uid).get();
          if (userDoc.exists) {
            userProfile = UserProfile.fromFirestore(userDoc);
            await _localStorageService.saveUser(userProfile); // Сохраняем в кеш
          }
        }
      } catch (e) {
        print('Ошибка получения профиля в createPost: $e');
        // Можно не прерывать, если имя/фото из Auth достаточно
      }
    }

    if (user == null) {
      throw Exception('Пользователь не авторизован или профиль не найден');
    }

    final newPostRef = _postsCollection.doc(); // Генерируем ID
    final now = DateTime.now();

    List<String>? uploadedImageUrls;
    if (images != null && images.isNotEmpty) {
      print(
        'Загрузка ${images.length} изображений для поста ${newPostRef.id}...',
      );
      uploadedImageUrls = await _uploadImagesSupabase(images);
      print('URL загруженных изображений: $uploadedImageUrls');
    }

    final post = Post(
      id: newPostRef.id,
      treeId: treeId,
      authorId: user.uid,
      authorName:
          userProfile?.displayName ?? user.displayName ?? 'Пользователь',
      authorPhotoUrl: userProfile?.photoURL ?? user.photoURL,
      content: content,
      imageUrls: uploadedImageUrls,
      createdAt: now,
      likedBy: [], // Изначально лайков нет
      commentCount: 0,
      isPublic: isPublic,
      scopeType: scopeType,
      anchorPersonIds: anchorPersonIds,
    );

    await newPostRef.set(post.toMap());
    print('[PostService] Пост ${newPostRef.id} создан в дереве $treeId');
  }

  // Загрузка изображений в Supabase Storage
  Future<List<String>> _uploadImagesSupabase(List<XFile> images) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }

    List<String> urls = [];
    final String bucketName = 'post-images'; // Обновленное имя бакета

    for (var image in images) {
      final fileBytes = await image.readAsBytes();
      final fileExt = image.path.split('.').last;
      // Генерируем уникальное имя файла
      final fileName = '${user.uid}/${Uuid().v4()}.$fileExt';

      print(
        '[PostService] Загрузка изображения в Supabase: $bucketName/$fileName',
      );
      try {
        final publicUrl = await _storageService.uploadBytes(
          bucket: bucketName,
          path: fileName,
          fileBytes: fileBytes,
          fileOptions: FileOptions(
            contentType: 'image/$fileExt',
          ), // Указываем тип контента
        );
        if (publicUrl != null) {
          urls.add(publicUrl);
          print('[PostService] Изображение загружено: $publicUrl');
        } else {
          print(
            '[PostService] Ошибка: Не удалось получить public URL для $fileName',
          );
          // Можно пробросить ошибку или просто пропустить файл
        }
      } catch (e) {
        print(
          '[PostService] Ошибка загрузки изображения $fileName в Supabase: $e',
        );
        // Обработка ошибки (пробросить, логировать, пропустить)
        rethrow; // Пробрасываем ошибку, чтобы createPost мог ее обработать
      }
    }

    return urls;
  }

  // Переключение лайка
  Future<void> toggleLike(String postId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }

    final postRef = _postsCollection.doc(postId);

    await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(postRef);
      if (!snapshot.exists) {
        throw Exception("Пост не найден!");
      }

      final post = Post.fromFirestore(snapshot);
      List<String> currentLikedBy = List<String>.from(post.likedBy);

      if (currentLikedBy.contains(user.uid)) {
        // Убираем лайк
        print('[PostService] Убираем лайк с поста $postId от ${user.uid}');
        transaction.update(postRef, {
          'likedBy': FieldValue.arrayRemove([user.uid]),
        });
      } else {
        // Ставим лайк
        print('[PostService] Ставим лайк на пост $postId от ${user.uid}');
        transaction.update(postRef, {
          'likedBy': FieldValue.arrayUnion([user.uid]),
        });
      }
    });
  }

  // Получение комментариев к посту
  Stream<List<Comment>> getCommentsStream(String postId) {
    return _firestore
        .collection('comments')
        .where('postId', isEqualTo: postId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) => Comment.fromFirestore(doc)).toList();
    });
  }

  // Добавление комментария
  Future<Comment> addComment({
    required String postId,
    required String content,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }

    // Получение данных о пользователе
    final userDoc = await _firestore.collection('users').doc(user.uid).get();

    final userData = userDoc.data();

    // Создание объекта комментария
    final commentId = Uuid().v4();
    final comment = Comment(
      id: commentId,
      postId: postId,
      authorId: user.uid,
      authorName: userData?['name'] ?? user.displayName ?? 'Пользователь',
      authorPhotoUrl: userData?['photoUrl'] ?? user.photoURL,
      content: content,
      createdAt: DateTime.now(),
    );

    // Сохранение комментария в Firestore
    await _firestore.collection('comments').doc(commentId).set(comment.toMap());

    // Увеличение счетчика комментариев в посте
    await _firestore.collection('posts').doc(postId).update({
      'commentCount': FieldValue.increment(1),
    });

    return comment;
  }
}
