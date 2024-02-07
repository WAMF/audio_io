## 0.0.1
Kiss release
Input from mic at fixed sample rate and buffer size, no output

## 0.0.2
Kiss MVP release

Input from mic at fixed sample rate and buffer size, output fixed at mono at the same sample rate as input.
Simple quick and dirty ringbuffer for output (needs optimisation)

## 0.0.3
Bugfix
Fix 32-64bit mismatch of data.

## 0.0.4
Improvement
Allow muliple listeners on audio input

## 0.0.5
Bugfix
Thread safety - memory leak fixed :)

## 0.0.6
Improvement
Main thread call for sink removed (attempt to reduce latency introduced in 0.0.5)

## 0.0.7
Rollback 0.0.6

## 0.0.8
Improvement
Handle audio session changes
Reset audio when entering foreground

## 0.0.9
Improvement
Handle audio interruptions
Using simpler binary message system to send data (2x cpu optimisation)
Replaced invoking method with binary message for output audio
Less format conversions when sending data in and out
Prep work for upcoming buffer and samplerate selection features

## 0.1.0
New Interface
Added inteface for getting format and buffer size selection (audio frame size)
Using serial queue for read and writes to buffer

## 0.1.1
Performance
Fixing Dart side audio format to double (everything is 64bit these days, 64bit is great for processing)
Optimised data conversion 

## 0.1.2
Bugfix
Fix bug which stopped audio when coming back from background

## 0.1.3
Bugfix
Fixed issue with route swapping from speaker to headphones

## 0.1.4
Bugfix
Better way to detect changes in audio format, removed old methods

## 0.1.5
Bugfix
Using detected input sample rate rather than fixed sample rate

## 0.1.6
Cleanup
Added null safety 

## 0.1.7
Performance improvement
## 0.1.8
Fix dangling pointer

Upcoming features 
- More Optimised for RAM and CPU
- Support multiple channels
- Sample rate conversion
- File sinks for saving and compressing audio