#pragma once
#include <algorithm>
#include <cstdint>

// Fixed-size calibration windows; failures back off without accepting unstable input.
// Bounds are board-specific and match the original startup acceptance criteria.
struct InputCalibration {
    enum class Result { Waiting, Failed, Ready };
    int samples=0, sum_x=0, sum_y=0, min_x=4095, max_x=0, min_y=4095, max_y=0;
    uint64_t sum_touch=0;
    uint32_t min_touch=UINT32_MAX, max_touch=0;
    int x=0,y=0;
    uint32_t touch=0;
    int reference_x=0, reference_y=0;
    uint32_t reference_touch=0;
    unsigned failures=0;
    int64_t retry_at=0;
    bool released=true;

    bool waiting(int64_t now) const { return now < retry_at; }
    void clear_window() {
        samples=sum_x=sum_y=0; sum_touch=0;
        min_x=min_y=4095; max_x=max_y=0;
        min_touch=UINT32_MAX; max_touch=0; released=true;
    }
    void fail(int64_t now) {
        failures=std::min(failures+1,4U);
        retry_at=now+(int64_t(1) << (failures-1))*1000000; // 1, 2, 4, then 8 seconds.
        clear_window();
    }
    Result add(int64_t now,int raw_x,int raw_y,uint32_t raw_touch,bool controls_released) {
        if(waiting(now))return Result::Waiting;
        released=released&&controls_released;
        sum_x+=raw_x; sum_y+=raw_y; sum_touch+=raw_touch;
        min_x=std::min(min_x,raw_x); max_x=std::max(max_x,raw_x);
        min_y=std::min(min_y,raw_y); max_y=std::max(max_y,raw_y);
        min_touch=std::min(min_touch,raw_touch); max_touch=std::max(max_touch,raw_touch);
        if(++samples<100)return Result::Waiting;
        x=sum_x/samples; y=sum_y/samples; touch=sum_touch/samples;
        // Caller records these statistics before fail() clears the rejected window.
        if(!released || x<1400 || x>2300 || y<1400 || y>2300 ||
           max_x-min_x>200 || max_y-min_y>200 || touch<20000 || touch>45000 ||
           max_touch-min_touch>touch/10)return Result::Failed;
        // After a runtime read failure, do not recalibrate around a held control.
        if(reference_touch && (x<reference_x-200 || x>reference_x+200 ||
           y<reference_y-200 || y>reference_y+200 ||
           touch<reference_touch-reference_touch/10 || touch>reference_touch+reference_touch/10))
            return Result::Failed;
        reference_x=x; reference_y=y; reference_touch=touch;
        failures=0;
        return Result::Ready;
    }
};
