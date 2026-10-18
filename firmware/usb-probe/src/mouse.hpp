#pragma once
#include <array>
#include <cstdint>
namespace board {
// Relative vertical wheel only: buttons and pointer motion always remain zero.
inline constexpr int8_t wheel_delta(unsigned action) { return action==1?1:action==2?-1:0; }
inline constexpr std::array<uint8_t,4> wheel_report(unsigned action) {
    return {0,0,0,static_cast<uint8_t>(wheel_delta(action))};
}
template<class Send> bool trigger_wheel(unsigned action,bool down,Send send) {
    if(!down)return true; // Relative values do not need a release report.
    if(!wheel_delta(action))return false;
    return send(wheel_report(action));
}
// Fixed-rate joystick scrolling. Schedule from the actual send time, so a
// stalled loop never catches up by emitting a burst of old wheel events.
class WheelRepeat {
public:
    static constexpr int64_t interval_us = 80000;
    void reset() { action_ = 0; next_ = 0; }
    void select(unsigned action, int64_t now) {
        if (!wheel_delta(action)) { reset(); return; }
        if (action_ != action) { action_ = action; next_ = now; }
    }
    template<class Send> bool tick(int64_t now, Send send) {
        if (!action_ || now < next_) return true;
        next_ = now + interval_us;
        if (send(wheel_report(action_))) return true;
        reset();
        return false;
    }
private:
    unsigned action_ = 0;
    int64_t next_ = 0;
};

}
