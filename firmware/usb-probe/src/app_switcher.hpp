#pragma once
namespace board {
// Command remains down between Tab pulses; Shift exists only for reverse steps.
// The caller merges this temporary state into the existing keyboard report.
class AppSwitcher {
public:
    bool active() const { return active_; }
    unsigned modifiers() const { return active_ ? (8U | (reverse_ ? 2U : 0U)) : 0U; }
    bool tab() const { return tab_; }
    void reset() { active_=tab_=reverse_=false; }
    template<class Send> bool begin(Send send) {
        if(active_)return true;
        active_=true;return step(false,send);
    }
    template<class Send> bool step(bool reverse,Send send) {
        if(!active_)return true;
        reverse_=reverse;tab_=true;
        if(!send()){reset();return false;}
        tab_=reverse_=false;
        if(!send()){reset();return false;}
        return true;
    }
    template<class Send> bool finish(Send send) {
        if(!active_)return true;
        reset();return send();
    }
private:
    bool active_=false,tab_=false,reverse_=false;
};
}
