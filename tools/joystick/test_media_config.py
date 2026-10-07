"""Offline firmware configuration checks using ESP-IDF's cJSON and fake NVS.

Requires the project's PlatformIO ESP-IDF dependency (or CJSON_DIR).
No device, flash, or real NVS access.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class MediaConfigTests(unittest.TestCase):
    def test_configuration_and_storage_upgrade(self):
        candidates = [Path(os.environ['CJSON_DIR'])] if 'CJSON_DIR' in os.environ else list(
            (Path(os.environ.get('PLATFORMIO_CORE_DIR', Path.home()/'.platformio'))/'packages').glob('framework-espidf*/components/json/cJSON'))
        cjson = next((p for p in candidates if (p/'cJSON.c').is_file()), None)
        if cjson is None:
            self.skipTest('Install the project ESP-IDF dependency or set CJSON_DIR to its cJSON directory')
        nvs = r'''
#pragma once
#include <map>
#include <string>
#include <vector>
#include <cstring>
using esp_err_t=int;using nvs_handle_t=int;
constexpr int ESP_OK=0,ESP_FAIL=-1,ESP_ERR_NVS_NOT_FOUND=1,NVS_READWRITE=0;
inline std::map<std::string,std::vector<char>> blobs, staged;
inline bool fail_write=false,fail_commit=false,fail_erase=false,corrupt_read=false;
inline const char *esp_err_to_name(int){return "test_error";}
inline int nvs_flash_init_partition(const char *){return 0;}
inline int nvs_open_from_partition(const char *,const char *,int,int *h){*h=1;staged=blobs;return 0;}
inline void nvs_close(int){staged.clear();}
inline int nvs_commit(int){if(fail_commit)return ESP_FAIL;blobs=staged;return 0;}
inline int nvs_erase_key(int,const char *key){if(fail_erase)return ESP_FAIL;return staged.erase(key)?ESP_OK:ESP_ERR_NVS_NOT_FOUND;}
inline int nvs_get_blob(int,const char *key,void *out,size_t *size){
 auto it=blobs.find(key);if(it==blobs.end())return ESP_ERR_NVS_NOT_FOUND;
 if(out){if(*size<it->second.size())return ESP_FAIL;std::memcpy(out,it->second.data(),it->second.size());if(corrupt_read&&*size)static_cast<char *>(out)[0]^=1;}
 *size=it->second.size();return 0;
}
inline int nvs_get_str(int h,const char *key,char *out,size_t *size){return nvs_get_blob(h,key,out,size);}
inline int nvs_set_blob(int,const char *key,const void *data,size_t size){
 size_t occupied=0;for(const auto &entry:blobs)occupied+=entry.second.size()+128;
 // Bounded allocation model, including the old blob during replacement.
 if(fail_write||occupied+size+128>20000)return ESP_FAIL;
 auto *p=static_cast<const char *>(data);staged[key]={p,p+size};return 0;
}
'''
        source = r'''
#include "configuration.cpp"
#include "auto_layer_policy.hpp"
#include <cassert>
#include <fstream>
#include <iterator>
#include <iostream>
using namespace board;
static std::vector<uint8_t> pack7(const Configuration &c) {
    std::vector<uint8_t> data;auto put=[&](uint32_t n,unsigned bytes=1){for(unsigned i=0;i<bytes;++i)data.push_back((n>>(i*8))&255);};
    put(7);put(c.revision,4);put(c.layers.size());
    for(const auto &l:c.layers){put(l.id);put(l.name.size());for(auto ch:l.name)put(uint8_t(ch));put(l.native);
        put(l.color,3);put(l.ring_color,3);put(l.brightness);for(int e:l.effects)put(e<0?255:e);
        for(auto b:l.bindings){put(unsigned(b.kind));put(b.usage);put(b.modifiers);put(b.source,4);put(b.key_count);for(auto k:b.keys)put(k);}
        for(auto v:l.key_lights){put(v.custom);put(v.effect);put(v.color,3);put(v.brightness);put(v.active);}
    }return data;
}

cJSON *read(const char *path){std::ifstream f(path);std::string text((std::istreambuf_iterator<char>(f)),{});auto *j=cJSON_Parse(text.c_str());assert(j);return j;}
int main(int argc,char **argv){
 assert(argc==3);
 auto *legacy=read(argv[1]);Configuration original;
 assert(decode_config(cJSON_GetObjectItemCaseSensitive(legacy,"maximumConfig"),original));
 original.revision=10;auto old=pack7(original);old[0]=6;
 blobs["snapshot6"]={old.begin(),old.end()};
 ConfigStore store;store.load();assert(store.writable());assert(store.current().revision==10);
 assert(store.current().favorites.size()==6);
 for(unsigned i=0;i<6;++i)assert(store.current().favorites[i]==original.layers[i].id);
 auto config=store.current();unsigned usages[]={233,234,226,205,182,181};
 for(unsigned i=0;i<6;++i){config.layers[1].bindings[i]={Kind::Media,uint8_t(usages[i])};}
 auto *json=encode_config(config);Configuration decoded;
 assert(decode_config(json,decoded));cJSON_Delete(json);
 for(unsigned i=0;i<6;++i)assert(decoded.resolve(config.layers[1].id,i).usage==usages[i]);
 for(unsigned bad:{0U,4U,115U,180U,235U}){
   auto broken=config;broken.layers[1].bindings[0].usage=bad;
   json=encode_config(broken);assert(!decode_config(json,decoded));cJSON_Delete(json);
 }
 for(bool source:{false,true}){
   auto broken=config;auto &b=broken.layers[1].bindings[0];if(source)b.source=1;else b.modifiers=1;
   json=encode_config(broken);assert(!decode_config(json,decoded));cJSON_Delete(json);
 }
 fail_write=true;assert(!store.save(config));assert(blobs.count("snapshot6") && !blobs.count("snapshot8"));
 fail_write=false;store.load();assert(store.writable());
 fail_commit=true;assert(!store.save(config));assert(blobs.count("snapshot6") && !blobs.count("snapshot8"));
 fail_commit=false;store.load();
 // Readback failure retains legacy recovery data, never reports a verified save.
 corrupt_read=true;assert(!store.save(config));assert(blobs.count("snapshot6"));corrupt_read=false;
 ConfigStore reload;reload.load();assert(reload.writable());assert(reload.current().revision==11);
 assert(!blobs.count("snapshot6") && blobs.count("snapshot8"));
 assert(reload.current().resolve(config.layers[1].id,5).usage==181);
 // New format cleanup may fail independently of a successful configuration commit.
 blobs["snapshot7"]={old.begin(),old.end()};fail_erase=true;
 assert(reload.save(config));assert(!reload.writable());assert(reload.error()=="legacy_cleanup_failed");
 fail_erase=false;reload.load();assert(reload.writable());assert(!blobs.count("snapshot7"));
 auto *fixtures=read(argv[2]);Configuration maximum;
 auto *maximumJSON=cJSON_GetObjectItemCaseSensitive(fixtures,"maximumConfig");assert(decode_config(maximumJSON,maximum));
 assert(maximum.layers.size()==16 && maximum.favorites.size()==6);
 auto full=pack8(maximum,true);assert(full.size()==8101 && full.size()<=config_bytes);
 assert(reload.save(maximum));
 for(unsigned n=0;n<12;++n){maximum.layers[15].color=n;assert(reload.save(maximum));}
 ConfigStore fullReload;fullReload.load();assert(fullReload.writable());assert(fullReload.current().layers.size()==16);
 assert(fullReload.current().layers[15].color==11);
 assert(fullReload.current().manual_layer==2 && fullReload.current().active_layer==2);
 assert(fullReload.current().next_favorite(16)==2);assert(fullReload.current().next_favorite(1)==2);
 assert(!fullReload.select(16));assert(fullReload.select(1));assert(fullReload.activate(16));
 auto invalid=maximum;invalid.favorites.clear();assert(!fullReload.save(invalid));
 invalid=maximum;invalid.favorites={1,1};assert(!fullReload.save(invalid));
 invalid=maximum;invalid.layers[0].name=std::string("\xff",1);assert(!fullReload.save(invalid));
 for(unsigned i=1;i<16;++i)maximum.layers[i].bindings[0]={Kind::Inherit,0,0,uint32_t(maximum.layers[i-1].id)};
 assert(valid_config(maximum));assert(maximum.resolve(16,0).kind==Kind::Shortcut);
 maximum.layers[0].bindings[0]={Kind::Inherit,0,0,16};assert(!valid_config(maximum));
 auto *validJSON=cJSON_GetObjectItemCaseSensitive(fixtures,"validConfig");Configuration valid;
 assert(decode_config(validJSON,valid));assert(valid.layers[2].id==240 && valid.layers[2].name=="扩展");
 assert(valid.favorites==std::vector<uint8_t>({8,1}));assert(valid.resolve(240,0).source==7);
 assert(valid.layers[1].key_lights[0].color==0xa8932e);
 assert(valid.layers[2].bindings[14].key_count==2 && valid.layers[2].bindings[14].keys[0]==227);
 json=encode_config(valid);assert(!strcmp(cJSON_GetObjectItemCaseSensitive(json,"payload")->valuestring,cJSON_GetObjectItemCaseSensitive(validJSON,"payload")->valuestring));cJSON_Delete(json);
 for(auto *item=cJSON_GetObjectItemCaseSensitive(fixtures,"invalidConfigs")->child;item;item=item->next)assert(!decode_config(cJSON_GetObjectItemCaseSensitive(item,"config"),decoded));
 auto packed=pack8(valid);std::vector<char> truncated(packed.begin(),packed.end());
 for(size_t size=0;size<truncated.size();++size)assert(!unpack8(truncated,size,decoded));
 // Current pre-upgrade firmware writes format 7, including Media actions.
 auto latest=blobs;blobs.clear();auto old7=pack7(config);
 blobs["snapshot7"]={old7.begin(),old7.end()};ConfigStore from7;from7.load();
 assert(from7.writable() && from7.current().resolve(config.layers[1].id,5).usage==181);
 assert(from7.current().favorites.size()==6);assert(from7.save(from7.current()));
 assert(!blobs.count("snapshot7") && blobs.count("snapshot8"));blobs=latest;
 // A corrupt newest snapshot must not silently activate stale settings.
 blobs["snapshot8"].pop_back();ConfigStore corrupt;corrupt.load();assert(!corrupt.writable());
 AutoLayerPolicy policy;
 assert(policy.accept(240)==240);policy.dismiss(240);
 for(unsigned i=0;i<10;++i)assert(policy.accept(240)==0);
 assert(policy.accept(0)==0);assert(policy.accept(240)==240);
 policy.dismiss(240);assert(policy.accept(8)==8);assert(policy.accept(240)==240);
 policy.dismiss(240);policy.reset();assert(policy.accept(240)==240);
 std::cout<<"PASS: legacy migration, shared v7 fixtures, 8101-byte snapshots, repeat saves, failure recovery, Favorites and auto-touch policy\n";
 cJSON_Delete(fixtures);cJSON_Delete(legacy);
}
'''
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            (root/'nvs.h').write_text(nvs)
            (root/'nvs_flash.h').write_text('#include "nvs.h"\n')
            (root/'test.cpp').write_text(source)
            subprocess.run(['cc','-c',str(cjson/'cJSON.c'),'-o',str(root/'json.o')],check=True)
            subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-I',str(root),'-I',str(cjson),'-I',str(ROOT/'firmware/usb-probe/src'),str(root/'test.cpp'),str(root/'json.o'),'-o',str(root/'test')],check=True)
            subprocess.run([str(root/'test'),str(ROOT/'protocol/fixtures/management-v6.json'),str(ROOT/'protocol/fixtures/management-v7.json')],check=True)

if __name__=='__main__': unittest.main()
