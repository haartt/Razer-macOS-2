#pragma once
#include <stdint.h>

/// USB control-transfer channel to a Razer device (endpoint 0).
/// Unlike HID device access, this needs no Input Monitoring permission.
typedef struct RazerUSB RazerUSB;

RazerUSB *razer_usb_open(int vendorID, int productID);
void razer_usb_close(RazerUSB *usb);
/// Sends a 90-byte report (HID SET_REPORT, feature). Returns 0 on success.
int razer_usb_set_report(RazerUSB *usb, const uint8_t *report);
/// Reads a 90-byte report (HID GET_REPORT, feature). Returns 0 on success.
int razer_usb_get_report(RazerUSB *usb, uint8_t *report);
