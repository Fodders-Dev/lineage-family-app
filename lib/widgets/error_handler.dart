import 'package:flutter/material.dart';

class ErrorHandler extends StatelessWidget {
  final Widget child;
  final Function? onRetry;

  const ErrorHandler({super.key, required this.child, this.onRetry});

  @override
  Widget build(BuildContext context) {
    ErrorWidget.builder = (FlutterErrorDetails errorDetails) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, color: Colors.red, size: 60),
                SizedBox(height: 16),
                Text(
                  'Произошла ошибка',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  errorDetails.exception.toString(),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[700]),
                ),
                SizedBox(height: 16),
                if (onRetry != null)
                  ElevatedButton(
                    onPressed: () => onRetry!(),
                    child: Text('Повторить'),
                  ),
              ],
            ),
          ),
        ),
      );
    };

    return child;
  }
}
