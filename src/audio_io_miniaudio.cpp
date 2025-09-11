#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <cstring>
#include <cstdlib>
#include <mutex>
#include <atomic>
#include <vector>



const int RING_BUFFER_SIZE = 8192;
const int SAMPLE_RATE = 48000;
const int CHANNELS = 1;

// Simple ring buffer implementation for doubles
class DoubleRingBuffer {
private:
    std::vector<double> buffer;
    size_t writePos;
    size_t readPos;
    size_t size;
    std::mutex mutex;
    
public:
    DoubleRingBuffer(size_t bufferSize) 
        : buffer(bufferSize), writePos(0), readPos(0), size(bufferSize) {}
    
    size_t write(const double* data, size_t count) {
        std::lock_guard<std::mutex> lock(mutex);
        size_t written = 0;
        for (size_t i = 0; i < count && available_write() > 0; i++) {
            buffer[writePos] = data[i];
            writePos = (writePos + 1) % size;
            written++;
        }
        return written;
    }
    
    size_t read(double* data, size_t count) {
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

struct AudioContext {
    ma_device device;
    DoubleRingBuffer* inputRingBuffer;
    DoubleRingBuffer* outputRingBuffer;
    std::atomic<bool> isRunning;
    
    AudioContext() 
        : inputRingBuffer(new DoubleRingBuffer(RING_BUFFER_SIZE)),
          outputRingBuffer(new DoubleRingBuffer(RING_BUFFER_SIZE)),
          isRunning(false) {}
    
    ~AudioContext() {
        delete inputRingBuffer;
        delete outputRingBuffer;
    }
};

void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    AudioContext* context = (AudioContext*)pDevice->pUserData;
    
    // Handle input
    if (pInput) {
        float* floatInput = (float*)pInput;
        std::vector<double> tempBuffer(frameCount);
        for (ma_uint32 i = 0; i < frameCount; i++) {
            tempBuffer[i] = (double)floatInput[i];
        }
        context->inputRingBuffer->write(tempBuffer.data(), frameCount);
    }
    
    // Handle output
    if (pOutput) {
        float* floatOutput = (float*)pOutput;
        std::vector<double> tempBuffer(frameCount);
        size_t framesRead = context->outputRingBuffer->read(tempBuffer.data(), frameCount);
        
        for (ma_uint32 i = 0; i < frameCount; i++) {
            floatOutput[i] = (i < framesRead) ? (float)tempBuffer[i] : 0.0f;
        }

    }
}

extern "C" {

void* audio_io_create() {

    AudioContext* context = new AudioContext();
    
    ma_device_config config = ma_device_config_init(ma_device_type_duplex);
    config.capture.pDeviceID = NULL;
    config.capture.format = ma_format_f32;
    config.capture.channels = CHANNELS;
    config.capture.shareMode = ma_share_mode_shared;
    config.playback.pDeviceID = NULL;
    config.playback.format = ma_format_f32;
    config.playback.channels = CHANNELS;
    config.playback.shareMode = ma_share_mode_shared;
    config.sampleRate = SAMPLE_RATE;
    config.dataCallback = data_callback;
    config.pUserData = context;
    
    #ifdef __ANDROID__
    config.performanceProfile = ma_performance_profile_low_latency;
    config.aaudio.usage = ma_aaudio_usage_media;
    config.aaudio.contentType = ma_aaudio_content_type_music;
    #endif
    
    if (ma_device_init(NULL, &config, &context->device) != MA_SUCCESS) {

        delete context;
        return NULL;
    }

    return context;
}

void audio_io_destroy(void* handle) {
    if (!handle) return;
    
    AudioContext* context = (AudioContext*)handle;
    
    if (context->isRunning) {
        ma_device_stop(&context->device);
    }
    
    ma_device_uninit(&context->device);
    delete context;
}

int audio_io_start(void* handle) {
    if (!handle) return -1;
    
    AudioContext* context = (AudioContext*)handle;
    
    if (context->isRunning) return 0;
    

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

int audio_io_get_sample_rate(void* handle) {
    if (!handle) return 0;
    
    AudioContext* context = (AudioContext*)handle;
    return context->device.sampleRate;
}

int audio_io_get_channels(void* handle) {
    return CHANNELS;
}

int audio_io_get_available_read_frames(void* handle) {
    if (!handle) return 0;
    
    AudioContext* context = (AudioContext*)handle;
    return context->inputRingBuffer->available_read();
}

int audio_io_get_available_write_space(void* handle) {
    if (!handle) return 0;
    
    AudioContext* context = (AudioContext*)handle;
    return context->outputRingBuffer->available_write();
}

} // extern "C"