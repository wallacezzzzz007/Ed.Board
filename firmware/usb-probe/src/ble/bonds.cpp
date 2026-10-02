// SPDX-License-Identifier: MIT
#include "transport.hpp"
#include "host/ble_hs.h"
#include "host/ble_store.h"
#include "store/config/ble_store_config.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"
#include "esp_random.h"
#include <array>
#include <cstring>
extern "C" void ble_store_config_init(void);
#if CONFIG_BT_NIMBLE_STATIC_TO_DYNAMIC
#error "Basic independent bond store requires CONFIG_BT_NIMBLE_STATIC_TO_DYNAMIC disabled"
#endif
namespace aim {
namespace {
struct Entry {int type;ble_store_value value;};
struct Store {uint32_t version=1,count=0;std::array<Entry,16> records{};};
constexpr int stored_types[]={BLE_STORE_OBJ_TYPE_PEER_SEC,BLE_STORE_OBJ_TYPE_OUR_SEC,
    BLE_STORE_OBJ_TYPE_CCCD,BLE_STORE_OBJ_TYPE_LOCAL_IRK,BLE_STORE_OBJ_TYPE_PEER_ADDR,BLE_STORE_OBJ_TYPE_CSFC};
bool allowed(int type) {for(int t:stored_types)if(t==type)return true;return false;}
std::array<uint8_t,16> local_irk{};
int generate_key(uint8_t type,ble_store_gen_key* key,uint16_t) {
    if(type!=BLE_STORE_GEN_KEY_IRK)return BLE_HS_ENOTSUP;
    std::memcpy(key->irk,local_irk.data(),local_irk.size());return 0;
}
int collect(int type,ble_store_value* v,void* ctx) {
    auto& s=*static_cast<Store*>(ctx);
    if(s.count>=s.records.size()) {s.count=unsigned(s.records.size()+1);return BLE_HS_ESTORE_CAP;}
    s.records[s.count++]={type,*v};return 0;
}
int persist() {
    Store s{};
    for(int type:stored_types) {
        int rc=ble_store_iterate(type,collect,&s);if(rc)return rc;
        if(s.count>s.records.size())return BLE_HS_ESTORE_CAP;
    }
    nvs_handle_t h=0;
    if(nvs_open_from_partition("edboard_ble","ble",NVS_READWRITE,&h)!=ESP_OK)return BLE_HS_ESTORE_FAIL;
    esp_err_t e=nvs_set_blob(h,"records",&s,sizeof(s));if(e==ESP_OK)e=nvs_commit(h);nvs_close(h);
    return e==ESP_OK?0:BLE_HS_ESTORE_FAIL;
}
int write(int type,const ble_store_value* v) {int rc=ble_store_config_write(type,v);return rc?rc:persist();}
int remove(int type,const ble_store_key* k) {int rc=ble_store_config_delete(type,k);return rc?rc:persist();}
}
esp_err_t bonds_begin() {
    // 仅初始化独立分区。错误时返回，不使用擦除全部 NVS 的示例兜底。
    esp_err_t e=nvs_flash_init_partition("edboard_ble");if(e!=ESP_OK)return e;
    ble_store_config_init();
    nvs_handle_t h=0;e=nvs_open_from_partition("edboard_ble","ble",NVS_READWRITE,&h);if(e!=ESP_OK)return e;
    size_t irk_size=local_irk.size();e=nvs_get_blob(h,"local_irk",local_irk.data(),&irk_size);
    if(e==ESP_ERR_NVS_NOT_FOUND) {
        esp_fill_random(local_irk.data(),local_irk.size());
        e=nvs_set_blob(h,"local_irk",local_irk.data(),local_irk.size());
        if(e==ESP_OK)e=nvs_commit(h);
    }
    if(e!=ESP_OK||irk_size!=local_irk.size()) {nvs_close(h);return e==ESP_OK?ESP_ERR_INVALID_SIZE:e;}
    Store s{};size_t length=sizeof(s);e=nvs_get_blob(h,"records",&s,&length);nvs_close(h);
    if(e!=ESP_ERR_NVS_NOT_FOUND) {
        if(e!=ESP_OK)return e;
        if(length!=sizeof(s)||s.version!=1||s.count>s.records.size())return ESP_ERR_INVALID_STATE;
        for(unsigned i=0;i<s.count;++i) {
            const auto& r=s.records[i];
            if(!allowed(r.type))return ESP_ERR_INVALID_STATE;
            if(ble_store_config_write(r.type,&r.value))return ESP_FAIL;
        }
    }
    ble_hs_cfg.store_read_cb=ble_store_config_read;ble_hs_cfg.store_write_cb=write;ble_hs_cfg.store_delete_cb=remove;
    ble_hs_cfg.store_gen_key_cb=generate_key;
    return ESP_OK;
}
}
