void main() {
  var requestedMs = 0.003; // 3ms
  var sampleRate = 48000.0;
  var targetSamples = (requestedMs * sampleRate).round();
  print("Requested: ${requestedMs * 1000}ms");
  print("Target samples: $targetSamples");

  var sizes = [256, 512, 1024, 2048, 4096, 8192, 16384];
  for (var size in sizes) {
    if (size >= targetSamples) {
      print("Selected buffer: $size samples = ${(size / sampleRate) * 1000}ms");
      break;
    }
  }
}
