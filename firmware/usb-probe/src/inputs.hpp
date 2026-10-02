#pragma once
#include <cstdint>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
enum class InputKind {Key, Encoder, Stick, QuickStick, Touch, Ready, Fault};
struct InputEvent {InputKind kind; int value; bool down; uint32_t epoch;};
struct InputSnapshot {uint16_t keys; uint16_t preview_pressed; uint32_t preview_left, preview_right, preview_touch; int preview_x, preview_y; int direction; int quick_direction; bool quick_cancelled; bool ready; bool fault; bool touched;
    int fault_reason; int fault_x; int fault_y; uint32_t fault_touch;
    int fault_x_span; int fault_y_span; uint32_t fault_touch_span;
    bool battery_valid; int battery_mv; int battery_percent; bool charging; bool full;};
void set_preview_cancelled(bool value);
void start_inputs();
InputSnapshot input_snapshot();
InputSnapshot take_preview_snapshot();
bool next_input(InputEvent &event);
void clear_inputs();
uint32_t input_drops();
uint32_t usb_epoch();
