#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <vector>
#include "cJSON.h"
#include "media.hpp"

namespace board {
constexpr size_t control_count=25, max_layers=6, config_bytes=8192, frame_bytes=32768;
enum class Kind { Native=0, Shortcut=1, Disabled=2, Inherit=3, Application=4, Open=5, Text=6, Cancel=7, Media=8 };
struct Binding { Kind kind=Kind::Native; uint8_t usage=0, modifiers=0; uint32_t source=0; uint8_t key_count=0; std::array<uint8_t,14> keys{}; };
struct LightSpec { bool custom=false; uint8_t effect=1; uint32_t color=0xffffff; uint8_t brightness=15, active=100; };
inline bool is_host(Kind k) { return k==Kind::Application||k==Kind::Open||k==Kind::Text; }
struct Layer {
    uint8_t id=1; std::string name="Codex"; bool native=true;
    uint32_t color=0xffffff, ring_color=0xffffff; uint8_t brightness=15;
    std::array<Binding,control_count> bindings{};
    std::array<int,5> effects{1,100,1,-1,100};
    std::array<LightSpec,13> key_lights{};
};
struct Configuration {
    std::string migration_note;
    uint32_t revision=0; uint8_t manual_layer=1, active_layer=1; // Runtime only, never encoded into configuration.
    std::vector<Layer> layers{Layer{}};
    const Layer *layer(unsigned id) const;
    const Layer &active() const;
    Binding resolve(unsigned layer_id,unsigned control) const;
};
bool valid_integer(const cJSON *item, uint32_t max);
bool exact_fields(const cJSON *item, const char *const *names, size_t count);
bool decode_config(const cJSON *json, Configuration &out, unsigned legacy_version=0);
cJSON *encode_config(const Configuration &config);
cJSON *encode_snapshot(const Configuration &config);
class ConfigStore {
public:
    void load();
    bool save(const Configuration &config);
    bool select(unsigned id);
    bool activate(unsigned id);
    const Configuration &current() const { return value_; }
    bool writable() const { return writable_; }
    const std::string &error() const { return error_; }
private:
    Configuration value_{};
    bool writable_=false;
    std::string error_;
};
}
