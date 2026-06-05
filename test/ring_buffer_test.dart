import 'package:flutter_test/flutter_test.dart';

class RingBuffer<T> {
  RingBuffer(int count) : _array = List<T?>.filled(count, null);

  final List<T?> _array;
  int _readIndex = 0;
  int _writeIndex = 0;

  bool write(T element) {
    if (!isFull) {
      _array[_writeIndex % _array.length] = element;
      _writeIndex = (_writeIndex + 1) % (_array.length * 2);
      return true;
    }
    return false;
  }

  T? read() {
    if (!isEmpty) {
      final index = _readIndex % _array.length;
      final element = _array[index];
      _array[index] = null;
      _readIndex = (_readIndex + 1) % (_array.length * 2);
      return element;
    }
    return null;
  }

  void clear() {
    _readIndex = 0;
    _writeIndex = 0;
  }

  int get _availableSpaceForReading {
    final diff = _writeIndex - _readIndex;
    if (diff < 0) {
      return diff + (_array.length * 2);
    }
    return diff;
  }

  int get availableForReading => _availableSpaceForReading;

  int get availableForWriting => _array.length - _availableSpaceForReading;

  bool get isEmpty => _availableSpaceForReading == 0;

  bool get isFull => availableForWriting == 0;

  int get capacity => _array.length;
}

void main() {
  group('RingBuffer', () {
    test('basic write and read', () {
      final buffer = RingBuffer<int>(4);

      expect(buffer.write(1), isTrue);
      expect(buffer.write(2), isTrue);
      expect(buffer.write(3), isTrue);

      expect(buffer.read(), 1);
      expect(buffer.read(), 2);
      expect(buffer.read(), 3);
      expect(buffer.read(), isNull);
    });

    test('reports correct available space', () {
      final buffer = RingBuffer<int>(4);

      expect(buffer.availableForReading, 0);
      expect(buffer.availableForWriting, 4);

      buffer.write(1);
      buffer.write(2);

      expect(buffer.availableForReading, 2);
      expect(buffer.availableForWriting, 2);

      buffer.read();

      expect(buffer.availableForReading, 1);
      expect(buffer.availableForWriting, 3);
    });

    test('prevents write when full', () {
      final buffer = RingBuffer<int>(3);

      expect(buffer.write(1), isTrue);
      expect(buffer.write(2), isTrue);
      expect(buffer.write(3), isTrue);
      expect(buffer.write(4), isFalse);
      expect(buffer.isFull, isTrue);
    });

    test('sequential data integrity', () {
      final buffer = RingBuffer<int>(100);

      for (var i = 0; i < 100; i++) {
        expect(buffer.write(i), isTrue);
      }

      for (var i = 0; i < 100; i++) {
        expect(buffer.read(), i);
      }
    });

    test('wrap-around data integrity', () {
      final buffer = RingBuffer<int>(8);

      for (var cycle = 0; cycle < 10; cycle++) {
        for (var i = 0; i < 6; i++) {
          final value = cycle * 100 + i;
          expect(buffer.write(value), isTrue,
              reason: 'Write failed at cycle $cycle, i $i');
        }

        for (var i = 0; i < 6; i++) {
          final expected = cycle * 100 + i;
          final actual = buffer.read();
          expect(actual, expected,
              reason:
                  'Data corruption at cycle $cycle, i $i: expected $expected, got $actual');
        }
      }
    });

    test('interleaved write/read maintains order', () {
      final buffer = RingBuffer<int>(8);
      final written = <int>[];
      final read = <int>[];

      for (var i = 0; i < 100; i++) {
        final v1 = i * 2;
        final v2 = i * 2 + 1;
        if (buffer.write(v1)) written.add(v1);
        if (buffer.write(v2)) written.add(v2);

        final r = buffer.read();
        if (r != null) read.add(r);

        final r2 = buffer.read();
        if (r2 != null) read.add(r2);
      }

      while (!buffer.isEmpty) {
        final r = buffer.read();
        if (r != null) read.add(r);
      }

      expect(read, written);
    });

    test('detects data loss when buffer overflows', () {
      final buffer = RingBuffer<int>(4);
      var droppedCount = 0;

      for (var i = 0; i < 10; i++) {
        if (!buffer.write(i)) {
          droppedCount++;
        }
      }

      expect(droppedCount, 6);
      expect(buffer.read(), 0);
      expect(buffer.read(), 1);
      expect(buffer.read(), 2);
      expect(buffer.read(), 3);
      expect(buffer.read(), isNull);
    });

    test('large scale wrap-around integrity', () {
      final buffer = RingBuffer<double>(1024);
      var writePhase = 0.0;
      var readPhase = 0.0;
      const phaseIncrement = 0.1;

      for (var i = 0; i < 512; i++) {
        buffer.write(writePhase);
        writePhase += phaseIncrement;
      }

      for (var cycle = 0; cycle < 100; cycle++) {
        for (var i = 0; i < 256; i++) {
          buffer.write(writePhase);
          writePhase += phaseIncrement;
        }

        for (var i = 0; i < 256; i++) {
          final actual = buffer.read();
          expect(actual, closeTo(readPhase, 0.0001),
              reason: 'Phase mismatch at cycle $cycle, i $i');
          readPhase += phaseIncrement;
        }
      }
    });

    test('available space correct after wrap-around', () {
      final buffer = RingBuffer<int>(4);

      for (var cycle = 0; cycle < 20; cycle++) {
        expect(buffer.availableForWriting, 4,
            reason: 'Cycle $cycle: should have 4 write slots');
        expect(buffer.availableForReading, 0,
            reason: 'Cycle $cycle: should have 0 read slots');

        buffer.write(1);
        buffer.write(2);
        buffer.write(3);
        buffer.write(4);

        expect(buffer.availableForWriting, 0,
            reason: 'Cycle $cycle: should have 0 write slots when full');
        expect(buffer.availableForReading, 4,
            reason: 'Cycle $cycle: should have 4 read slots when full');

        buffer.read();
        buffer.read();
        buffer.read();
        buffer.read();
      }
    });

    test('no stale data after wrap-around', () {
      final buffer = RingBuffer<int>(4);

      buffer.write(100);
      buffer.write(200);
      buffer.write(300);
      buffer.write(400);

      buffer.read();
      buffer.read();
      buffer.read();
      buffer.read();

      buffer.write(1);
      buffer.write(2);

      expect(buffer.read(), 1);
      expect(buffer.read(), 2);
      expect(buffer.read(), isNull);
    });

    test('stress test with sine wave pattern', () {
      final buffer = RingBuffer<double>(2048);
      var writePhase = 0.0;
      var readPhase = 0.0;
      const frequency = 440.0;
      const sampleRate = 48000.0;
      const phaseIncrement = 2 * 3.14159265359 * frequency / sampleRate;

      for (var i = 0; i < 1024; i++) {
        final sample = 0.5 * _sin(writePhase);
        buffer.write(sample);
        writePhase += phaseIncrement;
        if (writePhase >= 2 * 3.14159265359) {
          writePhase -= 2 * 3.14159265359;
        }
      }

      for (var cycle = 0; cycle < 500; cycle++) {
        for (var i = 0; i < 512; i++) {
          final sample = 0.5 * _sin(writePhase);
          buffer.write(sample);
          writePhase += phaseIncrement;
          if (writePhase >= 2 * 3.14159265359) {
            writePhase -= 2 * 3.14159265359;
          }
        }

        for (var i = 0; i < 512; i++) {
          final expected = 0.5 * _sin(readPhase);
          final actual = buffer.read()!;

          expect((actual - expected).abs() < 0.0001, isTrue,
              reason: 'Sine wave corruption at cycle $cycle, sample $i: '
                  'expected $expected, got $actual');

          readPhase += phaseIncrement;
          if (readPhase >= 2 * 3.14159265359) {
            readPhase -= 2 * 3.14159265359;
          }
        }
      }
    });
  });
}

double _sin(double x) {
  return x -
      (x * x * x) / 6 +
      (x * x * x * x * x) / 120 -
      (x * x * x * x * x * x * x) / 5040;
}
