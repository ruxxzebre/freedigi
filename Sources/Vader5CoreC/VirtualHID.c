#include "VirtualHID.h"
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <mach/mach_time.h>
#include <Security/SecTask.h>

int32_t V5VirtualHIDHasEntitlement(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return -1;
    CFErrorRef error = NULL;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task,
        CFSTR("com.apple.developer.hid.virtual.device"), &error);
    int32_t result = value && CFGetTypeID(value) == CFBooleanGetTypeID()
        && CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
    if (error) { if (!value) result = -1; CFRelease(error); }
    if (value) CFRelease(value);
    CFRelease(task);
    return result;
}

void *V5VirtualHIDCreate(CFDictionaryRef properties) {
    return (void *)IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties, 0);
}

int32_t V5VirtualHIDHandleReport(void *device, const uint8_t *report, size_t length) {
    return IOHIDUserDeviceHandleReportWithTimeStamp(
        (IOHIDUserDeviceRef)device, mach_absolute_time(), report, (CFIndex)length);
}

void V5VirtualHIDRelease(void *device) {
    if (device) CFRelease((CFTypeRef)device);
}
