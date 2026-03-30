import 'package:flutter/material.dart';
import '../../models/family_person.dart';

class TreeConnection extends StatelessWidget {
  final FamilyPerson startPerson;
  final FamilyPerson endPerson;
  final ConnectionType connectionType;
  final double scale;

  const TreeConnection({
    Key? key,
    required this.startPerson,
    required this.endPerson,
    required this.connectionType,
    this.scale = 1.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(2000, 2000), // Размер соответствует размеру контейнера дерева
      painter: ConnectionPainter(
        startPerson: startPerson,
        endPerson: endPerson,
        connectionType: connectionType,
        scale: scale,
      ),
    );
  }
}

class ConnectionPainter extends CustomPainter {
  final FamilyPerson startPerson;
  final FamilyPerson endPerson;
  final ConnectionType connectionType;
  final double scale;

  ConnectionPainter({
    required this.startPerson,
    required this.endPerson,
    required this.connectionType,
    this.scale = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color =
          connectionType == ConnectionType.spouse ? Colors.red : Colors.black
      ..strokeWidth = 2.0 / scale // Учитываем масштаб
      ..style = PaintingStyle.stroke;

    // Получаем позиции узлов
    final startPos = _getPersonPosition(startPerson);
    final endPos = _getPersonPosition(endPerson);

    if (connectionType == ConnectionType.spouse) {
      // Горизонтальная линия между супругами
      final y = (startPos.dy + endPos.dy) / 2;
      canvas.drawLine(
        Offset(startPos.dx + 75, y), // Центр правой стороны первого узла
        Offset(endPos.dx - 75, y), // Центр левой стороны второго узла
        paint,
      );
    } else if (connectionType == ConnectionType.parentChild) {
      // Вертикальная линия от родителя к ребенку
      final path = Path();

      // Начинаем от нижней части родительского узла
      path.moveTo(startPos.dx + 75, startPos.dy + 100);

      // Рисуем вертикальную линию вниз
      final midY = (startPos.dy + 100 + endPos.dy) / 2;
      path.lineTo(startPos.dx + 75, midY);

      // Рисуем горизонтальную линию до позиции над ребенком
      path.lineTo(endPos.dx + 75, midY);

      // Рисуем вертикальную линию вниз к ребенку
      path.lineTo(endPos.dx + 75, endPos.dy);

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }

  // Получаем позицию узла на основе его данных
  Offset _getPersonPosition(FamilyPerson person) {
    // Здесь нужно реализовать логику расположения узлов
    // Для примера используем простую схему:

    // Базовая позиция в центре
    double x = 1000;
    double y = 1000;

    // Смещение на основе ID (для демонстрации)
    final idHash = person.id.hashCode;
    x += (idHash % 5) * 200;
    y += (idHash % 3) * 250;

    return Offset(x, y);
  }
}

enum ConnectionType { spouse, parentChild }
