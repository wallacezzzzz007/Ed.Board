// SPDX-License-Identifier: MIT
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <utility>
namespace aim {
inline constexpr size_t report_size=63, fragment_size=61, json_limit=4096;
// 每个传输分别持有一个解析器，防止 USB/BLE 的半包混合。
class Framer {
public:
    using Message=std::function<void(const std::string&)>;
    void reset();
    void feed(const uint8_t* bytes,size_t length,int64_t now_ms,const Message& message);
    unsigned errors=0;
private:
    std::string text;
    std::array<char,32> closing{};
    size_t depth=0;
    bool quoted=false, escaped=false, discard=false;
    int64_t last_ms=0;
};
bool send_fragments(const std::string&,const std::function<bool(const uint8_t*,size_t)>&);
struct Light { uint32_t rgb=0; float brightness=0.15f, speed=0.5f; uint8_t effect=1; };
struct Lights { std::array<Light,6> agents{}; Light ambient{}, commands{}; };
// 回调返回 JSON 对象文本。协议核心无需硬件或 ESP-IDF，便于主机测试。
class Protocol {
public:
    explicit Protocol(std::string version):version_(std::move(version)) {}
    std::function<std::string()> status;
    Lights lights{};
    int last_error=0; // Ed.Board: observable validation result, including notifications.
    std::string request(const std::string&);
    static std::string key(const char* position,bool down,int agent=-1);
    static std::string radial(float degrees,float distance);
private:
    std::string version_;
};
}
