#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <algorithm>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <atomic>
#include <vector>
#include <cmath>

#ifdef __ANDROID__
#include <android/log.h>
#endif

#if defined(_WIN32)
// GetCurrentProcessId, used to exclude our own process from WASAPI loopback
// capture so an app playing TTS through the output stream does not hear itself.
#include <windows.h>
#endif

const int CHANNELS = 1;

const int AUDIO_FORMAT_FLOAT64 = 0;
const int AUDIO_FORMAT_PCM16 = 1;

// Input source selector, mirrored by AudioIoInputSource.index on the Dart side.
const int INPUT_SOURCE_MICROPHONE = 0;
const int INPUT_SOURCE_SYSTEM_AUDIO = 1;

// Single-producer single-consumer lock-free ring buffer.
//
// Power-of-two storage with monotonic 64-bit positions: the producer only
// advances head, the consumer only advances tail, each side reads the other
// with acquire ordering. The realtime audio callback therefore never blocks
// behind a descheduled Dart thread, which the previous std::mutex allowed
// (priority inversion -> audible glitches). Copies are bulk memcpy in at
// most two segments instead of per-sample modulo arithmetic.
//
// clear() only requests a clear: the consumer applies it at its next read,
// because tail belongs exclusively to the consumer. The request captures
// the head position at clear time, so samples written AFTER the request
// survive - a barge-in that clears and immediately queues the next
// response must not clip that response's start.
template <typename T>
class RingBuffer {
private:
    std::vector<T> buffer;
    size_t capacity;
    size_t mask;
    std::atomic<uint64_t> head{0};
    std::atomic<uint64_t> tail{0};
    std::atomic<bool> clearRequested{false};
    std::atomic<uint64_t> clearUpTo{0};

    static size_t nextPow2(size_t value) {
        size_t result = 1;
        while (result < value) result <<= 1;
        return result;
    }

public:
    explicit RingBuffer(size_t minCapacity)
        : buffer(nextPow2(minCapacity)),
          capacity(buffer.size()),
          mask(buffer.size() - 1) {}

    size_t write(const T* data, size_t count) {
        const uint64_t h = head.load(std::memory_order_relaxed);
        const uint64_t t = tail.load(std::memory_order_acquire);
        const size_t free = capacity - (size_t)(h - t);
        const size_t n = count < free ? count : free;
        const size_t start = (size_t)(h & mask);
        const size_t first = n < capacity - start ? n : capacity - start;
        std::memcpy(buffer.data() + start, data, first * sizeof(T));
        std::memcpy(buffer.data(), data + first, (n - first) * sizeof(T));
        head.store(h + n, std::memory_order_release);
        return n;
    }

    size_t read(T* data, size_t count) {
        if (clearRequested.exchange(false, std::memory_order_acq_rel)) {
            const uint64_t target = clearUpTo.load(std::memory_order_acquire);
            if (target > tail.load(std::memory_order_relaxed)) {
                tail.store(target, std::memory_order_release);
            }
        }
        const uint64_t t = tail.load(std::memory_order_relaxed);
        const uint64_t h = head.load(std::memory_order_acquire);
        const size_t avail = (size_t)(h - t);
        const size_t n = count < avail ? count : avail;
        const size_t start = (size_t)(t & mask);
        const size_t first = n < capacity - start ? n : capacity - start;
        std::memcpy(data, buffer.data() + start, first * sizeof(T));
        std::memcpy(data + first, buffer.data(), (n - first) * sizeof(T));
        tail.store(t + n, std::memory_order_release);
        return n;
    }

    void clear() {
        clearUpTo.store(head.load(std::memory_order_acquire),
                        std::memory_order_release);
        clearRequested.store(true, std::memory_order_release);
    }

    size_t available_read() const {
        return (size_t)(head.load(std::memory_order_acquire) -
                        tail.load(std::memory_order_acquire));
    }

    size_t available_write() const {
        return capacity - available_read();
    }
};

using DoubleRingBuffer = RingBuffer<double>;
using Int16RingBuffer = RingBuffer<int16_t>;

static size_t ringBufferSizeForRate(int sampleRate) {
    size_t size = (size_t)(sampleRate * 0.2);
    if (size < 8192) size = 8192;
    return size;
}

// Scratch buffers must cover the largest callback the backend can deliver;
// sized generously up front so the realtime callback never allocates.
const size_t SCRATCH_FRAMES = 8192;

struct AudioContext {
    ma_device device;
    // System-audio (loopback) mode uses a second, playback-only device so the
    // output stream keeps working: a WASAPI loopback device is capture-only
    // and cannot carry a playback side. Unused in microphone (duplex) mode.
    ma_device playbackDevice;
    bool hasPlaybackDevice;
    DoubleRingBuffer* inputRingBuffer;
    DoubleRingBuffer* outputRingBuffer;
    Int16RingBuffer* inputRingBufferPcm16;
    Int16RingBuffer* outputRingBufferPcm16;
    // The capture (input) and playback (output) conversions get their own
    // scratch buffers. In microphone/duplex mode a single callback fills both
    // in sequence; in loopback mode the capture and playback devices run on
    // separate realtime threads, so sharing one scratch buffer would be a data
    // race. Splitting them is safe in both modes.
    std::vector<double> scratchDouble;
    std::vector<int16_t> scratchPcm16;
    std::vector<double> scratchDoubleOut;
    std::vector<int16_t> scratchPcm16Out;
    std::atomic<bool> isRunning;
    std::atomic<bool> isDeviceInitialized;
    double frameDuration;
    int sampleRate;
    int format;
    int inputSource;

    AudioContext(int rate, int fmt)
        : hasPlaybackDevice(false),
          inputRingBuffer(nullptr),
          outputRingBuffer(nullptr),
          inputRingBufferPcm16(nullptr),
          outputRingBufferPcm16(nullptr),
          isRunning(false),
          isDeviceInitialized(false),
          frameDuration(0.003),
          sampleRate(rate),
          format(fmt),
          inputSource(INPUT_SOURCE_MICROPHONE) {
        size_t bufSize = ringBufferSizeForRate(rate);
        if (fmt == AUDIO_FORMAT_PCM16) {
            inputRingBufferPcm16 = new Int16RingBuffer(bufSize);
            outputRingBufferPcm16 = new Int16RingBuffer(bufSize);
            scratchPcm16.resize(SCRATCH_FRAMES);
            scratchPcm16Out.resize(SCRATCH_FRAMES);
        } else {
            inputRingBuffer = new DoubleRingBuffer(bufSize);
            outputRingBuffer = new DoubleRingBuffer(bufSize);
            scratchDouble.resize(SCRATCH_FRAMES);
            scratchDoubleOut.resize(SCRATCH_FRAMES);
        }
    }

    ~AudioContext() {
        delete inputRingBuffer;
        delete outputRingBuffer;
        delete inputRingBufferPcm16;
        delete outputRingBufferPcm16;
    }
};

// Runs on the realtime audio thread: no locks, no allocation. Conversions
// go through preallocated scratch, chunked in case the backend delivers a
// callback larger than the scratch buffer.
void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    AudioContext* context = (AudioContext*)pDevice->pUserData;

    if (context->format == AUDIO_FORMAT_PCM16) {
        if (pInput) {
            int16_t* scratch = context->scratchPcm16.data();
            const float* floatInput = (const float*)pInput;
            for (ma_uint32 offset = 0; offset < frameCount; offset += SCRATCH_FRAMES) {
                const ma_uint32 n = (ma_uint32)std::min((size_t)(frameCount - offset), SCRATCH_FRAMES);
                for (ma_uint32 i = 0; i < n; i++) {
                    float clamped = fminf(fmaxf(floatInput[offset + i], -1.0f), 1.0f);
                    scratch[i] = (int16_t)(clamped * 32767.0f);
                }
                context->inputRingBufferPcm16->write(scratch, n);
            }
        }
        if (pOutput) {
            int16_t* scratch = context->scratchPcm16Out.data();
            float* floatOutput = (float*)pOutput;
            for (ma_uint32 offset = 0; offset < frameCount; offset += SCRATCH_FRAMES) {
                const ma_uint32 n = (ma_uint32)std::min((size_t)(frameCount - offset), SCRATCH_FRAMES);
                size_t framesRead = context->outputRingBufferPcm16->read(scratch, n);
                for (ma_uint32 i = 0; i < n; i++) {
                    floatOutput[offset + i] = (i < framesRead) ? (float)scratch[i] / 32767.0f : 0.0f;
                }
            }
        }
    } else {
        if (pInput) {
            double* scratch = context->scratchDouble.data();
            const float* floatInput = (const float*)pInput;
            for (ma_uint32 offset = 0; offset < frameCount; offset += SCRATCH_FRAMES) {
                const ma_uint32 n = (ma_uint32)std::min((size_t)(frameCount - offset), SCRATCH_FRAMES);
                for (ma_uint32 i = 0; i < n; i++) {
                    scratch[i] = (double)floatInput[offset + i];
                }
                context->inputRingBuffer->write(scratch, n);
            }
        }
        if (pOutput) {
            double* scratch = context->scratchDoubleOut.data();
            float* floatOutput = (float*)pOutput;
            for (ma_uint32 offset = 0; offset < frameCount; offset += SCRATCH_FRAMES) {
                const ma_uint32 n = (ma_uint32)std::min((size_t)(frameCount - offset), SCRATCH_FRAMES);
                size_t framesRead = context->outputRingBuffer->read(scratch, n);
                for (ma_uint32 i = 0; i < n; i++) {
                    floatOutput[offset + i] = (i < framesRead) ? (float)scratch[i] : 0.0f;
                }
            }
        }
    }
}

extern "C" {

void* audio_io_create() {
    AudioContext* context = new AudioContext(48000, AUDIO_FORMAT_FLOAT64);
    return context;
}

void* audio_io_create_with_latency(double frameDuration) {
    AudioContext* context = new AudioContext(48000, AUDIO_FORMAT_FLOAT64);
    context->frameDuration = frameDuration;
    return context;
}

void* audio_io_create_with_config(double frameDuration, int sampleRate, int format) {
    if (sampleRate <= 0) sampleRate = 48000;
    if (format != AUDIO_FORMAT_PCM16) format = AUDIO_FORMAT_FLOAT64;
    AudioContext* context = new AudioContext(sampleRate, format);
    context->frameDuration = frameDuration;
    return context;
}

int audio_io_init_device(void* handle) {
    if (!handle) return -1;

    AudioContext* context = (AudioContext*)handle;

    ma_uint32 periodSizeInFrames = (ma_uint32)(context->frameDuration * context->sampleRate);
    if (periodSizeInFrames < 64) periodSizeInFrames = 64;
    if (periodSizeInFrames > 4096) periodSizeInFrames = 4096;

    if (context->inputSource == INPUT_SOURCE_SYSTEM_AUDIO) {
#if defined(_WIN32)
        // System audio: capture the default render endpoint's mix via WASAPI
        // loopback, excluding our own process ID so audio this app plays out
        // (e.g. TTS through the output stream) is not fed back into the input.
        // A loopback device is capture-only, so a separate playback device is
        // opened below to keep the output stream functional.
        ma_device_config captureConfig = ma_device_config_init(ma_device_type_loopback);
        captureConfig.capture.pDeviceID = NULL;         // default render endpoint
        captureConfig.capture.format = ma_format_f32;
        captureConfig.capture.channels = CHANNELS;      // miniaudio downmixes to mono
        captureConfig.capture.shareMode = ma_share_mode_shared;
        captureConfig.sampleRate = context->sampleRate; // miniaudio resamples to engine rate
        captureConfig.dataCallback = data_callback;
        captureConfig.pUserData = context;
        captureConfig.periodSizeInFrames = periodSizeInFrames;
        captureConfig.wasapi.loopbackProcessID = (ma_uint32)GetCurrentProcessId();
        captureConfig.wasapi.loopbackProcessExclude = MA_TRUE;

        if (ma_device_init(NULL, &captureConfig, &context->device) != MA_SUCCESS) {
            return -1;
        }

        ma_device_config playbackConfig = ma_device_config_init(ma_device_type_playback);
        playbackConfig.playback.pDeviceID = NULL;
        playbackConfig.playback.format = ma_format_f32;
        playbackConfig.playback.channels = CHANNELS;
        playbackConfig.playback.shareMode = ma_share_mode_shared;
        playbackConfig.sampleRate = context->sampleRate;
        playbackConfig.dataCallback = data_callback;
        playbackConfig.pUserData = context;
        playbackConfig.periodSizeInFrames = periodSizeInFrames;

        if (ma_device_init(NULL, &playbackConfig, &context->playbackDevice) != MA_SUCCESS) {
            ma_device_uninit(&context->device);
            return -1;
        }

        context->hasPlaybackDevice = true;
        context->isDeviceInitialized = true;
        return 0;
#else
        // Loopback is a WASAPI-only feature; the Dart layer rejects system
        // audio on non-Windows backends before reaching here. Guard anyway.
        return -1;
#endif
    }

    ma_device_config config = ma_device_config_init(ma_device_type_duplex);
    config.capture.pDeviceID = NULL;
    config.capture.format = ma_format_f32;
    config.capture.channels = CHANNELS;
    config.capture.shareMode = ma_share_mode_shared;
    config.playback.pDeviceID = NULL;
    config.playback.format = ma_format_f32;
    config.playback.channels = CHANNELS;
    config.playback.shareMode = ma_share_mode_shared;
    config.sampleRate = context->sampleRate;
    config.dataCallback = data_callback;
    config.pUserData = context;
    config.periodSizeInFrames = periodSizeInFrames;

    #ifdef __ANDROID__
    if (context->frameDuration <= 0.002) {
        config.performanceProfile = ma_performance_profile_low_latency;
    } else if (context->frameDuration <= 0.004) {
        config.performanceProfile = ma_performance_profile_conservative;
    } else {
        config.performanceProfile = ma_performance_profile_low_latency;
    }
    config.aaudio.usage = ma_aaudio_usage_media;
    config.aaudio.contentType = ma_aaudio_content_type_music;
    config.periods = 2;
    #endif

    if (ma_device_init(NULL, &config, &context->device) != MA_SUCCESS) {
        return -1;
    }

    context->isDeviceInitialized = true;
    return 0;
}

void audio_io_destroy(void* handle) {
    if (!handle) return;
    
    AudioContext* context = (AudioContext*)handle;
    
    if (context->isRunning) {
        ma_device_stop(&context->device);
        if (context->hasPlaybackDevice) {
            ma_device_stop(&context->playbackDevice);
        }
    }

    if (context->isDeviceInitialized) {
        ma_device_uninit(&context->device);
        if (context->hasPlaybackDevice) {
            ma_device_uninit(&context->playbackDevice);
        }
    }
    delete context;
}

int audio_io_start(void* handle) {
    if (!handle) return -1;
    
    AudioContext* context = (AudioContext*)handle;
    
    if (context->isRunning) return 0;
    
    // Initialize device if not already done
    if (!context->isDeviceInitialized) {
        if (audio_io_init_device(handle) != 0) {
            return -1;
        }
    }
    
    if (ma_device_start(&context->device) != MA_SUCCESS) {
        return -1;
    }

    if (context->hasPlaybackDevice) {
        if (ma_device_start(&context->playbackDevice) != MA_SUCCESS) {
            ma_device_stop(&context->device);
            return -1;
        }
    }

    context->isRunning = true;
    return 0;
}

int audio_io_stop(void* handle) {
    if (!handle) return -1;

    AudioContext* context = (AudioContext*)handle;

    if (!context->isRunning) return 0;

    if (ma_device_stop(&context->device) != MA_SUCCESS) {
        return -1;
    }

    if (context->hasPlaybackDevice) {
        if (ma_device_stop(&context->playbackDevice) != MA_SUCCESS) {
            return -1;
        }
    }

    context->isRunning = false;
    return 0;
}

int audio_io_read(void* handle, double* buffer, int frameCount) {
    if (!handle || !buffer || frameCount <= 0) return 0;
    
    AudioContext* context = (AudioContext*)handle;
    return context->inputRingBuffer->read(buffer, frameCount);
}

int audio_io_write(void* handle, const double* buffer, int frameCount) {
    if (!handle || !buffer || frameCount <= 0) return 0;
    
    AudioContext* context = (AudioContext*)handle;
    return context->outputRingBuffer->write(buffer, frameCount);
}

int audio_io_read_pcm16(void* handle, int16_t* buffer, int frameCount) {
    if (!handle || !buffer || frameCount <= 0) return 0;
    AudioContext* context = (AudioContext*)handle;
    if (!context->inputRingBufferPcm16) return 0;
    return context->inputRingBufferPcm16->read(buffer, frameCount);
}

int audio_io_write_pcm16(void* handle, const int16_t* buffer, int frameCount) {
    if (!handle || !buffer || frameCount <= 0) return 0;
    AudioContext* context = (AudioContext*)handle;
    if (!context->outputRingBufferPcm16) return 0;
    return context->outputRingBufferPcm16->write(buffer, frameCount);
}

void audio_io_clear_output(void* handle) {
    if (!handle) return;
    AudioContext* context = (AudioContext*)handle;
    if (context->outputRingBufferPcm16) context->outputRingBufferPcm16->clear();
    if (context->outputRingBuffer) context->outputRingBuffer->clear();
}

int audio_io_get_format(void* handle) {
    if (!handle) return AUDIO_FORMAT_FLOAT64;
    AudioContext* context = (AudioContext*)handle;
    return context->format;
}

int audio_io_get_sample_rate(void* handle) {
    if (!handle) return 0;
    AudioContext* context = (AudioContext*)handle;
    if (context->isDeviceInitialized) {
        return context->device.sampleRate;
    }
    return context->sampleRate;
}

int audio_io_get_channels(void* handle) {
    return CHANNELS;
}

int audio_io_get_available_read_frames(void* handle) {
    if (!handle) return 0;
    AudioContext* context = (AudioContext*)handle;
    if (context->format == AUDIO_FORMAT_PCM16) {
        return context->inputRingBufferPcm16 ? context->inputRingBufferPcm16->available_read() : 0;
    }
    return context->inputRingBuffer ? context->inputRingBuffer->available_read() : 0;
}

int audio_io_get_available_write_space(void* handle) {
    if (!handle) return 0;
    AudioContext* context = (AudioContext*)handle;
    if (context->format == AUDIO_FORMAT_PCM16) {
        return context->outputRingBufferPcm16 ? context->outputRingBufferPcm16->available_write() : 0;
    }
    return context->outputRingBuffer ? context->outputRingBuffer->available_write() : 0;
}

int audio_io_set_frame_duration(void* handle, double duration) {
    if (!handle) return -1;
    AudioContext* context = (AudioContext*)handle;
    if (context->isRunning) return -1;
    context->frameDuration = duration;
    if (context->isDeviceInitialized) {
        ma_device_uninit(&context->device);
        if (context->hasPlaybackDevice) {
            ma_device_uninit(&context->playbackDevice);
            context->hasPlaybackDevice = false;
        }
        context->isDeviceInitialized = false;
    }
    return 0;
}

// Selects the capture source (INPUT_SOURCE_MICROPHONE / _SYSTEM_AUDIO) applied
// when the device is (re)initialised. Must be called before the device starts,
// since the source fixes the device topology. Returns -1 on a bad handle or
// while running, -2 when system audio is unsupported on this backend.
int audio_io_set_input_source(void* handle, int source) {
    if (!handle) return -1;
    AudioContext* context = (AudioContext*)handle;
    if (context->isRunning) return -1;
    if (source != INPUT_SOURCE_SYSTEM_AUDIO) source = INPUT_SOURCE_MICROPHONE;
#if !defined(_WIN32)
    if (source == INPUT_SOURCE_SYSTEM_AUDIO) return -2;
#endif
    if (source == context->inputSource) return 0;
    context->inputSource = source;
    // Topology changed: drop any device built for the previous source so the
    // next start rebuilds it.
    if (context->isDeviceInitialized) {
        ma_device_uninit(&context->device);
        if (context->hasPlaybackDevice) {
            ma_device_uninit(&context->playbackDevice);
            context->hasPlaybackDevice = false;
        }
        context->isDeviceInitialized = false;
    }
    return 0;
}

double audio_io_get_frame_duration(void* handle) {
    if (!handle) return 0.003;
    AudioContext* context = (AudioContext*)handle;
    if (context->isDeviceInitialized && context->isRunning) {
        // In loopback (system-audio) mode context->device is capture-only, so
        // its playback period is 0; read the capture period instead.
        ma_uint32 actualBufferSize = context->hasPlaybackDevice
            ? context->device.capture.internalPeriodSizeInFrames
            : context->device.playback.internalPeriodSizeInFrames;
        if (actualBufferSize > 0) {
            return (double)actualBufferSize / (double)context->device.sampleRate;
        }
    }
    return context->frameDuration;
}

} // extern "C"