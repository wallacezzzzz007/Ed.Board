// SPDX-License-Identifier: MIT
#include "transport.hpp"
#include "hid.hpp"
#include "esp_mac.h"
#include "esp_timer.h"
#include "esp_app_desc.h"
#include "freertos/FreeRTOS.h"
#include "freertos/portmacro.h"
#include "esp_log.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_store.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include <atomic>
#include <cstring>
#include <algorithm>
namespace aim {
namespace {
portMUX_TYPE trace_lock=portMUX_INITIALIZER_UNLOCKED;
BleTrace trace_entries[96]{};
unsigned trace_head=0,trace_count=0;
uint32_t trace_sequence=0,trace_lost=0;
Receive receiver=nullptr;
std::atomic<bool> enabled{false},connected{false},secure{false},subscribed{false},keyboard_subscribed{false};
std::atomic<unsigned> bond_count{0};
std::atomic<int> security_status{0},disconnect_reason{0};
std::atomic<int> advertise_status{0};
std::atomic<uint16_t> handle{BLE_HS_CONN_HANDLE_NONE};
std::atomic<uint8_t> battery{0};
bool synced=false;
ble_npl_event control_event{};
std::atomic<int> clear_status{-2}; // -2 idle, -1 pending, 0 completed, positive error
std::atomic<bool> initialized{false};
uint32_t pair_ready_since=0; // app_main only
std::atomic<uint32_t> pair_until{0};
std::atomic<uint32_t> generation{0};
std::atomic<bool> advertising_snapshot{false},pair_restart{false};
std::atomic<uint32_t> directed_starts{0};
bool tried_directed=false; // host-task owned, reset for each enable cycle
std::atomic<uint32_t> adv_starts{0},connect_events{0},disconnect_events{0},encryption_events{0},subscription_events{0},repeat_events{0};
std::atomic<int> connect_status{0},security_start_status{0},mtu_start_status{0},last_mtu{0};
uint16_t keyboard_handle=0,vendor_handle=0,management_handle=0;
std::atomic<bool> management_subscribed{false};
std::atomic<uint32_t> management_generation{0};
portMUX_TYPE management_lock=portMUX_INITIALIZER_UNLOCKED;
uint8_t management_rx[2048]{};
size_t management_head=0,management_count=0;
void reset_management() {
    portENTER_CRITICAL(&management_lock);management_head=management_count=0;portEXIT_CRITICAL(&management_lock);
    ++management_generation;
}
// EDB00001/2/3-7B5A-4C31-9D62-0B6D7F820001, little-endian UUID bytes.
ble_uuid128_t management_uuid=BLE_UUID128_INIT(1,0,0x82,0x7f,0x6d,0x0b,0x62,0x9d,0x31,0x4c,0x5a,0x7b,1,0,0xb0,0xed);
ble_uuid128_t management_rx_uuid=BLE_UUID128_INIT(1,0,0x82,0x7f,0x6d,0x0b,0x62,0x9d,0x31,0x4c,0x5a,0x7b,2,0,0xb0,0xed);
ble_uuid128_t management_tx_uuid=BLE_UUID128_INIT(1,0,0x82,0x7f,0x6d,0x0b,0x62,0x9d,0x31,0x4c,0x5a,0x7b,3,0,0xb0,0xed);
uint8_t protocol_mode=1;
ble_uuid16_t hid_uuid=BLE_UUID16_INIT(0x1812),info_uuid=BLE_UUID16_INIT(0x2A4A),map_uuid=BLE_UUID16_INIT(0x2A4B);
ble_uuid16_t control_uuid=BLE_UUID16_INIT(0x2A4C),report_uuid=BLE_UUID16_INIT(0x2A4D),mode_uuid=BLE_UUID16_INIT(0x2A4E);
ble_uuid16_t ref_uuid=BLE_UUID16_INIT(0x2908),dis_uuid=BLE_UUID16_INIT(0x180A),pnp_uuid=BLE_UUID16_INIT(0x2A50);
ble_uuid16_t manufacturer_uuid=BLE_UUID16_INIT(0x2A29),version_uuid=BLE_UUID16_INIT(0x2A26);
ble_uuid16_t bas_uuid=BLE_UUID16_INIT(0x180F),level_uuid=BLE_UUID16_INIT(0x2A19);
enum Attribute {Info=1,Map,Mode,Control,Keyboard,VendorIn,VendorOut,KeyboardRef,VendorInRef,VendorOutRef,Pnp,Manufacturer,Version,Battery,ManagementIn,ManagementOut};
int append(os_mbuf* om,const void* b,size_t n) {return os_mbuf_append(om,b,n)==0?0:BLE_ATT_ERR_INSUFFICIENT_RES;}
int access(uint16_t,uint16_t,ble_gatt_access_ctxt* ctx,void* argument) {
    auto field=static_cast<Attribute>(reinterpret_cast<uintptr_t>(argument));
    bool reading=ctx->op==BLE_GATT_ACCESS_OP_READ_CHR||ctx->op==BLE_GATT_ACCESS_OP_READ_DSC;
    if(reading) {
        static const uint8_t info[]={0x11,0x01,0,0x02},pnp[]={2,0x3A,0x30,0x60,0x83,1,1};
        static const uint8_t kref[]={1,1},viref[]={6,1},voref[]={6,2};
        static const uint8_t empty[63]{};
        switch(field) {
            case Info:return append(ctx->om,info,sizeof(info));
            case Map:return append(ctx->om,hid_map,sizeof(hid_map));
            case Mode:return append(ctx->om,&protocol_mode,1);
            case Keyboard:return append(ctx->om,empty,8);
            case VendorIn:case VendorOut:return append(ctx->om,empty,63);
            case KeyboardRef:return append(ctx->om,kref,2);
            case VendorInRef:return append(ctx->om,viref,2);
            case VendorOutRef:return append(ctx->om,voref,2);
            case Pnp:return append(ctx->om,pnp,sizeof(pnp));
            case Manufacturer:return append(ctx->om,"CodexMicro",10);
            case Version:return append(ctx->om,esp_app_get_description()->version,std::strlen(esp_app_get_description()->version));
            case Battery:{uint8_t b=battery;return append(ctx->om,&b,1);}
            default:return BLE_ATT_ERR_READ_NOT_PERMITTED;
        }
    }
    if(ctx->op!=BLE_GATT_ACCESS_OP_WRITE_CHR)return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    if(field==ManagementIn) {
        if(!ble_management_ready())return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
        uint8_t data[128];uint16_t size=0;
        if(ble_hs_mbuf_to_flat(ctx->om,data,sizeof(data),&size)||!size)return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        bool accepted=false;
        portENTER_CRITICAL(&management_lock);
        if(size<=sizeof(management_rx)-management_count) {
            for(unsigned i=0;i<size;++i)management_rx[(management_head+management_count+i)%sizeof(management_rx)]=data[i];
            management_count+=size;accepted=true;
        }
        portEXIT_CRITICAL(&management_lock);
        return accepted?0:BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    uint16_t count=0;uint8_t buf[63]{};
    if(ble_hs_mbuf_to_flat(ctx->om,buf,sizeof(buf),&count))return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    if(field==VendorOut) {
        if(!secure)return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
        if(count!=63)return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        return receiver&&receiver(Link::Ble,buf,count)?0:BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if((field==Mode||field==Control)&&count==1&&buf[0]<=1) {
        if(field==Mode&&buf[0]!=1)return BLE_ATT_ERR_VALUE_NOT_ALLOWED; // 只实现 Report 模式
        return 0;
    }
    return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
}
ble_gatt_dsc_def refs[3][2]{};
ble_gatt_chr_def hid_chars[8]{},dis_chars[4]{},bas_chars[2]{};
ble_gatt_chr_def management_chars[3]{};
ble_gatt_svc_def services[5]{};
void characteristic(ble_gatt_chr_def& c,const ble_uuid16_t& uuid,Attribute a,ble_gatt_chr_flags flags,uint16_t* value=nullptr,ble_gatt_dsc_def* descriptors=nullptr) {
    c.uuid=&uuid.u;c.access_cb=access;c.arg=reinterpret_cast<void*>(uintptr_t(a));c.flags=flags;c.val_handle=value;c.descriptors=descriptors;
}
void setup_services() {
    const auto read=BLE_GATT_CHR_F_READ|BLE_GATT_CHR_F_READ_ENC;
    const auto write=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_NO_RSP|BLE_GATT_CHR_F_WRITE_ENC;
    for(unsigned i=0;i<3;++i) {
        refs[i][0].uuid=&ref_uuid.u;refs[i][0].access_cb=access;refs[i][0].att_flags=BLE_ATT_F_READ|BLE_ATT_F_READ_ENC;
        refs[i][0].arg=reinterpret_cast<void*>(uintptr_t(KeyboardRef+i));
    }
    characteristic(hid_chars[0],info_uuid,Info,read);
    characteristic(hid_chars[1],map_uuid,Map,read);
    characteristic(hid_chars[2],mode_uuid,Mode,read|write);
    characteristic(hid_chars[3],control_uuid,Control,BLE_GATT_CHR_F_WRITE_NO_RSP|BLE_GATT_CHR_F_WRITE_ENC);
    characteristic(hid_chars[4],report_uuid,Keyboard,read|BLE_GATT_CHR_F_NOTIFY,&keyboard_handle,refs[0]);
    characteristic(hid_chars[5],report_uuid,VendorIn,read|BLE_GATT_CHR_F_NOTIFY,&vendor_handle,refs[1]);
    characteristic(hid_chars[6],report_uuid,VendorOut,read|write,nullptr,refs[2]);
    characteristic(dis_chars[0],pnp_uuid,Pnp,BLE_GATT_CHR_F_READ);
    characteristic(dis_chars[1],manufacturer_uuid,Manufacturer,BLE_GATT_CHR_F_READ);
    characteristic(dis_chars[2],version_uuid,Version,BLE_GATT_CHR_F_READ);
    characteristic(bas_chars[0],level_uuid,Battery,BLE_GATT_CHR_F_READ);
    services[0].type=BLE_GATT_SVC_TYPE_PRIMARY;services[0].uuid=&hid_uuid.u;services[0].characteristics=hid_chars;
    services[1].type=BLE_GATT_SVC_TYPE_PRIMARY;services[1].uuid=&dis_uuid.u;services[1].characteristics=dis_chars;
    services[2].type=BLE_GATT_SVC_TYPE_PRIMARY;services[2].uuid=&bas_uuid.u;services[2].characteristics=bas_chars;
    // Append after existing services to retain HID characteristic ordering.
    management_chars[0].uuid=&management_rx_uuid.u;management_chars[0].access_cb=access;
    management_chars[0].arg=reinterpret_cast<void*>(uintptr_t(ManagementIn));
    management_chars[0].flags=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_ENC;
    management_chars[1].uuid=&management_tx_uuid.u;management_chars[1].access_cb=access;
    management_chars[1].arg=reinterpret_cast<void*>(uintptr_t(ManagementOut));
    management_chars[1].flags=BLE_GATT_CHR_F_NOTIFY;management_chars[1].val_handle=&management_handle;
    services[3].type=BLE_GATT_SVC_TYPE_PRIMARY;services[3].uuid=&management_uuid.u;services[3].characteristics=management_chars;
}
void refresh_bonds() {ble_addr_t peers[1]{};int count=0;if(!ble_store_util_bonded_peers(peers,&count,1))bond_count=count;}
bool allowed_peer(const ble_gap_conn_desc& desc) {
    if(!bond_count)return ble_pairing();
    ble_addr_t peers[1]{};int count=0;
    return !ble_store_util_bonded_peers(peers,&count,1)&&count==1&&
        (peers[0].type&1)==(desc.peer_id_addr.type&1)&&
        std::memcmp(peers[0].val,desc.peer_id_addr.val,6)==0;
}
int gap(ble_gap_event*,void*);
void advertise() {
    if(!synced||!enabled||connected||clear_status.load()==-1||ble_gap_adv_active())return;
    if(!bond_count && !ble_pairing())return;
    // Give the bonded central a directed reconnection window before ordinary
    // discoverable advertising. Do not delete or change identity/security keys.
    if(bond_count&&!ble_pairing()&&!tried_directed) {
        tried_directed=true;
        ble_addr_t peers[1]{};int count=0;
        if(!ble_store_util_bonded_peers(peers,&count,1)&&count==1) {
            peers[0].type &= 1; // Identity address type -> public/random address type.
            ble_gap_adv_params directed{};
            directed.conn_mode=BLE_GAP_CONN_MODE_DIR;directed.disc_mode=BLE_GAP_DISC_MODE_NON;
            directed.high_duty_cycle=0;directed.itvl_min=32;directed.itvl_max=48;
            int rc=ble_gap_adv_start(BLE_OWN_ADDR_RANDOM,&peers[0],15000,&directed,gap,nullptr);
            ble_trace("adv_directed",rc);
            advertise_status=rc;advertising_snapshot=ble_gap_adv_active();
            if(!rc){++adv_starts;++directed_starts;return;}
            // Unsupported directed parameters still permit normal advertising.
        }
    }
    ble_hs_adv_fields fields{};fields.flags=BLE_HS_ADV_F_DISC_GEN|BLE_HS_ADV_F_BREDR_UNSUP;
    fields.appearance=0x03C1;fields.appearance_is_present=1;
    fields.uuids16=&hid_uuid;fields.num_uuids16=1;fields.uuids16_is_complete=1;
    const char* name="Codex Micro";fields.name=reinterpret_cast<const uint8_t*>(name);fields.name_len=std::strlen(name);fields.name_is_complete=1;
    int fields_rc=ble_gap_adv_set_fields(&fields);
    if(fields_rc) {ble_trace("adv_fields_error",fields_rc);advertise_status=fields_rc;ESP_LOGE("basic_ble","advertising fields failed");return;}
    ble_gap_adv_params params{};params.conn_mode=BLE_GAP_CONN_MODE_UND;params.disc_mode=BLE_GAP_DISC_MODE_GEN;
    int rc=ble_gap_adv_start(BLE_OWN_ADDR_RANDOM,nullptr,BLE_HS_FOREVER,&params,gap,nullptr);
    ble_trace("adv_undirected",rc);
    advertise_status=rc;advertising_snapshot=ble_gap_adv_active();if(!rc)++adv_starts;
    if(rc)ESP_LOGE("basic_ble","advertise: %d",rc);
}
void control(ble_npl_event*) {
    if(!synced)return;
    if(clear_status.load()==-1) {
        if(ble_gap_adv_active())ble_gap_adv_stop();
        advertising_snapshot=false;
        if(connected) {
            int rc=ble_gap_terminate(handle,BLE_ERR_REM_USER_CONN_TERM);
            if(rc)clear_status=rc;
            return; // DISCONNECT queues the remaining clear operation.
        }
        int rc=ble_store_clear();refresh_bonds();
        pair_until=0;tried_directed=false;
        clear_status=rc?rc:(bond_count?BLE_HS_ESTORE_FAIL:0);
        return;
    }
    if(pair_restart.exchange(false)&&ble_gap_adv_active()) {
        ble_gap_adv_stop();advertising_snapshot=false;
        // NimBLE requires stop/start to occur in separate event contexts.
        ble_npl_eventq_put(nimble_port_get_dflt_eventq(),&control_event);return;
    }
    if(!enabled) {
        tried_directed=false;
        if(ble_gap_adv_active())ble_gap_adv_stop();
        advertising_snapshot=ble_gap_adv_active();
        if(connected)ble_gap_terminate(handle,BLE_ERR_REM_USER_CONN_TERM);
    } else advertise();
}
int gap(ble_gap_event* e,void*) {
    switch(e->type) {
        case BLE_GAP_EVENT_CONNECT: {
            ble_trace("connect",e->connect.status);
            ++connect_events;connect_status=e->connect.status;advertising_snapshot=ble_gap_adv_active();
            ble_gap_conn_desc desc{};
            // Captured on this board: ENC_CHANGE and restored SUBSCRIBE can
            // precede CONNECT. A failed CONNECT can still have a descriptor.
            if(ble_gap_conn_find(e->connect.conn_handle,&desc)) {
                ble_npl_eventq_put(nimble_port_get_dflt_eventq(),&control_event);break;
            }
            if(e->connect.status) {ble_gap_terminate(e->connect.conn_handle,BLE_ERR_REM_USER_CONN_TERM);break;}
            // Subscription flags start false and are cleared on DISCONNECT.
            // Do not erase notifications restored before this CONNECT callback.
            ++generation;handle=e->connect.conn_handle;connected=true;
            secure=desc.sec_state.encrypted&&allowed_peer(desc);
            if(!enabled||(!bond_count&&!ble_pairing())) {ble_gap_terminate(handle,BLE_ERR_REM_USER_CONN_TERM);break;}
            if(desc.sec_state.encrypted&&!secure) {
                ble_gap_terminate(handle,BLE_ERR_REM_USER_CONN_TERM);break;
            }
            // Do not restart security after the host already completed it.
            security_start_status=desc.sec_state.encrypted?0:ble_gap_security_initiate(handle);
            ble_trace("connect_state",desc.sec_state.encrypted,keyboard_subscribed.load(),subscribed.load());
            mtu_start_status=ble_gattc_exchange_mtu(handle,nullptr,nullptr);
            ble_trace("security_start",security_start_status.load(),mtu_start_status.load());
            break;
        }
        case BLE_GAP_EVENT_DISCONNECT:
            ble_trace("disconnect",e->disconnect.reason);
            ++disconnect_events;
            ++generation;disconnect_reason=e->disconnect.reason;
            management_subscribed=false;reset_management();
            connected=false;secure=false;subscribed=false;keyboard_subscribed=false;handle=BLE_HS_CONN_HANDLE_NONE;
            if(clear_status.load()==-1)ble_npl_eventq_put(nimble_port_get_dflt_eventq(),&control_event);else advertise();break;
        case BLE_GAP_EVENT_ENC_CHANGE: {
            ++encryption_events;
            security_status=e->enc_change.status;
            ble_gap_conn_desc desc{};
            bool accepted=e->enc_change.status==0&&!ble_gap_conn_find(e->enc_change.conn_handle,&desc)&&desc.sec_state.encrypted;
            // 连接建立时主机可能仍使用临时地址；加密完成后核对解析的绑定身份。
            if(accepted)accepted=allowed_peer(desc);
            ble_trace("encryption",e->enc_change.status,accepted);
            secure=accepted;
            // Encryption is not HID readiness. Keep the pairing window open
            // until both input subscriptions and MTU have settled.
            if(!accepted)ble_gap_terminate(e->enc_change.conn_handle,BLE_ERR_REM_USER_CONN_TERM);
            refresh_bonds();break;
        }
        case BLE_GAP_EVENT_SUBSCRIBE:
            if(e->subscribe.attr_handle==management_handle) {
                management_subscribed=e->subscribe.cur_notify;reset_management();
                ble_trace("management_subscribe",e->subscribe.cur_notify);break;
            }
            ble_trace("subscribe",e->subscribe.attr_handle==keyboard_handle?1:e->subscribe.attr_handle==vendor_handle?6:0,e->subscribe.cur_notify);
            ++subscription_events;
            if(e->subscribe.attr_handle==vendor_handle)subscribed=e->subscribe.cur_notify;
            if(e->subscribe.attr_handle==keyboard_handle)keyboard_subscribed=e->subscribe.cur_notify;
            break;
        case BLE_GAP_EVENT_MTU:ble_trace("mtu",e->mtu.value);last_mtu=e->mtu.value;break;
        case BLE_GAP_EVENT_REPEAT_PAIRING:ble_trace("repeat_pairing");++repeat_events;return BLE_GAP_REPEAT_PAIRING_IGNORE;
        case BLE_GAP_EVENT_ADV_COMPLETE:ble_trace("adv_complete",e->adv_complete.reason);advertising_snapshot=false;advertise();break;
        default:break;
    }
    return 0;
}
void sync() {
    uint8_t mac[6]{};ESP_ERROR_CHECK(esp_read_mac(mac,ESP_MAC_BT));
    uint8_t addr[6];for(int i=0;i<6;++i)addr[i]=mac[5-i];
    addr[0]^=0x42;addr[5]|=0xC0;
    if(ble_hs_id_set_rnd(addr)) {ESP_LOGE("basic_ble","identity failed");return;}
    synced=true;refresh_bonds();advertise();
}
void host(void*) {nimble_port_run();nimble_port_freertos_deinit();}
}
void ble_trace(const char *event,int a,int b,int c) {
    const uint32_t ms=uint32_t(esp_timer_get_time()/1000);
    portENTER_CRITICAL(&trace_lock);
    if(trace_count==96){trace_head=(trace_head+1)%96;--trace_count;++trace_lost;}
    trace_entries[(trace_head+trace_count)%96]={++trace_sequence,ms,event,a,b,c};++trace_count;
    portEXIT_CRITICAL(&trace_lock);
}
// Non-destructive history: queuing CDC bytes does not prove host receipt.
bool ble_trace_after(uint32_t sequence,BleTrace &entry) {
    bool present=false;
    portENTER_CRITICAL(&trace_lock);
    for(unsigned i=0;i<trace_count;++i) {
        const auto &candidate=trace_entries[(trace_head+i)%96];
        if(candidate.sequence>sequence){entry=candidate;present=true;break;}
    }
    portEXIT_CRITICAL(&trace_lock);return present;
}
uint32_t ble_trace_drops() {
    portENTER_CRITICAL(&trace_lock);auto count=trace_lost;portEXIT_CRITICAL(&trace_lock);return count;
}
esp_err_t ble_begin(Receive receive) {
    receiver=receive;esp_err_t err=nimble_port_init();if(err!=ESP_OK)return err;
    ble_svc_gap_init();ble_svc_gatt_init();ble_svc_gap_device_name_set("Codex Micro");ble_svc_gap_device_appearance_set(0x03C1);
    ble_hs_cfg.sync_cb=sync;ble_hs_cfg.sm_io_cap=BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding=1;ble_hs_cfg.sm_sc=1;
    ble_hs_cfg.sm_our_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    err=bonds_begin();if(err!=ESP_OK)return err;
    setup_services();
    if(ble_gatts_count_cfg(services)||ble_gatts_add_svcs(services))return ESP_FAIL;
    ble_att_set_preferred_mtu(128);ble_npl_event_init(&control_event,control,nullptr);
    nimble_port_freertos_init(host);initialized=true;return ESP_OK;
}
// Final shutdown from app_main only; reboot reinitializes this transport.
esp_err_t ble_stop_for_sleep() {
    if(!initialized)return ESP_OK;
    enabled=false;pair_until=0;
    if(nimble_port_stop()!=0)return ESP_FAIL;
    return nimble_port_deinit();
}
void ble_enable(bool value) {if(enabled.exchange(value)!=value){ble_trace("enable",value);ble_npl_eventq_put(nimble_port_get_dflt_eventq(),&control_event);}}
void ble_pair() {pair_restart=true;pair_until=uint32_t(esp_timer_get_time()/1000)+60000;ble_npl_eventq_put(nimble_port_get_dflt_eventq(),&control_event);}
bool ble_cancel_pairing() {
    if(!ble_pairing())return false;
    pair_until=0;pair_ready_since=0;
    // Restart advertising under the normal bond policy; never terminate an
    // established connection or erase a bond merely to close the window.
    pair_restart=true;
    ble_trace("pair_cancel");
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(),&control_event);
    return true;
}
bool ble_pairing() {const uint32_t end=pair_until.load();return end&&int32_t(end-uint32_t(esp_timer_get_time()/1000))>0;}
uint32_t ble_generation() {return generation;}
bool ble_forget() {
    if(!initialized)return false;
    int previous=clear_status.load();
    do {if(previous==-1)return false;} while(!clear_status.compare_exchange_weak(previous,-1));
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(),&control_event);return true;
}
int ble_forget_status() {return clear_status.load();}
bool ble_initialized() {return initialized.load();}
void ble_pair_tick() {
    const uint32_t now=uint32_t(esp_timer_get_time()/1000);
    if(!ble_pairing()||!ble_ready()){pair_ready_since=0;return;}
    if(!pair_ready_since)pair_ready_since=now;
    if(uint32_t(now-pair_ready_since)>=2000){pair_until=0;pair_ready_since=0;}
}
bool ble_connected() {return connected;}
bool ble_ready() {return connected&&secure&&keyboard_subscribed&&subscribed&&ble_att_mtu(handle)>=66;}
unsigned ble_bonds() {return bond_count;}
int ble_security_status() {return security_status;}
int ble_disconnect_reason() {return disconnect_reason;}
bool ble_advertising() {return advertising_snapshot.load();}
int ble_advertise_status() {return advertise_status;}
uint32_t ble_directed_starts() {return directed_starts.load();}
BleDiagnostics ble_diagnostics() {
    return {enabled.load(),advertising_snapshot.load(),secure.load(),keyboard_subscribed.load(),subscribed.load(),
        adv_starts.load(),connect_events.load(),disconnect_events.load(),encryption_events.load(),subscription_events.load(),repeat_events.load(),
        advertise_status.load(),connect_status.load(),security_start_status.load(),mtu_start_status.load(),last_mtu.load()};
}
void ble_battery(uint8_t percent) {battery=percent;}
bool ble_report(uint8_t id,const uint8_t* b,size_t n) {
    if(!enabled||!connected||!secure)return false;
    if(id==6) {if(!connected||!secure||!subscribed||ble_att_mtu(handle)<66||n!=63)return false;}
    else if(id==1) {if(!keyboard_subscribed||n!=8)return false;}
    else return false;
    os_mbuf* packet=ble_hs_mbuf_from_flat(b,n);if(!packet)return false;
    return ble_gatts_notify_custom(handle,id==6?vendor_handle:keyboard_handle,packet)==0;
}
}

namespace aim {
bool ble_management_ready() {return enabled&&connected&&secure&&management_subscribed;}
uint32_t ble_management_generation() {return management_generation.load();}
size_t ble_management_read(uint8_t *data,size_t capacity) {
    portENTER_CRITICAL(&management_lock);
    const size_t n=std::min(capacity,management_count);
    for(size_t i=0;i<n;++i)data[i]=management_rx[(management_head+i)%sizeof(management_rx)];
    management_head=(management_head+n)%sizeof(management_rx);management_count-=n;
    portEXIT_CRITICAL(&management_lock);return n;
}
size_t ble_management_write(const uint8_t *data,size_t length) {
    if(!ble_management_ready())return 0;
    const auto connection=handle.load();const int mtu=ble_att_mtu(connection);
    if(mtu<23)return 0;
    const size_t n=std::min(length,size_t(std::min(mtu-3,128)));
    if(!n)return 0;
    auto *packet=ble_hs_mbuf_from_flat(data,n);if(!packet)return 0;
    return ble_gatts_notify_custom(connection,management_handle,packet)==0?n:0;
}
}
