#pragma once

namespace board {
// A touch may leave an automatic Extended layer. Lease renewals for that same
// match must not immediately undo the user's selection. A new match/session
// or lease expiry releases the override; ordinary Favorite auto priority stays.
class AutoLayerPolicy {
public:
    unsigned accept(unsigned requested) {
        if(requested!=dismissed_)dismissed_=0;
        return dismissed_?0:requested;
    }
    void dismiss(unsigned layer) { dismissed_=layer; }
    void reset() { dismissed_=0; }
private:
    unsigned dismissed_=0;
};
}
