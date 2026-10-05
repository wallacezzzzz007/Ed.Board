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
inline std::map<std::string,std::vector<char>> blobs;
inline bool fail_write=false;
inline const char *esp_err_to_name(int){return "test_error";}
inline int nvs_flash_init_partition(const char *){return 0;}
inline int nvs_open_from_partition(const char *,const char *,int,int *h){*h=1;return 0;}
inline void nvs_close(int){}
inline int nvs_commit(int){return 0;}
inline int nvs_get_blob(int,const char *key,void *out,size_t *size){
 auto it=blobs.find(key);if(it==blobs.end())return ESP_ERR_NVS_NOT_FOUND;
 if(out){if(*size<it->second.size())return ESP_FAIL;std::memcpy(out,it->second.data(),it->second.size());}
 *size=it->second.size();return 0;
}
inline int nvs_get_str(int h,const char *key,char *out,size_t *size){return nvs_get_blob(h,key,out,size);}
inline int nvs_set_blob(int,const char *key,const void *data,size_t size){
 if(fail_write)return ESP_FAIL;auto *p=static_cast<const char *>(data);blobs[key]={p,p+size};return 0;
}
'''
        source = r'''
#include "configuration.cpp"
#include <cassert>
using namespace board;
int main(){
 Configuration original;original.revision=10;
 Layer layer;layer.id=7;layer.name="Sample";layer.native=false;
 for(auto &b:layer.bindings)b.kind=Kind::Disabled;
 original.layers.push_back(layer);
 auto old=pack7(original);old[0]=6;
 blobs["snapshot6"]={old.begin(),old.end()};
 ConfigStore store;store.load();assert(store.writable());assert(store.current().revision==10);
 assert(store.current().layers[1].id==7);
 auto config=store.current();unsigned usages[]={233,234,226,205,182,181};
 for(unsigned i=0;i<6;++i){config.layers[1].bindings[i]={Kind::Media,uint8_t(usages[i])};}
 auto *json=encode_config(config);Configuration decoded;
 assert(decode_config(json,decoded));cJSON_Delete(json);
 for(unsigned i=0;i<6;++i)assert(decoded.resolve(7,i).usage==usages[i]);
 for(unsigned bad:{0U,4U,115U,180U,235U,256U}){
   json=encode_config(config);auto *b=cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(json,"layers"),1),"bindings"),0);
   cJSON_SetNumberValue(cJSON_GetObjectItemCaseSensitive(b,"usage"),bad);
   assert(!decode_config(json,decoded));cJSON_Delete(json);
 }
 for(auto field:{"modifiers","source"}){
   json=encode_config(config);auto *b=cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(json,"layers"),1),"bindings"),0);
   cJSON_SetNumberValue(cJSON_GetObjectItemCaseSensitive(b,field),1);
   assert(!decode_config(json,decoded));cJSON_Delete(json);
 }
 assert(store.save(config));assert(store.current().revision==11);
 assert(blobs["snapshot6"]==std::vector<char>(old.begin(),old.end()));
 assert(blobs["snapshot7"][0]==7);
 ConfigStore reload;reload.load();assert(reload.writable());
 assert(reload.current().revision==11 && reload.current().resolve(7,0).kind==Kind::Media);
 assert(reload.current().resolve(7,5).usage==181);
 fail_write=true;assert(!reload.save(config));assert(reload.current().revision==11);
 fail_write=false;
 // A corrupt newest snapshot must not silently activate stale settings.
 blobs["snapshot7"].pop_back();ConfigStore corrupt;corrupt.load();assert(!corrupt.writable());
}
'''
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            (root/'nvs.h').write_text(nvs)
            (root/'nvs_flash.h').write_text('#include "nvs.h"\n')
            (root/'test.cpp').write_text(source)
            subprocess.run(['cc','-c',str(cjson/'cJSON.c'),'-o',str(root/'json.o')],check=True)
            subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-I',str(root),'-I',str(cjson),'-I',str(ROOT/'firmware/usb-probe/src'),str(root/'test.cpp'),str(root/'json.o'),'-o',str(root/'test')],check=True)
            subprocess.run([str(root/'test')],check=True)

if __name__=='__main__': unittest.main()
