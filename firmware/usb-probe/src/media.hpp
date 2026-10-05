#pragma once
#include <cstdint>

namespace board {
// USB HID Consumer Page, matching report 2's six one-bit usages.
inline constexpr uint8_t media_bit(unsigned usage) {
    return usage==0xE9?1:usage==0xEA?2:usage==0xE2?4:usage==0xCD?8:usage==0xB6?16:usage==0xB5?32:0;
}
class MediaPulse {
    bool pending_=false;
public:
    void reset() { pending_=false; }
    template<class Send> bool release(Send send) {
        if(pending_&&!send(uint8_t(0)))return false;
        pending_=false;return true;
    }
    template<class Send> bool trigger(unsigned usage,bool down,Send send) {
        if(!down)return true;
        const auto bits=media_bit(usage);
        if(!bits||!release(send))return false;
        if(!send(bits))return false;
        pending_=true;
        return release(send);
    }
};
}
