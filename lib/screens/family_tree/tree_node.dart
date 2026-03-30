import 'package:flutter/material.dart';
import '../../models/family_person.dart';
import '../../models/family_relation.dart';
import '../../screens/relation_request_screen.dart';

class TreeNode extends StatelessWidget {
  final FamilyPerson person;
  final bool isEditMode;
  final Function(RelationType) onAddRelative;
  final VoidCallback onNodeTap;

  const TreeNode({
    Key? key,
    required this.person,
    required this.isEditMode,
    required this.onAddRelative,
    required this.onNodeTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onNodeTap,
      child: Container(
        width: 150,
        height: 200,
        child: Stack(
          children: [
            // Основная карточка
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: _getGenderColor(), width: 2),
              ),
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Фото
                    CircleAvatar(
                      radius: 30,
                      backgroundImage: person.photoUrl != null
                          ? NetworkImage(person.photoUrl!)
                          : null,
                      child: person.photoUrl == null
                          ? Text(person.name[0].toUpperCase())
                          : null,
                    ),
                    SizedBox(height: 8),

                    // Имя
                    Text(
                      person.name,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: 4),

                    // Годы жизни
                    Text(
                      _getYearsText(),
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),

                    // Статус (жив/умер)
                    Container(
                      margin: EdgeInsets.only(top: 4),
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: person.isAlive
                            ? Colors.green[100]
                            : Colors.grey[300],
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        person.isAlive ? 'Жив' : 'Умер',
                        style: TextStyle(
                          fontSize: 10,
                          color: person.isAlive
                              ? Colors.green[800]
                              : Colors.grey[700],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Кнопки добавления родственников (только в режиме редактирования)
            if (isEditMode) ...[
              // Кнопка добавления родителя (сверху)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Center(
                  child: _buildAddButton(
                    icon: Icons.arrow_upward,
                    onPressed: () => onAddRelative(RelationType.parent),
                  ),
                ),
              ),

              // Кнопка добавления супруга (справа)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                child: Center(
                  child: _buildAddButton(
                    icon: Icons.arrow_forward,
                    onPressed: () => onAddRelative(RelationType.spouse),
                  ),
                ),
              ),

              // Кнопка добавления ребенка (снизу)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Center(
                  child: _buildAddButton(
                    icon: Icons.arrow_downward,
                    onPressed: () => onAddRelative(RelationType.child),
                  ),
                ),
              ),

              // Кнопка добавления брата/сестры (слева)
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                child: Center(
                  child: _buildAddButton(
                    icon: Icons.arrow_back,
                    onPressed: () => onAddRelative(RelationType.sibling),
                  ),
                ),
              ),
            ],

            // Если это офлайн родственник (userId == null), показываем кнопку для замены
            if (isEditMode && person.userId == null)
              Positioned(
                bottom: 5,
                right: 5,
                child: IconButton(
                  icon: Icon(Icons.swap_horiz, color: Colors.blue),
                  tooltip: 'Заменить на реального пользователя',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SendRelationRequestScreen(
                          treeId: person.treeId,
                          treeName: 'Семейное дерево',
                          offlineRelative: person,
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: Colors.black26, blurRadius: 2, offset: Offset(0, 1)),
        ],
      ),
      child: IconButton(
        icon: Icon(icon, size: 16),
        onPressed: onPressed,
        padding: EdgeInsets.all(4),
        constraints: BoxConstraints(minWidth: 24, minHeight: 24),
        color: Colors.blue,
      ),
    );
  }

  Color _getGenderColor() {
    switch (person.gender) {
      case Gender.male:
        return Colors.blue;
      case Gender.female:
        return Colors.pink;
      default:
        return Colors.grey;
    }
  }

  String _getYearsText() {
    String birthYear =
        person.birthDate != null ? person.birthDate!.year.toString() : '?';

    if (person.isAlive) {
      return birthYear;
    } else {
      String deathYear =
          person.deathDate != null ? person.deathDate!.year.toString() : '?';
      return '$birthYear - $deathYear';
    }
  }
}
