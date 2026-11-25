// libhugoc.so - Android 10 -> Android 14 ABI shim for HCT's GOC Bluetooth bridge daemon (gocsdkrf210, 32-bit ARM).
//
// The daemon was built against Android 10's libaudioclient/libmedia. On Android 14 four of its symbols no longer
// exist (AudioTrack/AudioRecord/MediaPlayer constructors with a String16 op-package and a C callback, and
// AudioRecord::getMinFrameCount with an untyped channel mask), so it cannot link (docs/findings.md, attempt 34).
//
// How it is wired (no symbol interposition): hct/goc-shim/rename_syms.py rewrites, in a copy of the binary's
// .dynstr, every reference to android::AudioTrack / android::AudioRecord / android::MediaPlayer into namespace
// "hugoc__" (same length as "android", so the string table is patched in place and the mangling structure is
// unchanged). This library defines exactly those hugoc__ symbols with the Android 10 signatures; each object the
// daemon allocates (with Android 10's sizeof, always larger than a proxy) becomes a small RefBase proxy holding an
// sp<> to a real Android 14 object. libaudioclient's own internal calls are untouched. The service loads it with
// LD_PRELOAD. RefBase::incStrong/decStrong and String16 stay the real android:: symbols.
#include <media/AudioRecord.h>
#include <media/AudioTrack.h>
#include <media/mediaplayer.h>
#include <android/content/AttributionSourceState.h>
#include <utils/RefBase.h>
#include <utils/String16.h>
#include <utils/String8.h>
#include <log/log.h>
#include <unistd.h>
#include <stdlib.h>
#include <new>

#undef LOG_TAG
#define LOG_TAG "hugoc_shim"

using android::sp;
using android::status_t;
using android::content::AttributionSourceState;

namespace hugoc__ {

// Layout-compatible stand-ins for the android:: types that appear inside the renamed mangled names.
struct String16 { const char16_t* mString; };           // android::String16 is one pointer in both releases
struct AudioSystem { enum sync_event_t { SYNC_EVENT_NONE = 0 }; };
typedef void (*callback_t)(int event, void* user, void* info);

// Android 10's Buffer as seen by callbacks (frameCount, size, raw).
struct OldBuffer { size_t frameCount; size_t size; void* raw; uint32_t sequence; };

static AttributionSourceState attribution(const String16* opPackage) {
    AttributionSourceState a;
    a.uid = getuid();
    a.pid = getpid();
    std::string pkg = "gocsdk";
    if (opPackage && opPackage->mString) {
        android::String8 s8(android::String16(opPackage->mString));
        if (s8.length() > 0) pkg = s8.c_str();
    }
    a.packageName = pkg;
    a.token = sp<android::BBinder>::make();
    return a;
}

// ---------------- AudioTrack ----------------
class TrackCb : public android::AudioTrack::IAudioTrackCallback {
  public:
    TrackCb(callback_t cbf, void* user) : mCbf(cbf), mUser(user) {}
    size_t onMoreData(const android::AudioTrack::Buffer& b) override {
        OldBuffer ob{b.getFrameCount(), b.size(), b.data(), 0};
        mCbf(0 /* EVENT_MORE_DATA */, mUser, &ob);
        return ob.size;
    }
    void onUnderrun() override { mCbf(1 /* EVENT_UNDERRUN */, mUser, nullptr); }
  private:
    callback_t mCbf; void* mUser;
};

class AudioTrack : public android::RefBase {
  public:
    enum transfer_type { TRANSFER_DEFAULT, TRANSFER_CALLBACK, TRANSFER_OBTAIN, TRANSFER_SYNC, TRANSFER_SHARED };
    AudioTrack(audio_stream_type_t streamType, uint32_t sampleRate, audio_format_t format, uint32_t channelMask,
               size_t frameCount, audio_output_flags_t flags, callback_t cbf, void* user,
               int32_t notificationFrames, audio_session_t sessionId, transfer_type transferType,
               const audio_offload_info_t* offloadInfo, uid_t uid, pid_t pid, const audio_attributes_t* pAttributes,
               bool doNotReconnect, float maxRequiredSpeed, int selectedDeviceId);
    static status_t getMinFrameCount(size_t* frameCount, audio_stream_type_t streamType, uint32_t sampleRate);
    status_t start();
    void stop();
    void flush();
    ssize_t write(const void* buffer, size_t size, bool blocking);
    status_t setVolume(float left, float right);
    bool stopped() const;
  private:
    sp<android::AudioTrack> mReal;
    sp<TrackCb> mCb;
};

AudioTrack::AudioTrack(audio_stream_type_t streamType, uint32_t sampleRate, audio_format_t format, uint32_t channelMask,
                       size_t frameCount, audio_output_flags_t flags, callback_t cbf, void* user,
                       int32_t notificationFrames, audio_session_t sessionId, transfer_type transferType,
                       const audio_offload_info_t* offloadInfo, uid_t, pid_t, const audio_attributes_t* pAttributes,
                       bool doNotReconnect, float maxRequiredSpeed, int selectedDeviceId) {
    if (cbf) mCb = sp<TrackCb>::make(cbf, user);
    mReal = sp<android::AudioTrack>::make(streamType, sampleRate, format, (audio_channel_mask_t)channelMask,
            frameCount, flags, mCb, notificationFrames, sessionId,
            (android::AudioTrack::transfer_type)transferType, offloadInfo, attribution(nullptr), pAttributes,
            doNotReconnect, maxRequiredSpeed, (audio_port_handle_t)selectedDeviceId);
    ALOGI("AudioTrack proxy: rate=%u fmt=%#x mask=%#x frames=%zu cb=%d initCheck=%d", sampleRate, format,
          channelMask, frameCount, cbf != nullptr, mReal->initCheck());
}
status_t AudioTrack::getMinFrameCount(size_t* frameCount, audio_stream_type_t streamType, uint32_t sampleRate) {
    return android::AudioTrack::getMinFrameCount(frameCount, streamType, sampleRate);
}
status_t AudioTrack::start() { return mReal->start(); }
void AudioTrack::stop() { mReal->stop(); }
void AudioTrack::flush() { mReal->flush(); }
ssize_t AudioTrack::write(const void* buffer, size_t size, bool blocking) { return mReal->write(buffer, size, blocking); }
status_t AudioTrack::setVolume(float l, float r) { return mReal->setVolume(l, r); }
bool AudioTrack::stopped() const { return mReal->stopped(); }

// ---------------- AudioRecord ----------------
class RecordCb : public android::AudioRecord::IAudioRecordCallback {
  public:
    RecordCb(callback_t cbf, void* user) : mCbf(cbf), mUser(user) {}
    size_t onMoreData(const android::AudioRecord::Buffer& b) override {
        OldBuffer ob{b.getFrameCount(), b.size(), b.data(), 0};
        mCbf(0 /* EVENT_MORE_DATA */, mUser, &ob);
        return ob.size;
    }
    void onOverrun() override { mCbf(1 /* EVENT_OVERRUN */, mUser, nullptr); }
  private:
    callback_t mCbf; void* mUser;
};

class AudioRecord : public android::RefBase {
  public:
    enum transfer_type { TRANSFER_DEFAULT, TRANSFER_CALLBACK, TRANSFER_OBTAIN, TRANSFER_SYNC };
    AudioRecord(audio_source_t inputSource, uint32_t sampleRate, audio_format_t format, uint32_t channelMask,
                const String16& opPackageName, size_t frameCount, callback_t cbf, void* user,
                uint32_t notificationFrames, audio_session_t sessionId, transfer_type transferType,
                audio_input_flags_t flags, uid_t uid, pid_t pid, const audio_attributes_t* pAttributes,
                int selectedDeviceId, audio_microphone_direction_t selectedMicDirection,
                float selectedMicFieldDimension);
    static status_t getMinFrameCount(size_t* frameCount, uint32_t sampleRate, audio_format_t format,
                                     uint32_t channelMask);
    status_t start(AudioSystem::sync_event_t event, audio_session_t triggerSession);
    void stop();
    ssize_t read(void* buffer, size_t size, bool blocking);
    bool stopped() const;
  private:
    sp<android::AudioRecord> mReal;
    sp<RecordCb> mCb;
};

AudioRecord::AudioRecord(audio_source_t inputSource, uint32_t sampleRate, audio_format_t format, uint32_t channelMask,
                         const String16& opPackageName, size_t frameCount, callback_t cbf, void* user,
                         uint32_t notificationFrames, audio_session_t sessionId, transfer_type transferType,
                         audio_input_flags_t flags, uid_t, pid_t, const audio_attributes_t* pAttributes,
                         int selectedDeviceId, audio_microphone_direction_t selectedMicDirection,
                         float selectedMicFieldDimension) {
    if (cbf) mCb = sp<RecordCb>::make(cbf, user);
    mReal = sp<android::AudioRecord>::make(inputSource, sampleRate, format, (audio_channel_mask_t)channelMask,
            attribution(&opPackageName), frameCount, mCb, notificationFrames, sessionId,
            (android::AudioRecord::transfer_type)transferType, flags, pAttributes,
            (audio_port_handle_t)selectedDeviceId, selectedMicDirection, selectedMicFieldDimension);
    ALOGI("AudioRecord proxy: src=%d rate=%u fmt=%#x mask=%#x frames=%zu cb=%d initCheck=%d", inputSource,
          sampleRate, format, channelMask, frameCount, cbf != nullptr, mReal->initCheck());
}
status_t AudioRecord::getMinFrameCount(size_t* frameCount, uint32_t sampleRate, audio_format_t format,
                                       uint32_t channelMask) {
    return android::AudioRecord::getMinFrameCount(frameCount, sampleRate, format, (audio_channel_mask_t)channelMask);
}
status_t AudioRecord::start(AudioSystem::sync_event_t event, audio_session_t triggerSession) {
    return mReal->start((android::AudioSystem::sync_event_t)event, triggerSession);
}
void AudioRecord::stop() { mReal->stop(); }
ssize_t AudioRecord::read(void* buffer, size_t size, bool blocking) { return mReal->read(buffer, size, blocking); }
bool AudioRecord::stopped() const { return mReal->stopped(); }

// ---------------- MediaPlayer ----------------
class MediaPlayer : public android::RefBase {
  public:
    MediaPlayer();
    status_t setDataSource(int fd, int64_t offset, int64_t length);
    status_t setAudioStreamType(audio_stream_type_t type);
    status_t setLooping(int loop);
    status_t prepare();
    status_t start();
    status_t stop();
    status_t reset();
    status_t setVolume(float l, float r);
  private:
    sp<android::MediaPlayer> mReal;
};

MediaPlayer::MediaPlayer() {
    mReal = sp<android::MediaPlayer>::make(attribution(nullptr), AUDIO_SESSION_ALLOCATE);
    ALOGI("MediaPlayer proxy created");
}
status_t MediaPlayer::setDataSource(int fd, int64_t offset, int64_t length) { return mReal->setDataSource(fd, offset, length); }
status_t MediaPlayer::setAudioStreamType(audio_stream_type_t type) { return mReal->setAudioStreamType(type); }
status_t MediaPlayer::setLooping(int loop) { return mReal->setLooping(loop); }
status_t MediaPlayer::prepare() { return mReal->prepare(); }
status_t MediaPlayer::start() { return mReal->start(); }
status_t MediaPlayer::stop() { return mReal->stop(); }
status_t MediaPlayer::reset() { return mReal->reset(); }
status_t MediaPlayer::setVolume(float l, float r) { return mReal->setVolume(l, r); }

}  // namespace hugoc__

// libGbtsTask.so (HCT, built with an older NDK) references the ARM EHABI helper __cxa_type_match, which Android 14's
// 32-bit runtime no longer exports; bionic binds every symbol at load time, so the daemon would still fail to start.
// The unwinder only calls it while matching a thrown C++ exception against a catch clause. This stub answers
// "no match" (ctm_failed = 0) and logs, so an exception propagates instead of being swallowed.
extern "C" __attribute__((visibility("default"))) int __cxa_type_match(void* /*ucbp*/, const void* /*type_info*/,
                                                                       bool /*is_ref*/, void** /*matched*/) {
    ALOGW("__cxa_type_match called (stub): treating as no match");
    return 0;
}

// The daemon runs shell commands (system() -> /system/bin/sh, 64-bit); with LD_PRELOAD inherited they fail with
// "libhugoc.so is 32-bit instead of 64-bit". Once this library is loaded the variable has done its job, so clear it
// from the process environment before main() runs; children then start clean.
__attribute__((constructor)) static void hugoc_clear_preload() {
    unsetenv("LD_PRELOAD");
}
