import 'package:flutter/material.dart';

import 'passthrough_screen.dart';
import 'sine_wave_screen.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const DemoPageView(),
    );
  }
}

class DemoPageView extends StatefulWidget {
  const DemoPageView({super.key});

  @override
  State<DemoPageView> createState() => _DemoPageViewState();
}

class _DemoPageViewState extends State<DemoPageView> {
  final _pageController = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          setState(() {
            _currentPage = index;
          });
        },
        children: const [
          PassthroughScreen(),
          SineWaveScreen(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentPage,
        onTap: (index) {
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.mic),
            label: 'Passthrough',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.waves),
            label: 'Sine Wave',
          ),
        ],
      ),
    );
  }
}
