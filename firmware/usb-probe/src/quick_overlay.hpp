#pragma once
#include <cstdint>
#include <cstdlib>

namespace board {
// Latest state only. Called after action processing; never executes an action.
struct QuickOverlay {
    bool visible=false, blocked=false;
    int x=0,y=0,candidate=0;
    unsigned layer=0;
    uint32_t revision=0,gesture=0;
    void update(bool enabled,int px,int py,int selected,bool completed,unsigned active,uint32_t rev) {
        const bool centered=px==0&&py==0;
        if(!enabled || layer!=active || revision!=rev) {visible=false;blocked=!centered;}
        layer=active;revision=rev;
        if(completed) {visible=false;blocked=!centered;}
        // More than one input event may drain in a loop: end followed by a new candidate.
        if(enabled&&completed&&selected!=0) {blocked=false;visible=true;++gesture;}
        if(centered)blocked=false;
        if(enabled&&!completed&&!blocked) {
            const bool next=!centered||selected!=0;
            if(next&&!visible)++gesture;
            visible=next;
        }
        // Suppress ADC noise only in the display; selection thresholds stay untouched.
        if(!visible) {x=0;y=0;}
        else {
            if(px==0 || std::abs(px-x)>=12)x=px;
            if(py==0 || std::abs(py-y)>=12)y=py;
        }
        candidate=visible?selected:0;
    }
    bool operator==(const QuickOverlay &other) const {
        return visible==other.visible&&x==other.x&&y==other.y&&candidate==other.candidate
            &&layer==other.layer&&revision==other.revision&&gesture==other.gesture;
    }
};
}
