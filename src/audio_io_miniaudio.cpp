#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <cstring>
#include <cstdlib>
#include <mutex>
#include <atomic>
#include <vector>
#include <cmath>

#ifdef __ANDROID__
#include <android/log.h>
#endif

const int CHANNELS = 1;

const int AUDIO_FORMAT_FLOAT64 = 0;
const int AUDIO_FORMAT_PCM16 = 1;

template <typename T>
class RingBuffer {
private:
    std::vector<T> buffer;
    size_t writePos;
    size_t readPos;
    size_t size;
    std::mutex mutex;

public:
    RingBuffer(size_t bufferSize)
        : buffer(bufferSize), writePos(0), readPos(0), size(bufferSize) {}

    size_t write(const T* data, size_t count) {
        std::lock_guard<std::mutex> lock(mutex);
        size_t written = 0;
        for (size_t i = 0; i < count && available_write() > 0; i++) {
            buffer[writePos] = data[i];
            writePos = (writePos + 1) % size;
            written++;
        }
        return written;
    }

    size_t read(T* data, size_t count) {
        std::lock_guard<std::mutex> lock(mutex);
        size_t readCount = 0;
        for (size_t i = 0; i < count && available_read() > 0; i++) {
            data[i] = buffer[readPos];
            readPos = (readPos + 1) % size;
            readCount++;
        }
        return readCount;
    }

    size_t available_read() const {
        if (writePos >= readPos) {
            return writePos - readPos;
        }
        return size - readPos + writePos;
    }

    size_t available_write() const {
        return size - available_read() - 1;
    }
};

using DoubleRingBuffer = RingBuffer<double>;
using Int16RingBuffer = RingBuffer<int16_t>;

static size_t ringBufferSizeForRate(int sampleRate) {
    size_t size = (size_t)(sampleRate * 0.2);
    if (size < 8192) size = 8192;
    return size;
}

struct AudioContext {
    ma_device device;
    DoubleRingBuffer* inputRingBuffer;
    DoubleRingBuffer* outputRingBuffer;
    Int16RingBuffer* inputRingBufferPcm16;
    Int16RingBuffer* outputRingBufferPcm16;
    std::atomic<bool> isRunning;
    std::atomic<bool> isDeviceInitialized;
    double frameDuration;
    int sampleRate;
    int format;

    AudioContext(int rate, int fmt)
        : inputRingBuffer(nullptr),
          outputRingBuffer(nullptr),
          inputRingBufferPcm16(nullptr),
          outputRingBufferPcm16(nullptr),
          isRunning(false),
          isDeviceInitialized(false),
          frameDuration(0.003),
          sampleRate(rate),
          format(fmt) {
        size_t bufSize = ringBufferSizeForRate(rate);
        if (fmt == AUDIO_FORMAT_PCM16) {
            inputRingBufferPcm16 = new Int16RingBuffer(bufSize);
            outputRingBufferPcm16 = new Int16RingBuffer(bufSize);
        } else {
            inputRingBuffer = new DoubleRingBuffer(bufSize);
            outputRingBuffer = new DoubleRingBuffer(bufSize);
        }
    }

    ~AudioContext() {
        delete inputRingBuffer;
        delete outputRingBuffer;
        delete inputRingBufferPcm16;
        delete outputRingBufferPcm16;
    }
};

void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    AudioContext* context = (AudioContext*)pDevice->pUserData;

    if (context->format == AUDIO_FORMAT_PCM16) {
        if (pInput) {
            float* floatInput = (float*)pInput;
            std::vector<int16_t> tempBuffer(frameCount);
            for (ma_uint32 i = 0; i < frameCount; i++) {
                float clamped = fminf(fmaxf(floatInput[i], -1.0f), 1.0f);
                tempBuffer[i] = (int16_t)(clamped * 32767.0f);
            }
            context->inputRingBufferPcm16->write(tempBuffer.data(), frameCount);
        }
        if (pOutput) {
            float* floatOutput = (float*)pOutput;
            std::vector<int16_t> tempBuffer(frameCount);
            size_t framesRead = context->outputRingBufferPcm16->read(tempBuffer.data(), frameCount);
            for (ma_uint32 i = 0; i < frameCount; i++) {
                floatOutput[i] = (i < framesRead) ? (float)tempBuffer[i] / 32767.0f : 0.0f;
            }
        }
    } else {
        if (pInput) {
            float* floatInput = (float*)pInput;
            std::vector<double> tempBuffer(frameCount);
            for (ma_uint32 i = 0; i < frameCount; i++) {
                tempBuffer[i] = (double)floatInput[i];
            }
            context->inputRingBuffer->write(tempBuffer.data(), frameCount);
        }
        if (pOutput) {
            float* floatOutput = (float*)pOutput;
            std::vector<double> tempBuffer(frameCount);
            size_t framesRead = context->outputRingBuffer->read(tempBuffer.data(), frameCount);
            for (ma_uint32 i = 0; i < frameCount; i++) {
                floatOutput[i] = (i < framesRead) ? (float)tempBuffer[i] : 0.0f;
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
    }
    
    if (context->isDeviceInitialized) {
        ma_device_uninit(&context->device);
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
        context->isDeviceInitialized = false;
    }
    return 0;
}

double audio_io_get_frame_duration(void* handle) {
    if (!handle) return 0.003;
    AudioContext* context = (AudioContext*)handle;
    if (context->isDeviceInitialized && context->isRunning) {
        ma_uint32 actualBufferSize = context->device.playback.internalPeriodSizeInFrames;
        if (actualBufferSize > 0) {
            return (double)actualBufferSize / (double)context->device.sampleRate;
        }
    }
    return context->frameDuration;
}

} // extern "C"