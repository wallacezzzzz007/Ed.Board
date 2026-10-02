// Input scanning and startup calibration for AI Micro Board3.
// Battery conversion adapted from AI Micro Basic (MIT); see vendor/LICENSE.
#include "inputs.hpp"
#include <atomic>
#include "esp_adc/adc_cali_scheme.h"
#include <cinttypes>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include "driver/gpio.h"
#include "driver/touch_sensor.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

namespace {
QueueHandle_t events;
std::atomic<uint32_t> drops{0};
portMUX_TYPE snapshot_lock = portMUX_INITIALIZER_UNLOCKED;
InputSnapshot snapshot{};
adc_cali_handle_t battery_calibration = nullptr;
void publish(InputKind kind, int value, bool down) {
    InputEvent event{kind,value,down,usb_epoch()};
    if(xQueueSend(events,&event,0)!=pdTRUE) ++drops;
}
void fault(int reason, int x, int y, uint32_t touch, int x_span = 0, int y_span = 0, uint32_t touch_span = 0) {
    portENTER_CRITICAL(&snapshot_lock); snapshot.fault=true; snapshot.ready=false;
    snapshot.fault_reason=reason; snapshot.fault_x=x; snapshot.fault_y=y; snapshot.fault_touch=touch;
    snapshot.fault_x_span=x_span; snapshot.fault_y_span=y_span; snapshot.fault_touch_span=touch_span; portEXIT_CRITICAL(&snapshot_lock);
    publish(InputKind::Fault,0,false);
}

constexpr const char *kTag = "inputs";
constexpr gpio_num_t kClock = GPIO_NUM_14, kLoad = GPIO_NUM_21;
constexpr gpio_num_t kEnable = GPIO_NUM_47, kData = GPIO_NUM_48;
constexpr gpio_num_t kA = GPIO_NUM_13, kB = GPIO_NUM_12, kPush = GPIO_NUM_11;
constexpr unsigned kBits[] = {9,15,7,8,11,14,3,4,10,13,6,5,12};
constexpr const char *kNames[] = {"AG00","AG01","AG02","AG03","AG04","AG05",
    "ACT06","ACT07","ACT08","ACT09","ACT10","ACT11","ACT12"};
adc_oneshot_unit_handle_t adc = nullptr;
adc_channel_t x_channel, y_channel;
portMUX_TYPE encoder_lock = portMUX_INITIALIZER_UNLOCKED;
int encoder_state = 0;
int32_t encoder_delta = 0;
int encoder_partial = 0;
uint32_t encoder_invalid = 0;

// ISR counts transitions only: no logging, allocation, or detent assumption.
void encoder_edge(void *) {
    portENTER_CRITICAL_ISR(&encoder_lock);
    const int state = (gpio_get_level(kA) << 1) | gpio_get_level(kB);
    const int previous = encoder_state;
    if ((state ^ previous) == 3) {
        ++encoder_invalid;
        encoder_partial = 0;
    } else if (state != previous) {
        // Positive sequence: 00 -> 01 -> 11 -> 10 -> 00.
        const bool positive = (previous == 0 && state == 1) ||
            (previous == 1 && state == 3) || (previous == 3 && state == 2) ||
            (previous == 2 && state == 0);
        encoder_partial += positive ? 1 : -1;
        if (encoder_partial >= 4) { ++encoder_delta; encoder_partial -= 4; }
        if (encoder_partial <= -4) { --encoder_delta; encoder_partial += 4; }
    }
    encoder_state = state;
    portEXIT_CRITICAL_ISR(&encoder_lock);
}

uint16_t read_panel() {
    gpio_set_level(kEnable, 1);
    gpio_set_level(kClock, 0);
    gpio_set_level(kLoad, 0);
    esp_rom_delay_us(2);
    gpio_set_level(kLoad, 1);
    esp_rom_delay_us(2);
    gpio_set_level(kEnable, 0);
    // Board3 measurement: first serial sample is bit 0 (T1-03).
    uint16_t word = 0;
    for (int i = 0; i < 16; ++i) {
        word |= static_cast<uint16_t>(gpio_get_level(kData) << i);
        gpio_set_level(kClock, 1);
        esp_rom_delay_us(2);
        gpio_set_level(kClock, 0);
        esp_rom_delay_us(2);
    }
    gpio_set_level(kEnable, 1);
    return word;
}

struct Debounce {
    bool candidate = false;
    bool stable = false;
    int64_t since = 0;
    bool update(bool pressed, int64_t now) {
        if (pressed != candidate) { candidate = pressed; since = now; }
        if (candidate != stable && now - since >= 30000) {
            stable = candidate;
            return true;
        }
        return false;
    }
};

void input_task(void *) {
    Debounce keys[14], touched;
    uint32_t sequence = 0;
    int64_t next_battery = 0;
    int64_t next_sample = 0, next_report = 0;
    int samples = 0, sum_x = 0, sum_y = 0;
    uint64_t sum_touch = 0;
    int min_x = 4095, max_x = 0, min_y = 4095, max_y = 0;
    uint32_t min_touch = UINT32_MAX, max_touch = 0;
    int center_x = 0, center_y = 0;
    uint32_t baseline = 0;
    bool calibrated = false;
    int direction = 0, candidate = 0;
    int quick = 0, quick_candidate = 0;
    int64_t quick_since = 0;
    int64_t candidate_since = 0;
    const char *directions[] = {"CENTER", "UP", "RIGHT", "DOWN", "LEFT"};
    ESP_LOGI(kTag, "event=calibration_start keep_controls_released=1 samples=100");
    while (true) {
        const int64_t now = esp_timer_get_time();
        const uint16_t raw = read_panel();
        uint16_t mask = 0;bool changed[14]{};
        for (unsigned i = 0; i < 14; ++i) {
            const bool pressed = i < 13 ? !(raw & (1U << kBits[i])) : !gpio_get_level(kPush);
            changed[i]=keys[i].update(pressed, now);
            if (keys[i].stable) { mask |= 1U << i; }
        }
        // Publish the whole scan state before waking the event consumer.
        portENTER_CRITICAL(&snapshot_lock);
        snapshot.preview_pressed |= mask & ~snapshot.keys; snapshot.keys=mask; snapshot.direction=direction; snapshot.touched=touched.stable;
        portEXIT_CRITICAL(&snapshot_lock);
        for(unsigned i=0;i<14;++i)if(changed[i]){
            publish(InputKind::Key,i,keys[i].stable);
            ESP_LOGI(kTag,"event=key seq=%" PRIu32 " control=%s state=%s raw=0x%04x",
                sequence++,i<13?kNames[i]:"ENC_PUSH",keys[i].stable?"down":"up",static_cast<unsigned>(raw));
        }
        int32_t turns;
        uint32_t invalid;
        portENTER_CRITICAL(&encoder_lock);
        turns = encoder_delta; encoder_delta = 0;
        invalid = encoder_invalid; encoder_invalid = 0;
        portEXIT_CRITICAL(&encoder_lock);
        if (turns) {
            portENTER_CRITICAL(&snapshot_lock);
            if(turns < 0) snapshot.preview_right += -turns; else snapshot.preview_left += turns;
            portEXIT_CRITICAL(&snapshot_lock);
            publish(InputKind::Encoder, turns, true);
            ESP_LOGI(kTag, "event=encoder seq=%" PRIu32 " direction=%s steps=%" PRId32,
                sequence++, turns < 0 ? "CW" : "CCW", turns < 0 ? -turns : turns);
        }
        if (invalid) { ESP_LOGW(kTag, "event=encoder_invalid count=%" PRIu32, invalid); }
        if (now >= next_sample) {
            next_sample = now + 20000;
            int x = 0, y = 0;
            uint32_t touch = 0;
            const esp_err_t ex = adc_oneshot_read(adc, x_channel, &x);
            const esp_err_t ey = adc_oneshot_read(adc, y_channel, &y);
            const esp_err_t et = touch_pad_read_raw_data(TOUCH_PAD_NUM7, &touch);
            const bool valid = ex == ESP_OK && ey == ESP_OK && et == ESP_OK && touch > 0;
            if (!valid) {
                // Fail-fast diagnostics rather than retaining a stale held action.
                fault(1, int(ex), int(ey), touch, int(et));
                ESP_LOGE(kTag, "event=sensor_error x=%s y=%s touch=%s raw_touch=%" PRIu32,
                    esp_err_to_name(ex), esp_err_to_name(ey), esp_err_to_name(et), touch);
                vTaskDelete(nullptr);
            }
            if (!calibrated) {
                sum_x += x; sum_y += y; sum_touch += touch; ++samples;
                min_x = std::min(min_x, x); max_x = std::max(max_x, x);
                min_y = std::min(min_y, y); max_y = std::max(max_y, y);
                min_touch = std::min(min_touch, touch); max_touch = std::max(max_touch, touch);
                if (samples == 100) {
                    center_x = sum_x / samples; center_y = sum_y / samples;
                    baseline = sum_touch / samples;
                    // Startup acceptance bounds for joystick centers, touch baseline and sample stability.
                    // These board-specific thresholds are not universal sensor limits; other hardware needs calibration.
                    if (center_x < 1400 || center_x > 2300 || center_y < 1400 || center_y > 2300 ||
                        max_x - min_x > 200 || max_y - min_y > 200 ||
                        baseline < 20000 || baseline > 45000 || max_touch - min_touch > baseline / 10) {
                        fault(2, center_x, center_y, baseline, max_x-min_x, max_y-min_y, max_touch-min_touch);
                        ESP_LOGE(kTag, "event=calibration_failed x=%d y=%d touch=%" PRIu32 " action=release_controls_and_reset",
                            center_x, center_y, baseline);
                        vTaskDelete(nullptr);
                    }
                    calibrated = true;
                    portENTER_CRITICAL(&snapshot_lock); snapshot.ready=true; portEXIT_CRITICAL(&snapshot_lock);
                    publish(InputKind::Ready,0,true);
                    ESP_LOGI(kTag, "event=calibrated x=%d y=%d touch=%" PRIu32 " touch_on=%" PRIu32 " touch_off=%" PRIu32,
                        center_x, center_y, baseline, baseline + baseline / 2, baseline + baseline / 4);
                }
            } else {
                const int dx = x - center_x, dy = y - center_y;
                const int ax = std::abs(dx), ay = std::abs(dy);
                portENTER_CRITICAL(&snapshot_lock);
                snapshot.preview_x = ax < 200 ? 0 : std::clamp(dx * 1000 / 1600, -1000, 1000);
                snapshot.preview_y = ay < 200 ? 0 : std::clamp(-dy * 1000 / 1600, -1000, 1000);
                portEXIT_CRITICAL(&snapshot_lock);
                // Independent eight-way classifier. Native Codex classifier below is unchanged.
                int next_quick = 0;
                if (quick && std::max(ax, ay) >= 400) { next_quick = quick; }
                if (std::max(ax, ay) >= 700) {
                    float angle = std::atan2(float(dx), float(dy));
                    if (angle < 0) { angle += 6.2831853f; }
                    int sector = int(std::floor((angle + 0.3926991f) / 0.7853982f)) % 8;
                    float distance = quick ? std::abs(angle - (quick - 1) * 0.7853982f) : 9;
                    distance = std::min(distance, 6.2831853f - distance);
                    if (!quick || distance > 0.48f) { next_quick = sector + 1; }
                }
                if (next_quick != quick_candidate) { quick_candidate = next_quick; quick_since = now; }
                if (quick_candidate != quick && now - quick_since >= 40000) {
                    quick = quick_candidate;
                    portENTER_CRITICAL(&snapshot_lock); snapshot.quick_direction = quick; portEXIT_CRITICAL(&snapshot_lock);
                    publish(InputKind::QuickStick, quick, quick != 0);
                }
                int proposed = 0;
                if (direction != 0 && std::max(ax, ay) >= 400) { proposed = direction; }
                if (std::max(ax, ay) >= 700) {
                    // Ambiguous diagonal retains the current direction; centre has no direction.
                    if (ax > ay + 250) { proposed = dx > 0 ? 2 : 4; }
                    else if (ay > ax + 250) { proposed = dy > 0 ? 1 : 3; }
                }
                if (proposed != candidate) { candidate = proposed; candidate_since = now; }
                if (candidate != direction && now - candidate_since >= 40000) {
                    if (direction) { ESP_LOGI(kTag, "event=stick seq=%" PRIu32 " direction=%s state=up", sequence++, directions[direction]); }
                    direction = candidate;
                    portENTER_CRITICAL(&snapshot_lock);snapshot.direction=direction;portEXIT_CRITICAL(&snapshot_lock);
                    publish(InputKind::Stick,direction,direction!=0);
                    if (direction) { ESP_LOGI(kTag, "event=stick seq=%" PRIu32 " direction=%s state=down", sequence++, directions[direction]); }
                }
                const uint32_t threshold = touched.stable ? baseline + baseline / 4 : baseline + baseline / 2;
                if (touched.update(touch >= threshold, now)) {
                    // The consumer can run as soon as publish wakes it. Commit the
                    // released state first so prepare_change does not see the old touch.
                    portENTER_CRITICAL(&snapshot_lock);
                    snapshot.touched=touched.stable; if(touched.stable) ++snapshot.preview_touch;
                    portEXIT_CRITICAL(&snapshot_lock);
                    publish(InputKind::Touch,0,touched.stable);
                    ESP_LOGI(kTag, "event=touch seq=%" PRIu32 " state=%s raw=%" PRIu32, sequence++, touched.stable ? "down" : "up", touch);
                }
            }
            if (now >= next_report) {
                next_report = now + 2000000;
                ESP_LOGI(kTag, "event=sample seq=%" PRIu32 " x=%d y=%d touch=%" PRIu32 " calibrated=%d",
                    sequence++, x, y, touch, static_cast<int>(calibrated));
            }
        }
        if(now>=next_battery) {
            next_battery=now+1000000;
            int raw=0,mv=0;
            const bool valid=battery_calibration && adc_oneshot_read(adc,ADC_CHANNEL_3,&raw)==ESP_OK &&
                adc_cali_raw_to_voltage(battery_calibration,raw,&mv)==ESP_OK;
            const bool charging=!gpio_get_level(GPIO_NUM_41),full=!gpio_get_level(GPIO_NUM_42);
            portENTER_CRITICAL(&snapshot_lock);
            snapshot.battery_valid=valid;
            snapshot.battery_mv=valid?mv*2:0;
            snapshot.battery_percent=valid?std::clamp((mv*2-3300)*100/900,0,100):0;
            snapshot.charging=charging; snapshot.full=full;
            portEXIT_CRITICAL(&snapshot_lock);
        }
        vTaskDelay(1);
    }
}
} // namespace

void start_inputs() {
    events=xQueueCreate(96,sizeof(InputEvent)); configASSERT(events);
    gpio_config_t output = {};
    output.pin_bit_mask = (1ULL << kClock) | (1ULL << kLoad) | (1ULL << kEnable);
    output.mode = GPIO_MODE_OUTPUT;
    ESP_ERROR_CHECK(gpio_config(&output));
    gpio_set_level(kEnable, 1);
    gpio_set_level(kLoad, 1);
    gpio_set_level(kClock, 0);
    gpio_config_t input = {};
    input.pin_bit_mask = (1ULL << kData) | (1ULL << kA) | (1ULL << kB) | (1ULL << kPush) | (1ULL << GPIO_NUM_41) | (1ULL << GPIO_NUM_42);
    input.mode = GPIO_MODE_INPUT;
    input.pull_up_en = GPIO_PULLUP_ENABLE;
    ESP_ERROR_CHECK(gpio_config(&input));
    encoder_state = (gpio_get_level(kA) << 1) | gpio_get_level(kB);
    ESP_ERROR_CHECK(gpio_install_isr_service(0));
    ESP_ERROR_CHECK(gpio_set_intr_type(kA, GPIO_INTR_ANYEDGE));
    ESP_ERROR_CHECK(gpio_set_intr_type(kB, GPIO_INTR_ANYEDGE));
    ESP_ERROR_CHECK(gpio_isr_handler_add(kA, encoder_edge, nullptr));
    ESP_ERROR_CHECK(gpio_isr_handler_add(kB, encoder_edge, nullptr));

    adc_unit_t x_unit, y_unit;
    ESP_ERROR_CHECK(adc_oneshot_io_to_channel(10, &x_unit, &x_channel));
    ESP_ERROR_CHECK(adc_oneshot_io_to_channel(9, &y_unit, &y_channel));
    ESP_ERROR_CHECK(x_unit == y_unit ? ESP_OK : ESP_ERR_INVALID_ARG);
    adc_oneshot_unit_init_cfg_t unit = {};
    unit.unit_id = x_unit;
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&unit, &adc));
    adc_oneshot_chan_cfg_t channel = {};
    channel.atten = ADC_ATTEN_DB_12;
    channel.bitwidth = ADC_BITWIDTH_12;
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc, x_channel, &channel));
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc, y_channel, &channel));
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc, ADC_CHANNEL_3, &channel));
    adc_cali_curve_fitting_config_t calibration{};
    calibration.unit_id=x_unit; calibration.chan=ADC_CHANNEL_3;
    calibration.atten=ADC_ATTEN_DB_12; calibration.bitwidth=ADC_BITWIDTH_12;
    if(adc_cali_create_scheme_curve_fitting(&calibration,&battery_calibration)!=ESP_OK) battery_calibration=nullptr;

    // IDF 5.5.3 legacy touch API is used only for raw characterization.
    ESP_ERROR_CHECK(touch_pad_init());
    ESP_ERROR_CHECK(touch_pad_config(TOUCH_PAD_NUM7));
    ESP_ERROR_CHECK(touch_pad_set_fsm_mode(TOUCH_FSM_MODE_TIMER));
    ESP_ERROR_CHECK(touch_pad_fsm_start());
    vTaskDelay(pdMS_TO_TICKS(100));
    ESP_LOGI(kTag, "event=ready scan_tick_ms=%u debounce_ms=30 analog_period_ms=20 report_period_ms=2000 mapping=board3_verified",
        static_cast<unsigned>(portTICK_PERIOD_MS));
    const BaseType_t result = xTaskCreate(input_task, "input_diag", 4096, nullptr, 5, nullptr);
    ESP_ERROR_CHECK(result == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
}

InputSnapshot input_snapshot() {
    portENTER_CRITICAL(&snapshot_lock); auto result=snapshot; portEXIT_CRITICAL(&snapshot_lock); return result;
}
bool next_input(InputEvent &event) {return events && xQueueReceive(events,&event,0)==pdTRUE;}
void clear_inputs() {if(events)xQueueReset(events);}
uint32_t input_drops() {return drops.load();}

InputSnapshot take_preview_snapshot() {
    portENTER_CRITICAL(&snapshot_lock); auto value=snapshot; snapshot.preview_pressed=0; portEXIT_CRITICAL(&snapshot_lock); return value;
}

void set_preview_cancelled(bool value) {
    portENTER_CRITICAL(&snapshot_lock); snapshot.quick_cancelled=value; portEXIT_CRITICAL(&snapshot_lock);
}
