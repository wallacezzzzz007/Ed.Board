#include "power.hpp"
#include "nvs.h"
#include "esp_timer.h"
#include <cstring>
#include <algorithm>
namespace board {
namespace {
struct Legacy {uint32_t version, revision, minutes, enabled;};
struct Stored {uint32_t version, revision, minutes, enabled, deepMinutes, keepConnected;};
// v3 keeps the six-word layout; the third word is seconds rather than minutes.
bool valid(const Stored &s) {return s.version==3&&s.revision<=0x7fffffff&&s.minutes>=30&&s.minutes<=7200&&s.enabled<=1&&s.deepMinutes>=1&&s.deepMinutes<=1440&&s.keepConnected<=1&&(!s.enabled||s.keepConnected||s.deepMinutes*60>s.minutes);}
bool legacy_valid(const Stored &s) {return s.version==2&&s.revision<=0x7fffffff&&s.minutes>=1&&s.minutes<=120&&s.enabled<=1&&s.deepMinutes>=1&&s.deepMinutes<=1440&&s.keepConnected<=1&&(!s.enabled||s.deepMinutes>s.minutes);}
}
void Power::load() {
    lastActivity_=esp_timer_get_time();
    nvs_handle_t h=0;
    if(nvs_open_from_partition("edboard","power",NVS_READWRITE,&h)!=ESP_OK)return;
    Stored s{};size_t size=sizeof(s);
    auto e=nvs_get_blob(h,"settings",&s,&size);nvs_close(h);
    if(e==ESP_ERR_NVS_NOT_FOUND){writable_=true;return;}
    // Read legacy four-word blob without erasing or writing during boot.
    if(e==ESP_OK&&size==sizeof(Legacy)&&s.version==1) {
        s.version=2;s.deepMinutes=std::max<uint32_t>(15,s.minutes+1);s.keepConnected=0;
    } else if(size!=sizeof(s))return;
    if(e==ESP_OK&&s.version==2) {if(!legacy_valid(s))return;s.minutes*=60;s.version=3;}
    if(e!=ESP_OK||!valid(s))return;
    seconds_=s.minutes;enabled_=s.enabled;deepMinutes_=s.deepMinutes;keepConnected_=s.keepConnected;revision_=s.revision;writable_=true;
}
const char *Power::save(unsigned seconds,bool enabled,unsigned deepMinutes,bool keepConnected,unsigned baseRevision) {
    if(!writable_)return "power_storage_unavailable";
    if(baseRevision!=revision_)return "power_revision_conflict";
    if(seconds<30||seconds>7200||deepMinutes<1||deepMinutes>1440||(enabled&&!keepConnected&&deepMinutes*60<=seconds)||revision_==0x7fffffff)return "invalid_power_settings";
    if(seconds==seconds_&&enabled==enabled_&&deepMinutes==deepMinutes_&&keepConnected==keepConnected_)return nullptr;
    Stored s{3,revision_+1,seconds,unsigned(enabled),deepMinutes,unsigned(keepConnected)},check{};
    nvs_handle_t h=0;auto e=nvs_open_from_partition("edboard","power",NVS_READWRITE,&h);
    if(e==ESP_OK) {
        e=nvs_set_blob(h,"settings",&s,sizeof(s));if(e==ESP_OK)e=nvs_commit(h);
        size_t size=sizeof(check);if(e==ESP_OK)e=nvs_get_blob(h,"settings",&check,&size);
        if(e==ESP_OK&&(size!=sizeof(check)||std::memcmp(&s,&check,sizeof(s))))e=ESP_FAIL;
        nvs_close(h);
    }
    if(e!=ESP_OK){writable_=false;return "power_storage_unavailable";}
    seconds_=seconds;enabled_=enabled;deepMinutes_=deepMinutes;keepConnected_=keepConnected;revision_=s.revision;
    activity(esp_timer_get_time());return nullptr;
}
void Power::tick(int64_t now,bool usb,bool held,bool pairing) {
    if(usb||held||pairing){activity(now);return;}
    deepDue_=writable_&&!keepConnected_&&now-lastActivity_>=int64_t(deepMinutes_)*60000000;
    sleeping_=writable_&&enabled_&&now-lastActivity_>=int64_t(seconds_)*1000000;
}
cJSON *Power::json() const {
    auto *r=cJSON_CreateObject();
    cJSON_AddNumberToObject(r,"revision",revision_);
    cJSON_AddNumberToObject(r,"powerVersion",2);
    cJSON_AddNumberToObject(r,"idleSeconds",seconds_);
    cJSON_AddNumberToObject(r,"idleMinutes",(seconds_+59)/60);
    cJSON_AddBoolToObject(r,"enabled",enabled_);
    cJSON_AddNumberToObject(r,"deepMinutes",deepMinutes_);
    cJSON_AddBoolToObject(r,"keepConnected",keepConnected_);
    cJSON_AddStringToObject(r,"wakeReason",woke_?"knob":"boot");
    cJSON_AddNumberToObject(r,"restoredManualLayer",restoredLayer_);
    cJSON_AddNumberToObject(r,"wakeCount",wakeCount_);
    cJSON_AddBoolToObject(r,"writable",writable_);
    cJSON_AddBoolToObject(r,"lightsSleeping",sleeping_);
    return r;
}
}
