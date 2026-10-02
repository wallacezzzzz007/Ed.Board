#pragma once
#include "vendor/protocol.hpp"
#include "esp_err.h"
#include "configuration.hpp"
#include "inputs.hpp"
void note_light_input(const InputEvent &event,int64_t now_ms);
void start_lights();
esp_err_t render_lights(const aim::Lights &lights, int64_t now_ms, bool connected, const board::Configuration &config, bool pairing = false, bool sleeping = false);

// Latch all LEDs off and retain digital output levels across deep sleep.
esp_err_t prepare_lights_for_sleep();
