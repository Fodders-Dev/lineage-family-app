import 'dart:ui';

import 'package:flutter/material.dart';

/// Класс с различными типами анимаций для перехода между страницами
class PageTransitions {
  /// Переход с затуханием
  static Widget fadeTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(opacity: animation, child: child);
  }

  /// Переход с скольжением справа
  static Widget slideRightTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    const begin = Offset(1.0, 0.0);
    const end = Offset.zero;
    const curve = Curves.easeInOutCubic;

    var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
    var offsetAnimation = animation.drive(tween);

    return SlideTransition(position: offsetAnimation, child: child);
  }

  /// Переход с скольжением слева
  static Widget slideLeftTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    const begin = Offset(-1.0, 0.0);
    const end = Offset.zero;
    const curve = Curves.easeInOutCubic;

    var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
    var offsetAnimation = animation.drive(tween);

    return SlideTransition(position: offsetAnimation, child: child);
  }

  /// Переход с скольжением снизу
  static Widget slideUpTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    const begin = Offset(0.0, 1.0);
    const end = Offset.zero;
    const curve = Curves.easeOutQuart;

    var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
    var offsetAnimation = animation.drive(tween);

    return SlideTransition(position: offsetAnimation, child: child);
  }

  /// Переход с скольжением сверху
  static Widget slideDownTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    const begin = Offset(0.0, -1.0);
    const end = Offset.zero;
    const curve = Curves.easeOutQuart;

    var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
    var offsetAnimation = animation.drive(tween);

    return SlideTransition(position: offsetAnimation, child: child);
  }

  /// Переход с масштабированием
  static Widget scaleTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    const curve = Curves.easeInOutCubic;
    var scaleAnimation = CurvedAnimation(parent: animation, curve: curve);

    return ScaleTransition(
      scale: scaleAnimation,
      child: FadeTransition(opacity: scaleAnimation, child: child),
    );
  }

  /// Переход с поворотом и масштабированием
  static Widget rotateAndScaleTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    const curve = Curves.easeInOutCubic;
    var curvedAnimation = CurvedAnimation(parent: animation, curve: curve);

    return RotationTransition(
      turns: Tween<double>(begin: 0.05, end: 0.0).animate(curvedAnimation),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.0, end: 1.0).animate(curvedAnimation),
        child: FadeTransition(opacity: curvedAnimation, child: child),
      ),
    );
  }

  /// Переход с размытием
  static Widget blurTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: animation,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          return ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: (1 - animation.value) * 5,
              sigmaY: (1 - animation.value) * 5,
            ),
            child: child,
          );
        },
        child: child,
      ),
    );
  }

  /// Элегантный переход для модальных окон
  static Widget modalTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    const begin = Offset(0.0, 1.0);
    const end = Offset.zero;
    const curve = Curves.easeOutQuint;

    var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
    var offsetAnimation = animation.drive(tween);

    // Затемнение фона
    return Stack(
      children: [
        // Затемняющий слой
        FadeTransition(
          opacity: Tween<double>(begin: 0.0, end: 0.5).animate(animation),
          child: Container(color: Colors.black),
        ),
        // Скользящий контент
        SlideTransition(position: offsetAnimation, child: child),
      ],
    );
  }
}
