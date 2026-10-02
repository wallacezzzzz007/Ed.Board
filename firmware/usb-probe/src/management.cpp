#include "management.hpp"
#include <cstring>
#include <algorithm>
#include <cstdio>
#include "esp_app_desc.h"
#include "esp_timer.h"
#include "esp_random.h"
#include "inputs.hpp"
#include "ble/transport.hpp"
#include "tusb.h"
#include "tusb_cdc_acm.h"

namespace board {
void Management::initialize(const char *serial){serial_=serial;store.load();power.load();line_.reserve(frame_bytes);}
cJSON *Management::runtime_json() const {
    auto *r=cJSON_CreateObject();const auto &c=store.current();
    cJSON_AddNumberToObject(r,"manualLayer",c.manual_layer);cJSON_AddNumberToObject(r,"activeLayer",c.active().id);
    cJSON_AddNumberToObject(r,"autoLayer",auto_layer_);cJSON_AddNumberToObject(r,"session",auto_session_);
    cJSON_AddBoolToObject(r,"pending",c.active().id!=(auto_layer_?auto_layer_:c.manual_layer));return r;
}
void Management::reconcile() {
    if(auto_layer_&&(esp_timer_get_time()>=auto_deadline_||!store.current().layer(auto_layer_)))auto_layer_=0;
    unsigned target=auto_layer_?auto_layer_:store.current().manual_layer;
    if(target!=store.current().active().id&&prepare_change&&prepare_change()){
        store.activate(target);if(finish_change)finish_change();
    }
}
bool Management::automatic_active() const {
    return auto_layer_ && esp_timer_get_time() < auto_deadline_;
}
void Management::select_manual(unsigned id) {
    store.select(id);
    if(auto_layer_&&esp_timer_get_time()>=auto_deadline_)auto_layer_=0;
    store.activate(auto_layer_?auto_layer_:store.current().manual_layer);
}
// Bounded diagnostics identify framing failures without printing a full user configuration.
void Management::reject_frame(const char *reason,const std::string &line,int offset) {
    ++errors;last_error=reason;
    auto hex=[](const std::string &text,size_t start,size_t count){
        const char *digits="0123456789abcdef";std::string value;
        for(size_t i=start;i<text.size()&&i<start+count;++i){unsigned char c=text[i];value+=digits[c>>4];value+=digits[c&15];}
        return value;
    };
    char header[180];snprintf(header,sizeof(header),"edboard event=management_reject reason=%s bytes=%u offset=%d head_hex=",reason,unsigned(line.size()),offset);
    out_=header;out_+=hex(line,0,48);out_+=" tail_hex=";out_+=hex(line,line.size()>48?line.size()-48:0,48);out_+='\n';
    tx_deadline_=esp_timer_get_time()+2000000;
}
void Management::respond(uint32_t id,cJSON *result,const char *code) {
    auto *j=cJSON_CreateObject();cJSON_AddNumberToObject(j,"protocol",1);cJSON_AddNumberToObject(j,"id",id);
    if(code){auto *e=cJSON_AddObjectToObject(j,"error");cJSON_AddStringToObject(e,"code",code);cJSON_Delete(result);}
    else cJSON_AddItemToObject(j,"result",result);
    char *encoded=cJSON_PrintUnformatted(j);cJSON_Delete(j);
    if(encoded){char header[128];snprintf(header,sizeof(header),"edboard event=management_request id=%lu bytes=%u result=%s\n",(unsigned long)id,unsigned(request_bytes_),code?code:"ok");out_=header;out_+="@edboard ";out_+=encoded;out_+='\n';cJSON_free(encoded);tx_deadline_=esp_timer_get_time()+2000000;}
    else {++errors;last_error="response_encode_failed";}
}
void Management::dispatch(const std::string &line) {
    constexpr const char *prefix="@edboard ";
    request_bytes_=line.size();
    if(line.compare(0,9,prefix)){reject_frame("bad_prefix",line);return;}
    if(line.find("\\u0000")!=std::string::npos){reject_frame("escaped_nul",line);return;}
    // Bound nesting before cJSON recursion; reject embedded NUL and incomplete JSON.
    int depth=0;bool quoted=false,escaped=false;
    for(size_t i=9;i<line.size();++i){char c=line[i];
        if(!c){reject_frame("embedded_nul",line,int(i));return;}
        if(quoted){if(escaped)escaped=false;else if(c=='\\')escaped=true;else if(c=='"')quoted=false;}
        else if(c=='"')quoted=true;
        else if(c=='{'||c=='['){if(++depth>8){reject_frame("nesting_limit",line,int(i));return;}}
        else if(c=='}'||c==']'){if(--depth<0){reject_frame("unexpected_close",line,int(i));return;}}
    }
    if(depth||quoted){reject_frame("incomplete_json",line);return;}
    const char *end=nullptr;
    auto *j=cJSON_ParseWithOpts(line.c_str()+9,&end,true);
    if(!j){reject_frame("invalid_json",line,end?int(end-line.c_str()):-1);return;}
    auto *id=cJSON_GetObjectItemCaseSensitive(j,"id");
    if(!valid_integer(id,0x7fffffff)||id->valueint==0){reject_frame("invalid_request_id",line);cJSON_Delete(j);return;}
    uint32_t request=uint32_t(id->valuedouble);
    const char *fields[]={"protocol","id","method","params"};
    auto *v=cJSON_GetObjectItemCaseSensitive(j,"protocol");
    auto *method=cJSON_GetObjectItemCaseSensitive(j,"method");
    auto *params=cJSON_GetObjectItemCaseSensitive(j,"params");
    if(!exact_fields(j,fields,4)||!cJSON_IsString(method)||!cJSON_IsObject(params))respond(request,nullptr,"invalid_request");
    else if(!valid_integer(v,1)||v->valueint!=1)respond(request,nullptr,"unsupported_protocol");
    else if(!strcmp(method->valuestring,"joystick.watch")) {
        const char *pf[]={"token","enabled"};
        auto *token=cJSON_GetObjectItemCaseSensitive(params,"token");
        auto *enabled=cJSON_GetObjectItemCaseSensitive(params,"enabled");
        if(!exact_fields(params,pf,2)||!valid_integer(token,0x7fffffff)||token->valueint==0||!cJSON_IsBool(enabled))respond(request,nullptr,"invalid_joystick_watch");
        else {
            quick_token_=cJSON_IsTrue(enabled)?token->valueint:0;
            quick_sequence_=0;quick_initial_=true;quick_sent_at_=0;
            auto *r=cJSON_CreateObject();cJSON_AddBoolToObject(r,"accepted",true);respond(request,r);
        }
    }
    else if(!strcmp(method->valuestring,"preview.watch")) {
        const char *pf[]={"token","enabled"};
        auto *token=cJSON_GetObjectItemCaseSensitive(params,"token");
        auto *enabled=cJSON_GetObjectItemCaseSensitive(params,"enabled");
        if(!exact_fields(params,pf,2)||!valid_integer(token,0x7fffffff)||token->valueint==0||!cJSON_IsBool(enabled))respond(request,nullptr,"invalid_preview");
        else {
            if(preview_token_!=unsigned(token->valueint)) {preview_sequence_=0;preview_sent_=0;take_preview_snapshot();}
            preview_token_=token->valueint;preview_deadline_=cJSON_IsTrue(enabled)?esp_timer_get_time()+5000000:0;
            auto *r=cJSON_CreateObject();cJSON_AddBoolToObject(r,"accepted",true);respond(request,r);
        }
    }
    else if(!strcmp(method->valuestring,"device.info")&&exact_fields(params,nullptr,0)) {
        if(diagnostic_reader)diagnostic_reader();
        auto *r=cJSON_CreateObject();cJSON_AddStringToObject(r,"device","Ed.Board");
        cJSON_AddStringToObject(r,"serial",serial_);cJSON_AddStringToObject(r,"firmware",esp_app_get_description()->version);
        cJSON_AddStringToObject(r,"controlId","board.layers");cJSON_AddNumberToObject(r,"schemaVersion",6);cJSON_AddStringToObject(r,"migrationNote",store.current().migration_note.c_str());cJSON_AddNumberToObject(r,"runtimeVersion",2);cJSON_AddNumberToObject(r,"previewVersion",1);cJSON_AddNumberToObject(r,"joystickVersion",1);cJSON_AddNumberToObject(r,"powerVersion",2);
        cJSON_AddBoolToObject(r,"writable",store.writable());cJSON_AddStringToObject(r,"storageError",store.error().c_str());
        auto state=input_snapshot();cJSON_AddBoolToObject(r,"ready",state.ready&&!state.fault);
        cJSON_AddBoolToObject(r,"batteryValid",state.battery_valid);
        cJSON_AddNumberToObject(r,"battery",state.battery_percent);cJSON_AddBoolToObject(r,"charging",state.charging);cJSON_AddBoolToObject(r,"full",state.full);
        respond(request,r);
    } else if(!strcmp(method->valuestring,"device.status")&&exact_fields(params,nullptr,0)) {
        auto state=input_snapshot();auto *r=cJSON_CreateObject();
        cJSON_AddBoolToObject(r,"batteryValid",state.battery_valid);cJSON_AddNumberToObject(r,"battery",state.battery_percent);
        cJSON_AddBoolToObject(r,"charging",state.charging);cJSON_AddBoolToObject(r,"full",state.full);
        cJSON_AddNumberToObject(r,"bonds",aim::ble_bonds());cJSON_AddBoolToObject(r,"connected",aim::ble_connected());
        cJSON_AddBoolToObject(r,"ready",aim::ble_ready());respond(request,r);
    } else if(!strcmp(method->valuestring,"power.get")&&exact_fields(params,nullptr,0)) {
        respond(request,power.json());
    } else if(!strcmp(method->valuestring,"power.set")||!strcmp(method->valuestring,"power.setSeconds")) {
        const bool seconds=!strcmp(method->valuestring,"power.setSeconds");
        const char *fields[]={"baseRevision",seconds?"idleSeconds":"idleMinutes","enabled","deepMinutes","keepConnected"};
        auto *revision=cJSON_GetObjectItemCaseSensitive(params,"baseRevision");
        auto *idle=cJSON_GetObjectItemCaseSensitive(params,fields[1]);
        auto *enabled=cJSON_GetObjectItemCaseSensitive(params,"enabled");
        auto *deep=cJSON_GetObjectItemCaseSensitive(params,"deepMinutes");
        auto *keep=cJSON_GetObjectItemCaseSensitive(params,"keepConnected");
        if(!exact_fields(params,fields,5)||!valid_integer(deep,1440)||deep->valueint<1||!cJSON_IsBool(keep)||!valid_integer(revision,0x7fffffff)||!valid_integer(idle,seconds?7200:120)||idle->valueint<(seconds?30:1)||!cJSON_IsBool(enabled))
            respond(request,nullptr,"invalid_power_settings");
        else {
            auto error=power.save(idle->valueint*(seconds?1:60),cJSON_IsTrue(enabled),deep->valueint,cJSON_IsTrue(keep),revision->valueint);
            respond(request,error?nullptr:power.json(),error);
        }
    } else if(!strcmp(method->valuestring,"bluetooth.status")&&exact_fields(params,nullptr,0)) {
        auto *r=cJSON_CreateObject();
        cJSON_AddBoolToObject(r,"initialized",aim::ble_initialized());
        cJSON_AddNumberToObject(r,"bonds",aim::ble_bonds());
        cJSON_AddNumberToObject(r,"clearStatus",aim::ble_forget_status());
        cJSON_AddBoolToObject(r,"connected",aim::ble_connected());
        cJSON_AddBoolToObject(r,"ready",aim::ble_ready());
        const auto diagnostic=aim::ble_diagnostics();
        cJSON_AddBoolToObject(r,"encrypted",diagnostic.encrypted);
        cJSON_AddBoolToObject(r,"keyboardNotify",diagnostic.keyboard_notify);
        cJSON_AddBoolToObject(r,"vendorNotify",diagnostic.vendor_notify);
        cJSON_AddNumberToObject(r,"mtu",diagnostic.mtu);
        respond(request,r);
    } else if(!strcmp(method->valuestring,"bluetooth.clear")) {
        const char *f[]={"confirm"};
        if(bluetooth_)respond(request,nullptr,"usb_required");
        else if(!exact_fields(params,f,1)||!cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(params,"confirm")))respond(request,nullptr,"confirmation_required");
        else if(!aim::ble_initialized())respond(request,nullptr,"bluetooth_unavailable");
        else if(!aim::ble_forget())respond(request,nullptr,"bluetooth_busy");
        else {auto *r=cJSON_CreateObject();cJSON_AddBoolToObject(r,"accepted",true);respond(request,r);}
    } else if(!strcmp(method->valuestring,"config.get")&&exact_fields(params,nullptr,0)) {
        auto *r=encode_snapshot(store.current());cJSON_AddBoolToObject(r,"writable",store.writable());
        cJSON_AddStringToObject(r,"storageError",store.error().c_str());respond(request,r);
    } else if(!strcmp(method->valuestring,"runtime.get")&&exact_fields(params,nullptr,0)) {
        reconcile();respond(request,runtime_json());
    } else if(!strcmp(method->valuestring,"runtime.begin")&&exact_fields(params,nullptr,0)) {
        uint32_t previous=auto_session_;
        do {auto_session_=(esp_random()&0x7fffffffU);} while(!auto_session_||auto_session_==previous);
        auto_sequence_=0;host_sequence_=0;host_events_.clear();auto_deadline_=0;auto_layer_=0;reconcile();respond(request,runtime_json());
    } else if(!strcmp(method->valuestring,"runtime.auto")) {
        const char *f[]={"session","sequence","layer","baseRevision"};
        auto *token=cJSON_GetObjectItemCaseSensitive(params,"session");
        auto *sequence=cJSON_GetObjectItemCaseSensitive(params,"sequence");
        auto *layer=cJSON_GetObjectItemCaseSensitive(params,"layer");
        auto *base=cJSON_GetObjectItemCaseSensitive(params,"baseRevision");
        if(!exact_fields(params,f,4)||!valid_integer(token,0x7fffffff)||!valid_integer(sequence,0x7fffffff)||!valid_integer(layer,255)||!valid_integer(base,0x7fffffff))respond(request,nullptr,"invalid_auto");
        else if(!auto_session_||uint32_t(token->valuedouble)!=auto_session_||uint32_t(sequence->valuedouble)<=auto_sequence_)respond(request,nullptr,"stale_auto_session");
        else if(uint32_t(base->valuedouble)!=store.current().revision)respond(request,nullptr,"revision_conflict");
        else if(layer->valueint&&!store.current().layer(layer->valueint))respond(request,nullptr,"invalid_layer");
        else {auto_sequence_=uint32_t(sequence->valuedouble);auto_layer_=layer->valueint;
            auto_deadline_=esp_timer_get_time()+8000000;reconcile();respond(request,runtime_json());}
    } else if(!strcmp(method->valuestring,"runtime.select")) {
        const char *f[]={"layer"};auto *id=cJSON_GetObjectItemCaseSensitive(params,"layer");
        if(!exact_fields(params,f,1)||!valid_integer(id,255)||!store.current().layer(id->valueint))respond(request,nullptr,"invalid_layer");
        else if(input_snapshot().fault)respond(request,nullptr,"input_fault");
        else if(!input_snapshot().ready)respond(request,nullptr,"inputs_not_ready");
        else if(!prepare_change||!prepare_change()) {
            const auto state=input_snapshot();
            respond(request,nullptr,state.fault?"input_fault":!state.ready?"inputs_not_ready":
                (state.keys||state.direction||state.touched)?"inputs_busy":"transport_not_ready");
        }
        else {select_manual(id->valueint);if(finish_change)finish_change();respond(request,runtime_json());}
    } else if(!strcmp(method->valuestring,"config.set")) {
        const char *setFields[]={"baseRevision","config"};Configuration configuration;
        auto *base=cJSON_GetObjectItemCaseSensitive(params,"baseRevision");
        if(!exact_fields(params,setFields,2)||!valid_integer(base,0x7fffffff)||
           !decode_config(cJSON_GetObjectItemCaseSensitive(params,"config"),configuration))respond(request,nullptr,"invalid_config");
        else if(uint32_t(base->valuedouble)!=store.current().revision)respond(request,nullptr,"revision_conflict");
        else if(!store.writable())respond(request,nullptr,"storage_unavailable");
        else if(input_snapshot().fault)respond(request,nullptr,"input_fault");
        else if(!input_snapshot().ready)respond(request,nullptr,"inputs_not_ready");
        else if(!prepare_change||!prepare_change()) {
            const auto state=input_snapshot();
            respond(request,nullptr,state.fault?"input_fault":!state.ready?"inputs_not_ready":
                (state.keys||state.direction||state.touched)?"inputs_busy":"transport_not_ready");
        }
        else {
            bool saved=store.save(configuration);
            if(saved){auto_layer_=0;host_events_.clear();}
            if(finish_change)finish_change();
            if(saved)respond(request,encode_snapshot(store.current()));
            else respond(request,nullptr,"storage_write_failed");
        }
    } else respond(request,nullptr,"unknown_method_or_params");
    cJSON_Delete(j);
}
size_t Management::write_bytes(const uint8_t *data,size_t size) {
    if(bluetooth_) {
        size_t total=0;
        for(unsigned i=0;i<8&&total<size;++i) {
            auto n=aim::ble_management_write(data+total,size-total);if(!n)break;total+=n;
        }
        return total;
    }
    size_t n=tinyusb_cdcacm_write_queue(TINYUSB_CDC_ACM_0,data,std::min(size,size_t(tud_cdc_n_write_available(0))));
    tinyusb_cdcacm_write_flush(TINYUSB_CDC_ACM_0,0);return n;
}
size_t Management::read_bytes(uint8_t *data,size_t size) {
    return bluetooth_?aim::ble_management_read(data,size):tud_cdc_n_read(0,data,size);
}
void Management::trigger_host(unsigned control,Binding binding) {
    const auto now=esp_timer_get_time();
    if(!available_||!auto_session_||now>=auto_deadline_||host_sequence_==0x7fffffff||host_events_.size()>=8){++host_drops;return;}
    char line[320];
    int n=snprintf(line,sizeof(line),"@edboard {\"protocol\":1,\"event\":\"host.action\",\"session\":%lu,\"sequence\":%lu,\"lease\":%lu,\"revision\":%lu,\"layer\":%u,\"control\":%u,\"source\":%lu}\n",
        (unsigned long)auto_session_,(unsigned long)++host_sequence_,(unsigned long)auto_sequence_,
        (unsigned long)store.current().revision,store.current().active().id,control,(unsigned long)binding.source);
    if(n>0&&n<int(sizeof(line)))host_events_.push_back({std::string(line,n),now+500000});
}
void Management::tick(uint32_t epoch,bool mounted,bool bluetooth) {
    bluetooth_=bluetooth;available_=mounted;
    if(epoch_!=epoch||!mounted){epoch_=epoch;quick_token_=0;quick_queued_=false;quick_started_=false;quick_overlay=QuickOverlay{};preview_deadline_=0;preview_token_=0;notified_state_=UINT64_MAX;auto_layer_=0;auto_session_=0;host_events_.clear();store.activate(store.current().manual_layer);line_.clear();out_.clear();discard_=false;rx_size_=rx_offset_=0;tud_cdc_n_read_flush(0);return;}
    reconcile(); // Lease expiration must not wait behind a pending CDC response.
    auto now=esp_timer_get_time();
    // Discard an unsent movement snapshot when the gesture has already ended.
    if(quick_queued_&&!quick_started_&&!quick_overlay.visible&&quick_sent_.visible) {
        out_.clear();quick_queued_=false;quick_initial_=true;
    }
    if(!out_.empty()) {
        size_t available=bluetooth_?1024:tud_cdc_n_write_available(0);
        if(available) {
            size_t count=std::min(available,out_.size());
            auto n=write_bytes(reinterpret_cast<const uint8_t*>(out_.data()),count);
            out_.erase(0,n);
            if(n) {tx_deadline_=now+2000000;if(quick_queued_)quick_started_=true;}
            if(out_.empty())quick_queued_=false;
        }
        if(!out_.empty()&&now>tx_deadline_){
            out_.clear();++errors;last_error="response_write_timeout";
            if(quick_queued_) {
                // Resynchronize a partial line, then retry the latest state, including end.
                out_="\n";tx_deadline_=now+500000;quick_initial_=true;quick_queued_=false;
            }
        }
        return;
    }
    while(!host_events_.empty()) {
        auto event=host_events_.front();host_events_.pop_front();
        if(now>=event.deadline||now>=auto_deadline_){++host_drops;continue;}
        out_=std::move(event.line);tx_deadline_=now+500000;return;
    }
    // Unsolicited state is best-effort and coalesced while no reader drains CDC.
    // Queue the whole line only when it fits; never block request parsing or leave
    // a timed-out notification prefix attached to the next response.
    const auto &config=store.current();unsigned active=config.active().id;
    bool waiting=active!=(auto_layer_?auto_layer_:config.manual_layer);
    uint64_t state=(uint64_t(auto_session_)<<25)|(uint64_t(waiting)<<24)|(auto_layer_<<16)|(active<<8)|config.manual_layer;
    if(notified_state_!=state){
        char message[256];
        int size=snprintf(message,sizeof(message),"@edboard {\"protocol\":1,\"event\":\"runtime\",\"manualLayer\":%u,\"activeLayer\":%u,\"autoLayer\":%u,\"session\":%lu,\"pending\":%s}\n",config.manual_layer,active,auto_layer_,(unsigned long)auto_session_,waiting?"true":"false");
        if(size>0&&size<int(sizeof(message))) {
            if(bluetooth_) {
                out_.assign(message,size);tx_deadline_=now+2000000;notified_state_=state;return;
            }
            if(tud_cdc_n_write_available(0)>=unsigned(size)&&write_bytes(reinterpret_cast<const uint8_t*>(message),size)==unsigned(size))notified_state_=state;
        }
    }
    if((!line_.empty()||discard_)&&now-last_byte_>2000000){reject_frame("receive_idle_timeout",line_);line_.clear();discard_=false;return;}
    // Stop at a complete request: one bounded response slot applies backpressure to RX.
    for(unsigned n=0;n<1024;++n) {
        // Read a block once, rather than rearming the USB OUT endpoint per byte.
        // Preserve unread bytes if a complete request creates response backpressure.
        if(rx_offset_==rx_size_) {
            rx_size_=read_bytes(rx_chunk_,sizeof(rx_chunk_));rx_offset_=0;
            if(!rx_size_)break;
        }
        char c=char(rx_chunk_[rx_offset_++]);last_byte_=now;
        if(c=='\n') {
            if(!line_.empty()&&line_.back()=='\r')line_.pop_back();
            if(!discard_&&!line_.empty())dispatch(line_);
            line_.clear();discard_=false;if(!out_.empty())break;
        } else if(!discard_) {
            if(line_.size()>=frame_bytes){reject_frame("frame_too_large",line_);line_.clear();discard_=true;}
            else line_+=c;
        }
        if(!out_.empty())break;
    }
    // One latest snapshot, no heartbeat. Responses and host actions take priority.
    if(out_.empty() && line_.empty() && !discard_ && quick_token_ &&
       (quick_initial_ || !(quick_overlay==quick_sent_)) &&
       (!quick_overlay.visible || now-quick_sent_at_>=33334)) {
        const auto &q=quick_overlay;
        char message[360];
        int size=snprintf(message,sizeof(message),"@edboard {\"protocol\":1,\"event\":\"joystick\",\"token\":%lu,\"sequence\":%lu,\"gesture\":%lu,\"layer\":%u,\"revision\":%lu,\"visible\":%s,\"x\":%d,\"y\":%d,\"candidate\":%d}\n",
            (unsigned long)quick_token_,(unsigned long)++quick_sequence_,(unsigned long)q.gesture,q.layer,
            (unsigned long)q.revision,q.visible?"true":"false",q.x,q.y,q.candidate);
        if(size>0&&size<int(sizeof(message))) {
            out_.assign(message,size);tx_deadline_=now+500000;
            quick_sent_=q;quick_sent_at_=now;quick_initial_=false;quick_queued_=true;quick_started_=false;return;
        }
    }
    if(out_.empty() && line_.empty() && !discard_ && now < preview_deadline_ && now-preview_checked_ >= 33334) {
        preview_checked_=now;
        auto p=take_preview_snapshot(); bool ready=p.ready&&!p.fault;
        const auto &last=preview_previous_;
        bool changed=p.quick_cancelled!=last.quick_cancelled || p.keys!=last.keys || p.preview_pressed || p.touched!=last.touched || p.ready!=last.ready || p.fault!=last.fault
            || p.preview_x!=last.preview_x || p.preview_y!=last.preview_y || p.preview_left!=last.preview_left
            || p.preview_right!=last.preview_right || p.preview_touch!=last.preview_touch;
        if(!changed && preview_sent_ && now-preview_sent_<500000)return;
        preview_previous_=p;
        char message[420];
        int size=snprintf(message,sizeof(message),"@edboard {\"protocol\":1,\"event\":\"preview\",\"token\":%lu,\"sequence\":%lu,\"keys\":%u,\"pressed\":%u,\"left\":%lu,\"right\":%lu,\"touchCount\":%lu,\"touched\":%s,\"x\":%d,\"y\":%d,\"cancelled\":%s}\n",
            (unsigned long)preview_token_,(unsigned long)++preview_sequence_,ready?p.keys:0,ready?p.preview_pressed:0,
            (unsigned long)p.preview_left,(unsigned long)p.preview_right,(unsigned long)p.preview_touch,ready&&p.touched?"true":"false",ready?p.preview_x:0,ready?p.preview_y:0,ready&&p.quick_cancelled?"true":"false");
        if(size>0&&size<int(sizeof(message))){out_.assign(message,size);tx_deadline_=now+500000;preview_sent_=now;}
    }

}
}
