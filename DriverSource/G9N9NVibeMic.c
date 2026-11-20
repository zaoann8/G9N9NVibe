// G9N9N-Vibe 原生 CoreAudio HAL 用户态虚拟音频驱动（MIT License）
// 特点：
// 1. 纯 C 实现，零动态堆分配，固定 16384 帧环形回环缓冲（约 128 KB）
// 2. 双声道 48kHz 32-bit Float，供 App 写入混合/选通音频、第三方输入法读取录音
// 3. 原生声明 kAudioDeviceTransportTypeUSB，确保豆包输入法等严格校验硬件类型的软件正常识别

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#pragma mark - 常量定义

#define kPlugIn_BundleID            "io.github.g9n9n-vibe.driver"
#define kDevice_Name                "G9N9N-Vibe Mic 2ch"
#define kDevice_Manufacturer        "G9N9N-Vibe"
#define kDevice_UID                 "io.github.g9n9n-vibe.mic2ch.uid"
#define kDevice_ModelUID            "io.github.g9n9n-vibe.mic2ch.model"

// 工厂 UUID，必须与 DriverSource/Info.plist 中的 CFPlugInFactories 完全一致
#define kFactory_UUID_String        "6F3A9E2B-8D41-4C7A-B10E-9A5C7D2E4F81"

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject, // 1
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4
};

#define kSampleRate                 48000.0
#define kChannelCount               2
#define kBitsPerChannel             32
#define kBytesPerFrame              (kChannelCount * sizeof(Float32))
#define kRingBufferFrames           16384u
#define kRingBufferMask             (kRingBufferFrames - 1u)
#define kZeroTimeStampPeriod        kRingBufferFrames

#pragma mark - 全局驱动状态（静态预分配，零实时堆分配）

static pthread_mutex_t              gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32                       gPlugInRefCount = 0;
static AudioServerPlugInHostRef     gPlugInHost = NULL;

static UInt64                       gIOClientCount = 0;
static Float64                      gHostTicksPerFrame = 0.0;
static _Atomic uint64_t             gAnchorHostTime = 0;
static _Atomic uint64_t             gTimeStampSeed = 1;

// 静态预分配的立体声 Float32 环形回环缓冲区与写入新鲜度追踪
static Float32                      gRingBuffer[kRingBufferFrames * kChannelCount];
static _Atomic uint64_t             gLastWrittenSampleEnd = 0;
static _Atomic uint64_t             gLastWriteHostTime = 0;
static uint64_t                     gStaleThresholdHostTicks = 0;

#pragma mark - 辅助函数

static AudioStreamBasicDescription MakeStreamFormat(void) {
    AudioStreamBasicDescription desc;
    memset(&desc, 0, sizeof(desc));
    desc.mSampleRate       = kSampleRate;
    desc.mFormatID         = kAudioFormatLinearPCM;
    desc.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    desc.mBytesPerPacket   = kBytesPerFrame;
    desc.mFramesPerPacket  = 1;
    desc.mBytesPerFrame    = kBytesPerFrame;
    desc.mChannelsPerFrame = kChannelCount;
    desc.mBitsPerChannel   = kBitsPerChannel;
    return desc;
}

static AudioStreamRangedDescription MakeStreamRangedFormat(void) {
    AudioStreamRangedDescription desc;
    desc.mFormat = MakeStreamFormat();
    desc.mSampleRateRange.mMinimum = kSampleRate;
    desc.mSampleRateRange.mMaximum = kSampleRate;
    return desc;
}

static void EnsureTimebaseInitialized(void) {
    if (gHostTicksPerFrame > 0.0) {
        return;
    }
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    Float64 hostClockFrequency = ((Float64)timebase.denom / (Float64)timebase.numer) * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / kSampleRate;
    // 超过 250ms 无写入则判定为静音，防止循环回放旧残留声音
    gStaleThresholdHostTicks = (uint64_t)(hostClockFrequency * 0.25);
}

#pragma mark - 接口前向声明

static HRESULT  Driver_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    Driver_AddRef(void* inDriver);
static ULONG    Driver_Release(void* inDriver);
static OSStatus Driver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Driver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus Driver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Driver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Driver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Driver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus Driver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean  Driver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus Driver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus Driver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus Driver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus Driver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus Driver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Driver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Driver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus Driver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus Driver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus Driver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus Driver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    Driver_QueryInterface,
    Driver_AddRef,
    Driver_Release,
    Driver_Initialize,
    Driver_CreateDevice,
    Driver_DestroyDevice,
    Driver_AddDeviceClient,
    Driver_RemoveDeviceClient,
    Driver_PerformDeviceConfigurationChange,
    Driver_AbortDeviceConfigurationChange,
    Driver_HasProperty,
    Driver_IsPropertySettable,
    Driver_GetPropertyDataSize,
    Driver_GetPropertyData,
    Driver_SetPropertyData,
    Driver_StartIO,
    Driver_StopIO,
    Driver_GetZeroTimeStamp,
    Driver_WillDoIOOperation,
    Driver_BeginIOOperation,
    Driver_DoIOOperation,
    Driver_EndIOOperation
};

static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef        gDriverRef = &gDriverInterfacePtr;

#pragma mark - 插件工厂入口

__attribute__((visibility("default")))
void* G9N9NVibeMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        Driver_AddRef(gDriverRef);
        return gDriverRef;
    }
    return NULL;
}

#pragma mark - IUnknown 生命周期

static HRESULT Driver_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) {
        return kAudioHardwareBadObjectError;
    }
    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requestedUUID == NULL) {
        return E_NOINTERFACE;
    }
    Boolean matched = CFEqual(requestedUUID, IUnknownUUID) ||
                      CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requestedUUID);
    if (matched) {
        Driver_AddRef(inDriver);
        *outInterface = gDriverRef;
        return S_OK;
    }
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG Driver_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    UInt32 count = ++gPlugInRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG Driver_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    UInt32 count = (gPlugInRefCount > 0) ? --gPlugInRefCount : 0;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

#pragma mark - 初始化与客户端管理

static OSStatus Driver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gPlugInHost = inHost;
    EnsureTimebaseInitialized();
    memset(gRingBuffer, 0, sizeof(gRingBuffer));
    atomic_store(&gLastWrittenSampleEnd, 0);
    atomic_store(&gLastWriteHostTime, 0);
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus Driver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Driver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Driver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus Driver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus Driver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

static OSStatus Driver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

#pragma mark - 属性查询：PlugIn

static Boolean PlugIn_HasProperty(const AudioObjectPropertyAddress* inAddress) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static OSStatus PlugIn_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus PlugIn_GetPropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            if (inQualifierDataSize < sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareBadPropertySizeError;
            if (CFEqual(*((CFStringRef*)inQualifierData), CFSTR(kDevice_UID))) {
                *((AudioObjectID*)outData) = kObjectID_Device;
            } else {
                *((AudioObjectID*)outData) = kAudioObjectUnknown;
            }
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioPlugInPropertyResourceBundle:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - 属性查询：Device

static Boolean Device_HasProperty(const AudioObjectPropertyAddress* inAddress) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return true;
        default:
            return false;
    }
}

static OSStatus Device_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                *outDataSize = 2 * sizeof(AudioObjectID);
            } else if (inAddress->mScope == kAudioObjectPropertyScopeInput ||
                       inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return noErr;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return noErr;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange);
            return noErr;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Device_GetPropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyName:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR(kDevice_Name);
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioDevicePropertyDeviceUID:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR(kDevice_UID);
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioDevicePropertyModelUID:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID);
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioDevicePropertyTransportType:
            // 关键：原生声明为 USB 传输类型，使豆包等会过滤 virtual 设备的输入法可见
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = kAudioDeviceTransportTypeUSB;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyRelatedDevices:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioDevicePropertyClockDomain:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyDeviceIsAlive:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyDeviceIsRunning:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            *((UInt32*)outData) = (gIOClientCount > 0) ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            // 仅允许作为系统默认输入设备（麦克风）；Output 通道仅作内部回环写入，绝不允许被系统误选成默认扬声器
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = (inAddress->mScope == kAudioObjectPropertyScopeInput) ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            // 麦克风设备不参与系统提示音默认输出，杜绝拔出耳机时系统声音丢失
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = kZeroTimeStampPeriod;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID* list = (AudioObjectID*)outData;
            if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                UInt32 count = inDataSize / sizeof(AudioObjectID);
                if (count > 2) count = 2;
                if (count >= 1) list[0] = kObjectID_Stream_Input;
                if (count >= 2) list[1] = kObjectID_Stream_Output;
                *outDataSize = count * sizeof(AudioObjectID);
            } else if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                list[0] = kObjectID_Stream_Input;
                *outDataSize = sizeof(AudioObjectID);
            } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                list[0] = kObjectID_Stream_Output;
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return noErr;
        }
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return noErr;
        case kAudioDevicePropertyNominalSampleRate:
            if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            *((Float64*)outData) = kSampleRate;
            *outDataSize = sizeof(Float64);
            return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
            AudioValueRange* range = (AudioValueRange*)outData;
            range->mMinimum = kSampleRate;
            range->mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioValueRange);
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32* channels = (UInt32*)outData;
            channels[0] = 1;
            channels[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 required = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription);
            if (inDataSize < required) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            memset(layout, 0, required);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = kChannelCount;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = required;
            return noErr;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - 属性查询：Stream

static Boolean Stream_HasProperty(const AudioObjectPropertyAddress* inAddress) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static OSStatus Stream_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Stream_GetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    Boolean isInput = (inObjectID == kObjectID_Stream_Input);
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioStreamPropertyIsActive:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyDirection:
            // 1 = 输入流（麦克风），0 = 输出流（供主程序写入）
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = isInput ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyTerminalType:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyStartingChannel:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyLatency:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            *((AudioStreamBasicDescription*)outData) = MakeStreamFormat();
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            if (inDataSize < sizeof(AudioStreamRangedDescription)) return kAudioHardwareBadPropertySizeError;
            *((AudioStreamRangedDescription*)outData) = MakeStreamRangedFormat();
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - 统一属性分发

static Boolean Driver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;
    switch (inObjectID) {
        case kObjectID_PlugIn:
            return PlugIn_HasProperty(inAddress);
        case kObjectID_Device:
            return Device_HasProperty(inAddress);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            return Stream_HasProperty(inAddress);
        default:
            return false;
    }
}

static OSStatus Driver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL || outIsSettable == NULL) return kAudioHardwareBadObjectError;
    if (!Driver_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    *outIsSettable = false;
    return noErr;
}

static OSStatus Driver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef || inAddress == NULL || outDataSize == NULL) return kAudioHardwareBadObjectError;
    switch (inObjectID) {
        case kObjectID_PlugIn:
            return PlugIn_GetPropertyDataSize(inAddress, outDataSize);
        case kObjectID_Device:
            return Device_GetPropertyDataSize(inAddress, outDataSize);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            return Stream_GetPropertyDataSize(inAddress, outDataSize);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus Driver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareBadObjectError;
    switch (inObjectID) {
        case kObjectID_PlugIn:
            return PlugIn_GetPropertyData(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
        case kObjectID_Device:
            return Device_GetPropertyData(inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            return Stream_GetPropertyData(inObjectID, inAddress, inDataSize, outDataSize, outData);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus Driver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    (void)inDriver; (void)inObjectID; (void)inClientProcessID; (void)inAddress;
    (void)inQualifierDataSize; (void)inQualifierData; (void)inDataSize; (void)inData;
    return kAudioHardwareUnsupportedOperationError;
}

#pragma mark - 实时音频 IO 与回环引擎

static OSStatus Driver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    EnsureTimebaseInitialized();
    if (gIOClientCount == 0) {
        atomic_store_explicit(&gAnchorHostTime, mach_absolute_time(), memory_order_release);
        // 每次重启 IO 时钟锚点递增 Seed，严格遵循 CoreAudio HAL 规范防止 coreaudiod 时钟漂移
        atomic_fetch_add_explicit(&gTimeStampSeed, 1, memory_order_acq_rel);
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
        atomic_store(&gLastWrittenSampleEnd, 0);
        atomic_store(&gLastWriteHostTime, 0);
    }
    gIOClientCount++;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus Driver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOClientCount > 0) {
        gIOClientCount--;
    }
    if (gIOClientCount == 0) {
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
        atomic_store(&gLastWrittenSampleEnd, 0);
        atomic_store(&gLastWriteHostTime, 0);
    }
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus Driver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) return kAudioHardwareIllegalOperationError;

    UInt64 anchorHost = atomic_load_explicit(&gAnchorHostTime, memory_order_acquire);
    UInt64 seed = atomic_load_explicit(&gTimeStampSeed, memory_order_acquire);
    UInt64 currentHostTime = mach_absolute_time();
    if (anchorHost == 0) {
        *outSampleTime = 0.0;
        *outHostTime   = currentHostTime;
        *outSeed       = seed;
        return noErr;
    }
    Float64 ticksPerRing = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    UInt64 elapsed = (currentHostTime >= anchorHost) ? (currentHostTime - anchorHost) : 0;
    UInt64 periods = (ticksPerRing > 0.0) ? (UInt64)((Float64)elapsed / ticksPerRing) : 0;

    *outSampleTime = (Float64)(periods * (UInt64)kZeroTimeStampPeriod);
    *outHostTime   = anchorHost + (UInt64)((Float64)periods * ticksPerRing);
    *outSeed       = seed;
    return noErr;
}

static OSStatus Driver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean willDo = false;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            willDo = true;
            break;
        default:
            willDo = false;
            break;
    }
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return noErr;
}

static OSStatus Driver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}

static OSStatus Driver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device || ioMainBuffer == NULL || inIOCycleInfo == NULL) {
        return kAudioHardwareBadObjectError;
    }

    Float32* buffer = (Float32*)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        // 主程序写入混合/选通后的立体声 PCM 到环形缓冲区（限制单次帧数不超过环形容量，杜绝极端客户端越界）
        uint32_t frames = (inIOBufferFrameSize > kRingBufferFrames) ? kRingBufferFrames : inIOBufferFrameSize;
        Float64 rawSampleTime = inIOCycleInfo->mOutputTime.mSampleTime;
        uint64_t startFrame = (isfinite(rawSampleTime) && rawSampleTime >= 0.0) ? (uint64_t)rawSampleTime : 0;
        uint32_t offset = (uint32_t)(startFrame & kRingBufferMask);
        uint32_t firstPart = kRingBufferFrames - offset;
        if (firstPart > frames) firstPart = frames;
        uint32_t secondPart = frames - firstPart;

        memcpy(&gRingBuffer[offset * kChannelCount], buffer, firstPart * kBytesPerFrame);
        if (secondPart > 0) {
            memcpy(&gRingBuffer[0], &buffer[firstPart * kChannelCount], secondPart * kBytesPerFrame);
        }
        atomic_store_explicit(&gLastWrittenSampleEnd, startFrame + frames, memory_order_release);
        atomic_store_explicit(&gLastWriteHostTime, mach_absolute_time(), memory_order_release);
        return noErr;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        // 第三方输入法（豆包/微信等）读取回环音频
        uint64_t lastHost = atomic_load_explicit(&gLastWriteHostTime, memory_order_acquire);
        uint64_t nowHost = mach_absolute_time();
        if (lastHost == 0 || (nowHost > lastHost && (nowHost - lastHost) > gStaleThresholdHostTicks)) {
            memset(buffer, 0, inIOBufferFrameSize * kBytesPerFrame);
            return noErr;
        }

        uint32_t frames = (inIOBufferFrameSize > kRingBufferFrames) ? kRingBufferFrames : inIOBufferFrameSize;
        Float64 rawSampleTime = inIOCycleInfo->mInputTime.mSampleTime;
        uint64_t startFrame = (isfinite(rawSampleTime) && rawSampleTime >= 0.0) ? (uint64_t)rawSampleTime : 0;
        uint32_t offset = (uint32_t)(startFrame & kRingBufferMask);
        uint32_t firstPart = kRingBufferFrames - offset;
        if (firstPart > frames) firstPart = frames;
        uint32_t secondPart = frames - firstPart;

        memcpy(buffer, &gRingBuffer[offset * kChannelCount], firstPart * kBytesPerFrame);
        if (secondPart > 0) {
            memcpy(&buffer[firstPart * kChannelCount], &gRingBuffer[0], secondPart * kBytesPerFrame);
        }
        if (frames < inIOBufferFrameSize) {
            memset(&buffer[frames * kChannelCount], 0, (inIOBufferFrameSize - frames) * kBytesPerFrame);
        }
        return noErr;
    }

    return noErr;
}

static OSStatus Driver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}
