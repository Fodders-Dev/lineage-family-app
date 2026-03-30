import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';
import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../models/relation_request.dart';
import '../models/user_profile.dart';

class RelationRequestsScreen extends StatefulWidget {
  final String treeId;

  const RelationRequestsScreen({Key? key, required this.treeId})
      : super(key: key);

  @override
  _RelationRequestsScreenState createState() => _RelationRequestsScreenState();
}

class _RelationRequestsScreenState extends State<RelationRequestsScreen> {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final FamilyTreeServiceInterface _familyService =
      GetIt.I<FamilyTreeServiceInterface>();
  final ProfileServiceInterface _profileService =
      GetIt.I<ProfileServiceInterface>();

  List<RelationRequest> _requests = [];
  Map<String, UserProfile?> _userProfiles = {};
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRequests();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final focusNode = FocusNode();
      FocusScope.of(context).requestFocus(focusNode);
      focusNode.addListener(() {
        if (focusNode.hasFocus) {
          _loadRequests();
        }
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      _loadRequests();
    }
  }

  Future<void> _loadRequests() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      if (_authService.currentUserId == null) {
        setState(() {
          _error = 'Пользователь не авторизован';
          _isLoading = false;
        });
        return;
      }

      final requests = await _familyService.getPendingRelationRequests(
        treeId: widget.treeId,
      );
      final profiles = <String, UserProfile?>{};
      for (final senderId
          in requests.map((request) => request.senderId).toSet()) {
        try {
          profiles[senderId] = await _profileService.getUserProfile(senderId);
        } catch (e) {
          print('Ошибка загрузки профиля отправителя $senderId: $e');
          profiles[senderId] = null;
        }
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _requests = requests;
        _userProfiles = profiles;
        _isLoading = false;
      });
    } catch (e) {
      print('Ошибка при загрузке запросов: $e');
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Ошибка при загрузке запросов: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  Future<void> _respondToRequest(String requestId, RequestStatus status) async {
    setState(() {
      _isLoading = true;
    });

    try {
      await _familyService.respondToRelationRequest(
        requestId: requestId,
        response: status,
      );

      await _loadRequests();

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status == RequestStatus.accepted
                ? 'Запрос принят'
                : 'Запрос отклонен',
          ),
        ),
      );
    } catch (e) {
      print('Ошибка при обработке запроса: $e');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Запросы на родство')),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: Colors.red),
                      SizedBox(height: 16),
                      Text(
                        'Произошла ошибка',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 8),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 32),
                        child: Text(_error!, textAlign: TextAlign.center),
                      ),
                      SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadRequests,
                        child: Text('Повторить'),
                      ),
                    ],
                  ),
                )
              : _requests.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.people_outline,
                              size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text(
                            'Нет запросов на родство',
                            style: TextStyle(fontSize: 18),
                          ),
                          Text(
                            'Когда кто-то пригласит вас в свое дерево,\nзапросы появятся здесь',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _requests.length,
                      itemBuilder: (context, index) {
                        final request = _requests[index];
                        final senderProfile = _userProfiles[request.senderId];

                        return Card(
                          margin:
                              EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundImage:
                                          senderProfile?.photoURL != null
                                              ? NetworkImage(
                                                  senderProfile!.photoURL!)
                                              : null,
                                      child: senderProfile?.photoURL == null
                                          ? Icon(Icons.person)
                                          : null,
                                    ),
                                    SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            senderProfile?.displayName ??
                                                'Неизвестный пользователь',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                          ),
                                          Text(
                                            'Хочет добавить вас как: ${FamilyRelation.getRelationName(request.getRecipientToSender(), Gender.unknown)}',
                                            style: TextStyle(
                                                color: Colors.grey[600]),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                if (request.message != null &&
                                    request.message!.isNotEmpty) ...[
                                  SizedBox(height: 12),
                                  Container(
                                    padding: EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.grey[100],
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(request.message!),
                                  ),
                                ],
                                SizedBox(height: 16),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton(
                                      onPressed: () => _respondToRequest(
                                        request.id,
                                        RequestStatus.rejected,
                                      ),
                                      style: TextButton.styleFrom(
                                        foregroundColor: Colors.grey[700],
                                      ),
                                      child: Text('Отклонить'),
                                    ),
                                    SizedBox(width: 8),
                                    ElevatedButton(
                                      onPressed: () => _respondToRequest(
                                        request.id,
                                        RequestStatus.accepted,
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                            Theme.of(context).primaryColor,
                                        foregroundColor: Colors.white,
                                      ),
                                      child: Text('Принять'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
