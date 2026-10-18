"""Offline idle-power regression tests with a synthetic clock and in-memory NVS."""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class PowerTests(unittest.TestCase):
    def test_powered_lights_and_battery_deep_sleep(self):
        nvs = r'''
#pragma once
#include <vector>
#include <cstring>
using nvs_handle_t=int;
constexpr int ESP_OK=0,ESP_FAIL=-1,ESP_ERR_NVS_NOT_FOUND=1,NVS_READWRITE=0;
inline std::vector<char> blob;
inline int nvs_open_from_partition(const char*,const char*,int,int*h){*h=1;return ESP_OK;}
inline void nvs_close(int){}
inline int nvs_commit(int){return ESP_OK;}
inline int nvs_set_blob(int,const char*,const void*p,size_t n){auto*b=static_cast<const char*>(p);blob.assign(b,b+n);return ESP_OK;}
inline int nvs_get_blob(int,const char*,void*p,size_t*n){if(blob.empty())return ESP_ERR_NVS_NOT_FOUND;if(*n<blob.size())return ESP_FAIL;std::memcpy(p,blob.data(),blob.size());*n=blob.size();return ESP_OK;}
'''
        cjson = r'''
#pragma once
struct cJSON{};
inline cJSON* cJSON_CreateObject(){return new cJSON;}
inline void cJSON_AddNumberToObject(cJSON*,const char*,double){}
inline void cJSON_AddBoolToObject(cJSON*,const char*,bool){}
inline void cJSON_AddStringToObject(cJSON*,const char*,const char*){}
'''
        source = r'''
#include "power.cpp"
#include <cassert>
using board::Power;
constexpr int64_t second=1000000;
Power fresh(){blob.clear();fake_now=0;Power p;p.load();return p;}
int main(){
    // Both supplies share the exact light-off boundary.
    for(bool powered:{false,true}){
        auto p=fresh();p.tick(59*second,powered,false,false);assert(!p.sleeping());
        p.tick(60*second,powered,false,false);assert(p.sleeping());
        p.tick(15*60*second,powered,false,false);assert(p.deepDue()==!powered);
        p.activity(16*60*second);assert(!p.sleeping()&&!p.deepDue());
        p.tick((16*60+59)*second,powered,false,false);assert(!p.sleeping());
        p.tick(17*60*second,powered,false,false);assert(p.sleeping());
    }
    auto p=fresh();p.tick(86400*second,true,false,false);assert(p.sleeping()&&!p.deepDue());
    // Unplug after a long powered idle: lighting stays off, but deep sleep waits.
    p.tick(86401*second,false,false,false);assert(p.sleeping()&&!p.deepDue());
    p.tick((86400+899)*second,false,false,false);assert(!p.deepDue());
    p.tick((86400+900)*second,false,false,false);assert(p.deepDue());
    // Power arrival cancels deep sleep without relighting an idle keyboard.
    p.tick((86400+901)*second,true,false,false);assert(p.sleeping()&&!p.deepDue());
    p.tick((86400+902)*second,true,true,false);assert(!p.sleeping()&&!p.deepDue());
    p.tick((86400+1000)*second,true,false,true);assert(!p.sleeping()&&!p.deepDue());
    // Lights Off and Deep Sleep Off remain independent saved settings.
    auto off=fresh();assert(!off.save(60,false,15,false,0));
    off.tick(1000*second,true,false,false);assert(!off.sleeping()&&!off.deepDue());
    off.tick(1900*second,false,false,false);assert(!off.sleeping()&&off.deepDue());
    auto keep=fresh();assert(!keep.save(60,true,15,true,0));
    keep.tick(1000*second,false,false,false);assert(keep.sleeping()&&!keep.deepDue());
    // Persisted settings still load unchanged; no storage format migration.
    Power reload;reload.load();reload.tick(1000*second,false,false,false);assert(reload.sleeping()&&!reload.deepDue());
}
'''
        with tempfile.TemporaryDirectory(prefix='edboard-power-') as folder:
            path=Path(folder)
            (path/'nvs.h').write_text(nvs);(path/'cJSON.h').write_text(cjson)
            (path/'esp_timer.h').write_text('#pragma once\n#include <cstdint>\ninline int64_t fake_now=0;\ninline int64_t esp_timer_get_time(){return fake_now;}\n')
            (path/'test.cpp').write_text(source)
            subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror','-I',str(path),'-I',str(ROOT/'firmware/usb-probe/src'),str(path/'test.cpp'),'-o',str(path/'test')],check=True)
            subprocess.run([str(path/'test')],check=True)
if __name__=='__main__':unittest.main()
