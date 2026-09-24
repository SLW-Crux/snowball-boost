/*
 * SnowballBoostDriver.c — AudioServerPlugIn implementing two Core Audio devices:
 *
 *   "Snowball Boost Feed" (hidden, 1 output stream)  — SnowballBoost.app writes boosted audio here.
 *   "Snowball Boosted"    (visible, 1 input stream)  — apps read boosted audio from here.
 *
 * Feed's output and Boosted's input are the same signal, moved through an in-process ring buffer
 * indexed by host-timeline sample time. This plug-in never touches the physical Snowball itself —
 * AudioServerPlugIn.h forbids a plug-in from calling the client HAL API, so all physical capture,
 * gain and limiting happens in the companion app (see ARCHITECTURE.md).
 *
 * Written directly from CoreAudio/AudioServerPlugIn.h and AudioHardwareBase.h (macOS 27 SDK).
 * No sample code was used as a source — see ARCHITECTURE.md "Third-party code — none used".
 */

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <os/log.h>

#pragma mark - Constants

// A UUID identifying this plug-in's CFPlugIn factory. Only needs to be locally unique; referenced
// by name (not value) from Info.plist's CFPlugInFactories/CFPlugInTypes.
#define kSnowballBoostFactoryUUIDString "B4A9CF01-2E3D-4C7A-9F21-5B6C7D8E9F00"

enum {
    kObjectID_PlugIn               = kAudioObjectPlugInObject, // must be 1, per AudioServerPlugIn.h
    kObjectID_Device_Feed          = 2,
    kObjectID_Stream_Feed_Output   = 3,
    kObjectID_Device_Boosted       = 4,
    kObjectID_Stream_Boosted_Input = 5,
};

#define kDeviceIndex_Feed    0
#define kDeviceIndex_Boosted 1
#define kNumDevices          2

#define kRingFrames          16384u  // also the ZeroTimeStampPeriod; must be >= 10923 (SDK minimum)
#define kChangeAction_SetSampleRate 1

// kSBBPropertyStreamConfiguration ('slay') is declared in the client-side AudioHardware.h,
// which a plug-in doesn't include (AudioServerPlugIn.h only pulls in AudioHardwareBase.h). The host
// can still query a driver for it directly by selector value, so it's defined locally here. A
// #define (not a `static const`) so it can be used as a switch case label.
#define kSBBPropertyStreamConfiguration 'slay'

// kAudioHardwarePropertyDevices ('dev#') is likewise only in the client-side AudioHardware.h.
// Traced empirically (os_log from inside the real sandboxed remote-driver-service process,
// 2026-09-24): macOS 27's remote plug-in hosting layer queries the PlugIn object itself for this
// selector during activation and treats an unanswered query as fatal ("Device activation failed"),
// even though AudioServerPlugIn.h never documents it. Answered identically to
// kAudioObjectPropertyOwnedObjects on the PlugIn object.
#define kSBBPropertyHardwareDevices 'dev#'

static os_log_t gLog;

#pragma mark - Global state

typedef struct {
    _Atomic(float) samples[kRingFrames];
} RingBuffer;

static RingBuffer gRing;
static _Atomic uint64_t gRingWriteWatermark = 0; // one-past the last sample index Feed has written

// Config state, protected by gStateLock. Not touched from the realtime IO path.
static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static double gSampleRate = 48000.0;
static UInt32 gRunningClientCount[kNumDevices] = {0, 0};
static UInt32 gTotalRunningClients = 0;
static bool gDeviceIsAlive[kNumDevices] = {true, true};

// Clock timeline, read from the realtime path (GetZeroTimeStamp) via atomics only.
static _Atomic uint64_t gAnchorHostTime = 0;
static _Atomic double gAnchorSampleTime = 0.0;
static _Atomic uint64_t gClockSeed = 1;
static mach_timebase_info_data_t gTimebase;

#pragma mark - Static object descriptions

typedef struct {
    AudioObjectID deviceObjectID;
    AudioObjectID streamObjectID;
    CFStringRef uid;
    CFStringRef name;
    bool isInput;   // true = Boosted (1 input stream); false = Feed (1 output stream)
    bool isHidden;
} DeviceDesc;

static DeviceDesc gDevices[kNumDevices];
static bool gDevicesInitialized = false;

static void EnsureDevicesInitialized(void) {
    if (gDevicesInitialized) return;
    gDevices[kDeviceIndex_Feed] = (DeviceDesc){
        .deviceObjectID = kObjectID_Device_Feed,
        .streamObjectID = kObjectID_Stream_Feed_Output,
        .uid = CFSTR("com.snowballboost.feed"),
        .name = CFSTR("Snowball Boost Feed"),
        .isInput = false,
        .isHidden = true,
    };
    gDevices[kDeviceIndex_Boosted] = (DeviceDesc){
        .deviceObjectID = kObjectID_Device_Boosted,
        .streamObjectID = kObjectID_Stream_Boosted_Input,
        .uid = CFSTR("com.snowballboost.boosted"),
        .name = CFSTR("Snowball Boosted"),
        .isInput = true,
        .isHidden = false,
    };
    gDevicesInitialized = true;
}

static int DeviceIndexForDeviceID(AudioObjectID objectID) {
    if (objectID == kObjectID_Device_Feed) return kDeviceIndex_Feed;
    if (objectID == kObjectID_Device_Boosted) return kDeviceIndex_Boosted;
    return -1;
}

static int DeviceIndexForStreamID(AudioObjectID objectID) {
    if (objectID == kObjectID_Stream_Feed_Output) return kDeviceIndex_Feed;
    if (objectID == kObjectID_Stream_Boosted_Input) return kDeviceIndex_Boosted;
    return -1;
}

#pragma mark - Clock helpers (realtime-safe: atomics only, no locks, no allocation)

static double HostTicksToSeconds(uint64_t ticks) {
    return (double)ticks * (double)gTimebase.numer / (double)gTimebase.denom / 1.0e9;
}

static uint64_t SecondsToHostTicks(double seconds) {
    return (uint64_t)llround(seconds * 1.0e9 * (double)gTimebase.denom / (double)gTimebase.numer);
}

// Resets the shared host-time <-> sample-time mapping to "now". Called when IO starts from a fully
// stopped state, and whenever the nominal sample rate changes. Not realtime (called from StartIO /
// PerformDeviceConfigurationChange, neither of which is CA_REALTIME_API).
static void ResetClockAnchor(void) {
    atomic_store_explicit(&gAnchorHostTime, mach_absolute_time(), memory_order_relaxed);
    atomic_store_explicit(&gAnchorSampleTime, 0.0, memory_order_relaxed);
    atomic_fetch_add_explicit(&gClockSeed, 1, memory_order_relaxed);
}

static void ComputeZeroTimeStamp(Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    uint64_t anchorHost = atomic_load_explicit(&gAnchorHostTime, memory_order_relaxed);
    double anchorSample = atomic_load_explicit(&gAnchorSampleTime, memory_order_relaxed);
    double rate = gSampleRate; // read without lock: only changes via config-change, rare, benign tear

    uint64_t now = mach_absolute_time();
    double elapsedSeconds = HostTicksToSeconds(now - anchorHost);
    double currentSampleTime = anchorSample + elapsedSeconds * rate;

    double period = (double)kRingFrames;
    double zeroSampleTime = floor(currentSampleTime / period) * period;
    double secondsToZero = (zeroSampleTime - anchorSample) / rate;
    uint64_t zeroHostTime = anchorHost + SecondsToHostTicks(secondsToZero);

    *outSampleTime = zeroSampleTime;
    *outHostTime = zeroHostTime;
    *outSeed = atomic_load_explicit(&gClockSeed, memory_order_relaxed);
}

#pragma mark - Ring buffer IO (realtime-safe)

static void RingWrite(uint64_t startSample, const float *data, UInt32 frameCount) {
    for (UInt32 i = 0; i < frameCount; i++) {
        uint64_t idx = (startSample + i) % kRingFrames;
        atomic_store_explicit(&gRing.samples[idx], data[i], memory_order_relaxed);
    }
    atomic_store_explicit(&gRingWriteWatermark, startSample + frameCount, memory_order_relaxed);
}

static void RingRead(uint64_t startSample, float *outData, UInt32 frameCount) {
    uint64_t watermark = atomic_load_explicit(&gRingWriteWatermark, memory_order_relaxed);
    for (UInt32 i = 0; i < frameCount; i++) {
        uint64_t sampleIdx = startSample + i;
        bool notYetWritten = sampleIdx >= watermark;
        bool tooStale = (watermark > sampleIdx) && (watermark - sampleIdx > kRingFrames);
        if (notYetWritten || tooStale) {
            outData[i] = 0.0f; // Feed not running / not keeping up: silence, never a stale loop.
        } else {
            uint64_t idx = sampleIdx % kRingFrames;
            outData[i] = atomic_load_explicit(&gRing.samples[idx], memory_order_relaxed);
        }
    }
}

#pragma mark - Forward declarations of the COM-style vtable methods

static HRESULT SnowballBoost_QueryInterface(void *driver, REFIID uuid, LPVOID *outInterface);
static ULONG SnowballBoost_AddRef(void *driver);
static ULONG SnowballBoost_Release(void *driver);
static OSStatus SnowballBoost_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host);
static OSStatus SnowballBoost_CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo *clientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus SnowballBoost_DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID);
static OSStatus SnowballBoost_AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo *clientInfo);
static OSStatus SnowballBoost_RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo *clientInfo);
static OSStatus SnowballBoost_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void *changeInfo);
static OSStatus SnowballBoost_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void *changeInfo);
static Boolean SnowballBoost_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address);
static OSStatus SnowballBoost_IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, Boolean *outIsSettable);
static OSStatus SnowballBoost_GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 *outDataSize);
static OSStatus SnowballBoost_GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 dataSize, UInt32 *outDataSize, void *outData);
static OSStatus SnowballBoost_SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 dataSize, const void *data);
static OSStatus SnowballBoost_StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus SnowballBoost_StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus SnowballBoost_GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus SnowballBoost_WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus SnowballBoost_BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo);
static OSStatus SnowballBoost_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus SnowballBoost_EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo);

#pragma mark - The interface instance (single, static; ref-counted but never deallocated)

static AudioServerPlugInDriverInterface gInterface = {
    .QueryInterface                    = SnowballBoost_QueryInterface,
    .AddRef                            = SnowballBoost_AddRef,
    .Release                           = SnowballBoost_Release,
    .Initialize                        = SnowballBoost_Initialize,
    .CreateDevice                      = SnowballBoost_CreateDevice,
    .DestroyDevice                     = SnowballBoost_DestroyDevice,
    .AddDeviceClient                   = SnowballBoost_AddDeviceClient,
    .RemoveDeviceClient                = SnowballBoost_RemoveDeviceClient,
    .PerformDeviceConfigurationChange  = SnowballBoost_PerformDeviceConfigurationChange,
    .AbortDeviceConfigurationChange    = SnowballBoost_AbortDeviceConfigurationChange,
    .HasProperty                       = SnowballBoost_HasProperty,
    .IsPropertySettable                = SnowballBoost_IsPropertySettable,
    .GetPropertyDataSize               = SnowballBoost_GetPropertyDataSize,
    .GetPropertyData                   = SnowballBoost_GetPropertyData,
    .SetPropertyData                   = SnowballBoost_SetPropertyData,
    .StartIO                           = SnowballBoost_StartIO,
    .StopIO                            = SnowballBoost_StopIO,
    .GetZeroTimeStamp                  = SnowballBoost_GetZeroTimeStamp,
    .WillDoIOOperation                 = SnowballBoost_WillDoIOOperation,
    .BeginIOOperation                  = SnowballBoost_BeginIOOperation,
    .DoIOOperation                     = SnowballBoost_DoIOOperation,
    .EndIOOperation                    = SnowballBoost_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;
static _Atomic int32_t gRefCount = 1;

#pragma mark - IUnknown

static HRESULT SnowballBoost_QueryInterface(void *driver, REFIID uuid, LPVOID *outInterface) {
    (void)driver;
    if (!outInterface) return E_POINTER;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    if (!requested) return E_NOINTERFACE;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        SnowballBoost_AddRef(driver);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG SnowballBoost_AddRef(void *driver) {
    (void)driver;
    return (ULONG)atomic_fetch_add_explicit(&gRefCount, 1, memory_order_relaxed) + 1;
}

static ULONG SnowballBoost_Release(void *driver) {
    (void)driver;
    int32_t newCount = atomic_fetch_sub_explicit(&gRefCount, 1, memory_order_relaxed) - 1;
    return (ULONG)(newCount < 0 ? 0 : newCount);
}

#pragma mark - Basic operations

static OSStatus SnowballBoost_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    (void)driver;
    EnsureDevicesInitialized();
    mach_timebase_info(&gTimebase);
    gLog = os_log_create("com.snowballboost.driver", "SnowballBoostDriver");

    pthread_mutex_lock(&gStateLock);
    gHost = host;
    gSampleRate = 48000.0;
    ResetClockAnchor();
    pthread_mutex_unlock(&gStateLock);

    os_log(gLog, "Initialize: SnowballBoost driver loaded");
    return kAudioHardwareNoError;
}

// Both devices are statically declared and published at Initialize time (via HasProperty /
// GetPropertyData responding for their fixed object IDs); CreateDevice/DestroyDevice are only
// relevant to plug-ins that create devices dynamically at a client's request, which this driver
// does not do.
static OSStatus SnowballBoost_CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo *clientInfo, AudioObjectID *outDeviceObjectID) {
    (void)driver; (void)description; (void)clientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SnowballBoost_DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID) {
    (void)driver; (void)deviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SnowballBoost_AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo *clientInfo) {
    (void)driver; (void)deviceObjectID; (void)clientInfo;
    return kAudioHardwareNoError;
}

static OSStatus SnowballBoost_RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo *clientInfo) {
    (void)driver; (void)deviceObjectID; (void)clientInfo;
    return kAudioHardwareNoError;
}

typedef struct {
    double newSampleRate;
} SampleRateChangeInfo;

static OSStatus SnowballBoost_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void *changeInfo) {
    (void)driver; (void)deviceObjectID;
    if (changeAction != kChangeAction_SetSampleRate || !changeInfo) return kAudioHardwareIllegalOperationError;

    SampleRateChangeInfo *info = (SampleRateChangeInfo *)changeInfo;

    pthread_mutex_lock(&gStateLock);
    gSampleRate = info->newSampleRate;
    ResetClockAnchor();
    AudioServerPlugInHostRef host = gHost;
    pthread_mutex_unlock(&gStateLock);

    free(info);

    if (host) {
        AudioObjectPropertyAddress address = {
            .mSelector = kAudioDevicePropertyNominalSampleRate,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain,
        };
        host->PropertiesChanged(host, kObjectID_Device_Feed, 1, &address);
        host->PropertiesChanged(host, kObjectID_Device_Boosted, 1, &address);
    }
    return kAudioHardwareNoError;
}

static OSStatus SnowballBoost_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void *changeInfo) {
    (void)driver; (void)deviceObjectID; (void)changeAction;
    free(changeInfo);
    return kAudioHardwareNoError;
}

#pragma mark - Property helpers shared by GetPropertyData / GetPropertyDataSize

// Returns kAudioHardwareNoError and fills *outSize/writes into outData (if non-NULL and it fits)
// for a property common to any AudioObject (Class/BaseClass/Owner/OwnedObjects/Name/Manufacturer).
// Returns kAudioHardwareUnknownPropertyError if the selector isn't one of these.

static OSStatus PlugIn_CopyProperty(const AudioObjectPropertyAddress *address, UInt32 dataSize, UInt32 *outDataSize, void *outData) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: {
            if (dataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID *)outData = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyClass: {
            if (dataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID *)outData = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyOwner: {
            if (dataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *(AudioObjectID *)outData = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyName: {
            if (dataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = CFSTR("Snowball Boost");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyManufacturer: {
            if (dataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = CFSTR("Snowball Boost");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyOwnedObjects:
        case kSBBPropertyHardwareDevices: {
            AudioObjectID owned[kNumDevices] = { kObjectID_Device_Feed, kObjectID_Device_Boosted };
            UInt32 byteSize = (UInt32)sizeof(owned);
            if (dataSize < byteSize) byteSize = dataSize - (dataSize % sizeof(AudioObjectID));
            memcpy(outData, owned, byteSize);
            *outDataSize = byteSize;
            return kAudioHardwareNoError;
        }
        case kAudioPlugInPropertyResourceBundle: {
            if (dataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus PlugIn_PropertyDataSize(const AudioObjectPropertyAddress *address, UInt32 *outSize) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
            *outSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kSBBPropertyHardwareDevices:
            *outSize = (UInt32)(kNumDevices * sizeof(AudioObjectID));
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static bool DeviceHasStreamInScope(const DeviceDesc *d, AudioObjectPropertyScope scope) {
    if (scope == kAudioObjectPropertyScopeGlobal) return true;
    if (scope == kAudioObjectPropertyScopeOutput) return !d->isInput;
    if (scope == kAudioObjectPropertyScopeInput) return d->isInput;
    return false;
}

static UInt32 StreamConfigDataSize(bool hasStream) {
    return hasStream ? (UInt32)sizeof(AudioBufferList) : (UInt32)offsetof(AudioBufferList, mBuffers);
}

static void FillStreamConfig(AudioBufferList *list, bool hasStream) {
    if (hasStream) {
        list->mNumberBuffers = 1;
        list->mBuffers[0].mNumberChannels = 1;
        list->mBuffers[0].mDataByteSize = 0;
        list->mBuffers[0].mData = NULL;
    } else {
        list->mNumberBuffers = 0;
    }
}

static OSStatus Device_PropertyDataSize(int deviceIndex, const AudioObjectPropertyAddress *address, UInt32 *outSize) {
    const DeviceDesc *d = &gDevices[deviceIndex];
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
            *outSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
        case kAudioObjectPropertyControlList:
            *outSize = 0; // no related devices, no controls (gain/limiter are app-side, not HAL controls)
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outSize = sizeof(AudioObjectID); // exactly one stream per device
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
            *outSize = DeviceHasStreamInScope(d, address->mScope) ? (UInt32)sizeof(AudioObjectID) : 0;
            return kAudioHardwareNoError;
        case kSBBPropertyStreamConfiguration:
            *outSize = StreamConfigDataSize(DeviceHasStreamInScope(d, address->mScope));
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outSize = (UInt32)(2 * sizeof(AudioValueRange));
            return kAudioHardwareNoError;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        default:
            (void)d;
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Device_CopyProperty(int deviceIndex, const AudioObjectPropertyAddress *address, UInt32 dataSize, UInt32 *outDataSize, void *outData) {
    const DeviceDesc *d = &gDevices[deviceIndex];

    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (dataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID *)outData = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            if (dataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID *)outData = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            if (dataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *(AudioObjectID *)outData = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            if (dataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = d->name;
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID:
            if (dataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = d->uid;
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyModelUID:
            if (dataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = CFSTR("com.snowballboost.model");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyClockDomain:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = 0; // not synchronized to any other device's clock domain
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsAlive:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = gDeviceIsAlive[deviceIndex] ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsRunning:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = gRunningClientCount[deviceIndex] > 0 ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            // Feed is an internal plumbing device; only Boosted should ever be selectable/default.
            *(UInt32 *)outData = (deviceIndex == kDeviceIndex_Boosted) ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = 0; // no added latency beyond the 1 ms DSP lookahead (handled in-app)
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyIsHidden:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = d->isHidden ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            if (dataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = CFSTR("Snowball Boost");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            if (dataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *(AudioObjectID *)outData = d->streamObjectID;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams: {
            bool hasStream = DeviceHasStreamInScope(d, address->mScope);
            if (!hasStream) { *outDataSize = 0; return kAudioHardwareNoError; }
            if (dataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *(AudioObjectID *)outData = d->streamObjectID;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kSBBPropertyStreamConfiguration: {
            bool hasStream = DeviceHasStreamInScope(d, address->mScope);
            UInt32 needed = StreamConfigDataSize(hasStream);
            if (dataSize < needed) return kAudioHardwareBadPropertySizeError;
            FillStreamConfig((AudioBufferList *)outData, hasStream);
            *outDataSize = needed;
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyNominalSampleRate: {
            if (dataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateLock);
            *(Float64 *)outData = gSampleRate;
            pthread_mutex_unlock(&gStateLock);
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 needed = (UInt32)(2 * sizeof(AudioValueRange));
            if (dataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
            AudioValueRange ranges[2] = {
                { .mMinimum = 44100.0, .mMaximum = 44100.0 },
                { .mMinimum = 48000.0, .mMaximum = 48000.0 },
            };
            UInt32 toCopy = dataSize < needed ? dataSize - (dataSize % sizeof(AudioValueRange)) : needed;
            memcpy(outData, ranges, toCopy);
            *outDataSize = toCopy;
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyZeroTimeStampPeriod:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = kRingFrames;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static bool Device_PropertyIsSettable(const AudioObjectPropertyAddress *address) {
    return address->mSelector == kAudioDevicePropertyNominalSampleRate;
}

static OSStatus Stream_PropertyDataSize(const AudioObjectPropertyAddress *address, UInt32 *outSize) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
            *outSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
            *outSize = 0; // a stream owns nothing and has no controls of its own
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outSize = (UInt32)(2 * sizeof(AudioStreamRangedDescription));
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static void FillStreamFormat(AudioStreamBasicDescription *fmt, double sampleRate) {
    fmt->mSampleRate = sampleRate;
    fmt->mFormatID = kAudioFormatLinearPCM;
    fmt->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    fmt->mBytesPerPacket = 4;
    fmt->mFramesPerPacket = 1;
    fmt->mBytesPerFrame = 4;
    fmt->mChannelsPerFrame = 1;
    fmt->mBitsPerChannel = 32;
    fmt->mReserved = 0;
}

static OSStatus Stream_CopyProperty(int deviceIndex, const AudioObjectPropertyAddress *address, UInt32 dataSize, UInt32 *outDataSize, void *outData) {
    const DeviceDesc *d = &gDevices[deviceIndex];

    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (dataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID *)outData = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            if (dataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID *)outData = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            if (dataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *(AudioObjectID *)outData = d->deviceObjectID;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            if (dataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = d->name;
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            if (dataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = CFSTR("Snowball Boost");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyDirection:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = d->isInput ? 1 : 0; // 0 = output, 1 = input
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyTerminalType:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = d->isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyStartingChannel:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyLatency:
            if (dataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *(UInt32 *)outData = 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (dataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateLock);
            double rate = gSampleRate;
            pthread_mutex_unlock(&gStateLock);
            FillStreamFormat((AudioStreamBasicDescription *)outData, rate);
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 needed = (UInt32)(2 * sizeof(AudioStreamRangedDescription));
            if (dataSize < sizeof(AudioStreamRangedDescription)) return kAudioHardwareBadPropertySizeError;
            AudioStreamRangedDescription ranges[2];
            FillStreamFormat(&ranges[0].mFormat, 44100.0);
            ranges[0].mSampleRateRange = (AudioValueRange){ 44100.0, 44100.0 };
            FillStreamFormat(&ranges[1].mFormat, 48000.0);
            ranges[1].mSampleRateRange = (AudioValueRange){ 48000.0, 48000.0 };
            UInt32 toCopy = dataSize < needed ? dataSize - (dataSize % sizeof(AudioStreamRangedDescription)) : needed;
            memcpy(outData, ranges, toCopy);
            *outDataSize = toCopy;
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Property dispatch (HasProperty / IsPropertySettable / GetPropertyDataSize / GetPropertyData / SetPropertyData)

static Boolean SnowballBoost_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address) {
    (void)driver; (void)clientProcessID;
    if (!address) return false;
    UInt32 dummy = 0;
    OSStatus status;
    if (objectID == kObjectID_PlugIn) {
        status = PlugIn_PropertyDataSize(address, &dummy);
    } else if (DeviceIndexForDeviceID(objectID) >= 0) {
        status = Device_PropertyDataSize(DeviceIndexForDeviceID(objectID), address, &dummy);
    } else if (DeviceIndexForStreamID(objectID) >= 0) {
        status = Stream_PropertyDataSize(address, &dummy);
    } else {
        return false;
    }
    return status == kAudioHardwareNoError;
}

static OSStatus SnowballBoost_IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, Boolean *outIsSettable) {
    (void)driver; (void)clientProcessID;
    if (!address || !outIsSettable) return kAudioHardwareIllegalOperationError;

    if (objectID == kObjectID_PlugIn) {
        UInt32 dummy;
        *outIsSettable = false;
        return PlugIn_PropertyDataSize(address, &dummy);
    }
    int deviceIndex = DeviceIndexForDeviceID(objectID);
    if (deviceIndex >= 0) {
        UInt32 dummy;
        OSStatus status = Device_PropertyDataSize(deviceIndex, address, &dummy);
        if (status != kAudioHardwareNoError) return status;
        *outIsSettable = Device_PropertyIsSettable(address);
        return kAudioHardwareNoError;
    }
    if (DeviceIndexForStreamID(objectID) >= 0) {
        UInt32 dummy;
        *outIsSettable = false;
        return Stream_PropertyDataSize(address, &dummy);
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus SnowballBoost_GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 *outDataSize) {
    (void)driver; (void)clientProcessID; (void)qualifierDataSize; (void)qualifierData;
    if (!address || !outDataSize) return kAudioHardwareIllegalOperationError;

    if (objectID == kObjectID_PlugIn) return PlugIn_PropertyDataSize(address, outDataSize);
    int deviceIndex = DeviceIndexForDeviceID(objectID);
    if (deviceIndex >= 0) return Device_PropertyDataSize(deviceIndex, address, outDataSize);
    if (DeviceIndexForStreamID(objectID) >= 0) return Stream_PropertyDataSize(address, outDataSize);
    return kAudioHardwareBadObjectError;
}

static OSStatus SnowballBoost_GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 dataSize, UInt32 *outDataSize, void *outData) {
    (void)driver; (void)clientProcessID; (void)qualifierDataSize; (void)qualifierData;
    if (!address || !outDataSize || !outData) return kAudioHardwareIllegalOperationError;

    if (objectID == kObjectID_PlugIn) return PlugIn_CopyProperty(address, dataSize, outDataSize, outData);
    int deviceIndex = DeviceIndexForDeviceID(objectID);
    if (deviceIndex >= 0) return Device_CopyProperty(deviceIndex, address, dataSize, outDataSize, outData);
    int streamDeviceIndex = DeviceIndexForStreamID(objectID);
    if (streamDeviceIndex >= 0) return Stream_CopyProperty(streamDeviceIndex, address, dataSize, outDataSize, outData);
    return kAudioHardwareBadObjectError;
}

static OSStatus SnowballBoost_SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 dataSize, const void *data) {
    (void)driver; (void)clientProcessID; (void)qualifierDataSize; (void)qualifierData;
    if (!address || !data) return kAudioHardwareIllegalOperationError;

    int deviceIndex = DeviceIndexForDeviceID(objectID);
    if (deviceIndex < 0) return kAudioHardwareUnsupportedOperationError;
    if (address->mSelector != kAudioDevicePropertyNominalSampleRate) return kAudioHardwareUnsupportedOperationError;
    if (dataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;

    double requested = *(const Float64 *)data;
    if (requested != 44100.0 && requested != 48000.0) return kAudioHardwareIllegalOperationError;

    pthread_mutex_lock(&gStateLock);
    AudioServerPlugInHostRef host = gHost;
    double current = gSampleRate;
    pthread_mutex_unlock(&gStateLock);

    if (requested == current) return kAudioHardwareNoError;
    if (!host) return kAudioHardwareNotRunningError;

    SampleRateChangeInfo *info = (SampleRateChangeInfo *)malloc(sizeof(SampleRateChangeInfo));
    if (!info) return kAudioHardwareUnspecifiedError;
    info->newSampleRate = requested;

    OSStatus status = host->RequestDeviceConfigurationChange(host, objectID, kChangeAction_SetSampleRate, info);
    if (status != kAudioHardwareNoError) free(info);
    return status;
}

#pragma mark - IO operations

static OSStatus SnowballBoost_StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    (void)driver; (void)clientID;
    int deviceIndex = DeviceIndexForDeviceID(deviceObjectID);
    if (deviceIndex < 0) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateLock);
    if (gTotalRunningClients == 0) {
        ResetClockAnchor();
        atomic_store_explicit(&gRingWriteWatermark, 0, memory_order_relaxed);
    }
    gRunningClientCount[deviceIndex]++;
    gTotalRunningClients++;
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus SnowballBoost_StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    (void)driver; (void)clientID;
    int deviceIndex = DeviceIndexForDeviceID(deviceObjectID);
    if (deviceIndex < 0) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateLock);
    if (gRunningClientCount[deviceIndex] > 0) {
        gRunningClientCount[deviceIndex]--;
        gTotalRunningClients--;
    }
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus SnowballBoost_GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)driver; (void)clientID;
    if (DeviceIndexForDeviceID(deviceObjectID) < 0) return kAudioHardwareBadObjectError;
    ComputeZeroTimeStamp(outSampleTime, outHostTime, outSeed);
    return kAudioHardwareNoError;
}

static OSStatus SnowballBoost_WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)driver; (void)clientID;
    int deviceIndex = DeviceIndexForDeviceID(deviceObjectID);
    if (deviceIndex < 0) return kAudioHardwareBadObjectError;

    bool willDo = false;
    if (deviceIndex == kDeviceIndex_Feed && operationID == kAudioServerPlugInIOOperationWriteMix) willDo = true;
    if (deviceIndex == kDeviceIndex_Boosted && operationID == kAudioServerPlugInIOOperationReadInput) willDo = true;

    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus SnowballBoost_BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo) {
    (void)driver; (void)deviceObjectID; (void)clientID; (void)operationID; (void)ioBufferFrameSize; (void)ioCycleInfo;
    return kAudioHardwareNoError;
}

static OSStatus SnowballBoost_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)driver; (void)streamObjectID; (void)clientID; (void)ioSecondaryBuffer;
    int deviceIndex = DeviceIndexForDeviceID(deviceObjectID);
    if (deviceIndex < 0 || !ioCycleInfo || !ioMainBuffer) return kAudioHardwareBadObjectError;

    if (deviceIndex == kDeviceIndex_Feed && operationID == kAudioServerPlugInIOOperationWriteMix) {
        uint64_t startSample = (uint64_t)llround(ioCycleInfo->mOutputTime.mSampleTime);
        RingWrite(startSample, (const float *)ioMainBuffer, ioBufferFrameSize);
        return kAudioHardwareNoError;
    }
    if (deviceIndex == kDeviceIndex_Boosted && operationID == kAudioServerPlugInIOOperationReadInput) {
        uint64_t startSample = (uint64_t)llround(ioCycleInfo->mInputTime.mSampleTime);
        RingRead(startSample, (float *)ioMainBuffer, ioBufferFrameSize);
        return kAudioHardwareNoError;
    }
    return kAudioHardwareNoError;
}

static OSStatus SnowballBoost_EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo) {
    (void)driver; (void)deviceObjectID; (void)clientID; (void)operationID; (void)ioBufferFrameSize; (void)ioCycleInfo;
    return kAudioHardwareNoError;
}

#pragma mark - CFPlugIn factory

void *SnowballBoostDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);

__attribute__((visibility("default")))
void *SnowballBoostDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    EnsureDevicesInitialized();
    return gDriverRef;
}
