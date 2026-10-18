#pragma once
#include <cstdint>
#include "cJSON.h"
namespace board {
class Power {
public:
    void load();
    const char *save(unsigned seconds, bool enabled, unsigned deepMinutes, bool keepConnected, unsigned baseRevision);
    cJSON *json() const;
    void activity(int64_t now) { lastActivity_=lastDeepActivity_=now; sleeping_=false; deepDue_=false; }
    void tick(int64_t now, bool externalPower, bool held, bool pairing);
    bool deepDue() const { return deepDue_; }
    void recordWake(bool deep, unsigned layer, unsigned count) { woke_=deep; restoredLayer_=layer; wakeCount_=count; }
    bool sleeping() const { return sleeping_; }
private:
    unsigned seconds_=60, revision_=0, deepMinutes_=15, restoredLayer_=0, wakeCount_=0;
    bool enabled_=true, writable_=false, sleeping_=false, keepConnected_=false, deepDue_=false, woke_=false;
    int64_t lastActivity_=0, lastDeepActivity_=0;
};
}
