// SPDX-License-Identifier: MIT
#pragma once
#include "esp_err.h"
#include <cstddef>
#include <cstdint>
namespace aim {
enum class Link:uint8_t { Usb,Ble };
using Receive=bool(*)(Link,const uint8_t*,size_t);
esp_err_t ble_begin(Receive);
void ble_enable(bool);
esp_err_t ble_stop_for_sleep();
bool ble_forget();
int ble_forget_status();
bool ble_initialized();
void ble_pair_tick();
bool ble_connected();
bool ble_ready();
bool ble_report(uint8_t id,const uint8_t*,size_t);
void ble_battery(uint8_t);
unsigned ble_bonds();
int ble_security_status();
int ble_disconnect_reason();
bool ble_advertising();
int ble_advertise_status();
esp_err_t bonds_begin();
}

namespace aim { void ble_pair(); bool ble_cancel_pairing(); bool ble_pairing(); uint32_t ble_generation(); }

namespace aim {
struct BleDiagnostics {
    bool enabled, advertising, encrypted, keyboard_notify, vendor_notify;
    uint32_t adv_starts, connects, disconnects, encryptions, subscriptions, repeats;
    int adv_status, connect_status, security_start_status, mtu_start_status, mtu;
};
BleDiagnostics ble_diagnostics();
uint32_t ble_directed_starts();
}

namespace aim {
struct BleTrace {uint32_t sequence, ms; const char *event; int a,b,c;};
void ble_trace(const char *event,int a=0,int b=0,int c=0);
bool ble_trace_after(uint32_t sequence,BleTrace &entry);
uint32_t ble_trace_drops();
}

namespace aim {
bool ble_management_ready();
uint32_t ble_management_generation();
size_t ble_management_read(uint8_t *data,size_t capacity);
size_t ble_management_write(const uint8_t *data,size_t length);
}
