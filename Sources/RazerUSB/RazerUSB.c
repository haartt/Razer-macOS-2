#include "RazerUSB.h"
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

struct RazerUSB {
    IOUSBDeviceInterface **dev;
};

RazerUSB *razer_usb_open(int vendorID, int productID) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vendorID);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &productID);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), p);
    CFRelease(v);
    CFRelease(p);

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match); // consumes match
    if (!service) return NULL;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !plugin) return NULL;

    IOUSBDeviceInterface **dev = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);
    if (!dev) return NULL;

    RazerUSB *usb = malloc(sizeof(RazerUSB));
    usb->dev = dev;
    return usb;
}

void razer_usb_close(RazerUSB *usb) {
    if (!usb) return;
    (*usb->dev)->Release(usb->dev);
    free(usb);
}

// Control request to interface 0: wValue 0x0300 = feature report, ID 0.
static int request(RazerUSB *usb, uint8_t type, uint8_t req, uint8_t *data) {
    IOUSBDevRequest r = {
        .bmRequestType = type, .bRequest = req, .wValue = 0x0300, .wIndex = 0, .wLength = 90, .pData = data,
    };
    return (*usb->dev)->DeviceRequest(usb->dev, &r);
}

int razer_usb_set_report(RazerUSB *usb, const uint8_t *report) {
    return request(usb, 0x21, 0x09, (uint8_t *)report); // class, interface, host→device; SET_REPORT
}

int razer_usb_get_report(RazerUSB *usb, uint8_t *report) {
    return request(usb, 0xA1, 0x01, report); // class, interface, device→host; GET_REPORT
}
