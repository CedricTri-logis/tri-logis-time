import 'package:flutter/material.dart';

import '../../core/config/constants.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppConstants.appName),
        centerTitle: true,
      ),
      body: const Center(
        child: Text(
          'Home Screen Placeholder',
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
