#pragma once
#include <algorithm>

// Voltage-based usable-charge estimate, not a coulomb counter or runtime prediction.
// Reserve the low end for reliable input; never use loss of communication as 0%.
struct BatteryEstimate {
    int filtered_mv=0;
    bool initialized=false;
    static int percent(int mv) {
        struct Point { int mv, percent; };
        constexpr Point curve[]={{3100,0},{3200,1},{3300,3},{3400,6},{3500,12},
            {3600,20},{3700,32},{3800,48},{3900,65},{4000,82},{4100,96},{4150,99}};
        if(mv<=curve[0].mv)return 0;
        for(unsigned i=1;i<sizeof(curve)/sizeof(curve[0]);++i) {
            if(mv<=curve[i].mv) {
                const auto a=curve[i-1],b=curve[i];
                return a.percent+(mv-a.mv)*(b.percent-a.percent)/(b.mv-a.mv);
            }
        }
        return 99; // 100% requires the charger's full indication.
    }
    int update(int mv,bool valid,bool charging,bool full) {
        if(!valid){initialized=false;return 0;}
        if(!initialized){filtered_mv=mv;initialized=true;}
        else filtered_mv+=(mv-filtered_mv)/4; // Existing 1 Hz readings; fixed RAM, no extra ADC work.
        if(full)return 100;
        // Do not smooth away a low-voltage drop; rises settle gradually.
        return percent(charging?filtered_mv:std::min(mv,filtered_mv));
    }
};
