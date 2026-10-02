#include <array>
// Ed.Board USB Codex integration. Vendor protocol/animation attribution: vendor/LICENSE.
#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "cJSON.h"
#include "esp_app_desc.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "esp_sleep.h"
#include "esp_attr.h"
#include "esp_system.h"
#include "soc/rtc_cntl_reg.h"
#include "soc/soc.h"
#include "driver/rtc_io.h"
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "tinyusb.h"
#include "tusb_cdc_acm.h"
#include "lights.hpp"
#include "inputs.hpp"
#include "management.hpp"
#include "ble/transport.hpp"
#include "vendor/protocol.hpp"

namespace {
std::atomic<bool> updateBaud{false}, downloadRequested{false};
static_assert(CFG_TUD_HID_EP_BUFSIZE >= 64, "Codex reports require 64-byte HID buffers");
constexpr uint8_t kReportId = 6;
constexpr size_t kBodySize = 63, kChunkSize = 61, kMessageSize = 4096;
const uint8_t kReportDescriptor[] = {
    0x06, 0x00, 0xff, 0x09, 0x01, 0xa1, 0x01, 0x85, kReportId,
    0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, kBodySize,
    0x09, 0x01, 0x81, 0x02, 0x95, kBodySize, 0x09, 0x02, 0x91, 0x02, 0xc0,
    0x05,0x01,0x09,0x06,0xA1,0x01,0x85,0x01,
    0x05,0x07,0x19,0xE0,0x29,0xE7,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x08,0x81,0x02,
    0x95,0x01,0x75,0x08,0x81,0x01,
    0x95,0x06,0x75,0x08,0x15,0x00,0x26,0xA4,0x00,0x19,0x00,0x2A,0xA4,0x00,0x81,0x00,0xC0
};
const tusb_desc_device_t kDevice = {
    .bLength = sizeof(tusb_desc_device_t), .bDescriptorType = TUSB_DESC_DEVICE,
    .bcdUSB = 0x0200, .bDeviceClass = TUSB_CLASS_MISC,
    .bDeviceSubClass = MISC_SUBCLASS_COMMON, .bDeviceProtocol = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0 = 64, .idVendor = 0x303a, .idProduct = 0x8360,
    .bcdDevice = 0x0100, .iManufacturer = 1, .iProduct = 2,
    .iSerialNumber = 3, .bNumConfigurations = 1
};
// HID first; CDC uses its own two interfaces and endpoint addresses.
const uint8_t kConfiguration[] = {
    TUD_CONFIG_DESCRIPTOR(1, 3, 0, TUD_CONFIG_DESC_LEN + TUD_HID_INOUT_DESC_LEN + TUD_CDC_DESC_LEN, 0, 100),
    TUD_HID_INOUT_DESCRIPTOR(0, 4, HID_ITF_PROTOCOL_NONE, sizeof(kReportDescriptor), 0x01, 0x81, 64, 1),
    TUD_CDC_DESCRIPTOR(1, 5, 0x82, 8, 0x03, 0x83, 64)
};
char serial[24];
const char *strings[] = {"\x09\x04", "Work Louder", "Codex Micro", serial, "Codex HID", "Ed.Board management"};
struct Packet { uint32_t epoch; uint8_t length; uint8_t data[kChunkSize]; };
QueueHandle_t rxQueue;
std::atomic<uint32_t> epoch{0}, received{0}, rejected{0}, dropped{0};
std::atomic<bool> mounted{false};
// The selected HID link is independent of the USB CDC management connection.
std::atomic<unsigned> activeLink{0}; // 0 offline, 1 USB, 2 BLE
esp_err_t bleError=ESP_ERR_INVALID_STATE;
bool pairingTouchConsumed=false;
int64_t touchStarted=0;
bool usbDataReady() {return mounted.load()&&tud_mounted()&&!tud_suspended();}
bool inputLinkReady() {return activeLink.load()==1 ? usbDataReady() : activeLink.load()==2&&aim::ble_ready();}

uint32_t messages = 0, replies = 0, txFailures = 0, logDrops = 0;
uint32_t versions = 0, statuses = 0, unsupported = 0, parseErrors = 0;
uint32_t rgbQueries=0,agentQueries=0,inputSent=0,resyncs=0,rpcErrors=0;
bool armed=false,needsSync=true,lightFault=false;
aim::Protocol protocol("0.3.1-usb.3");
board::Management management;
// Retained only across deep sleep. No NVS writes for idle/wake cycles.
struct SleepMemory { uint32_t magic, revision, manual, count; };
RTC_DATA_ATTR SleepMemory sleepMemory{};
constexpr uint32_t sleepMagic=0x45444234;

uint32_t traceCursor=0,traceReaderEpoch=0;
bool traceReaderPresent=false;
uint32_t keyboardSent=0;
constexpr const char *keyNames[]={"AG00","AG01","AG02","AG03","AG04","AG05","ACT06","ACT07","ACT08","ACT09","ACT10","ACT11","ACT12","ENC"};


// Called only by app_main. No waits inside TinyUSB callbacks and no host task text.
bool logLine(const char *format, ...) {
    char line[512];
    int prefix = snprintf(line, sizeof(line), "edboard ms=%lld ", (long long)(esp_timer_get_time() / 1000));
    va_list args;
    va_start(args, format);
    vsnprintf(line + prefix, sizeof(line) - prefix - 3, format, args);
    va_end(args);
    size_t n = strlen(line);
    line[n++] = '\r'; line[n++] = '\n';
    // One CDC writer; reserve enough FIFO room for the whole line. DTR may be off in PIO monitor.
    if(management.pending() || !mounted.load() || tud_suspended() || !tud_mounted() || tud_cdc_n_write_available(0)<n) {++logDrops;return false;}
    size_t written = tinyusb_cdcacm_write_queue(TINYUSB_CDC_ACM_0, reinterpret_cast<uint8_t *>(line), n);
    if (written != n) ++logDrops;
    (void)tinyusb_cdcacm_write_flush(TINYUSB_CDC_ACM_0, 0);
    return written==n;
}

bool sendMessage(const char *json, uint32_t session) {
    size_t length = strlen(json);
    // Include a newline even though RX also accepts complete objects without one.
    for (size_t offset = 0; offset < length + 1;) {
        uint8_t body[kBodySize] = {2, 0};
        size_t count = std::min(kChunkSize, length + 1 - offset);
        body[1] = static_cast<uint8_t>(count);
        for (size_t i = 0; i < count; ++i)
            body[i + 2] = offset + i < length ? json[offset + i] : '\n';
        int64_t deadline = esp_timer_get_time() + 500000;
        if(activeLink.load()==2) {
            while(!aim::ble_report(kReportId,body,sizeof(body))) {
                if(!inputLinkReady()||epoch.load()!=session||esp_timer_get_time()>=deadline)return false;
                vTaskDelay(1);
            }
            if(epoch.load()!=session)return false;
            offset+=count;continue;
        }
        while (!tud_hid_n_ready(0)) {
            if (!usbDataReady() || epoch.load() != session || esp_timer_get_time() >= deadline) return false;
            vTaskDelay(1);
        }
        if (!usbDataReady() || epoch.load() != session || !tud_hid_n_report(0, kReportId, body, sizeof(body))) return false;
        offset += count;
    }
    return true; // Enqueued to USB; does not prove the host accepted the reply.
}

std::string deviceStatus() {
    const auto state=input_snapshot();
    cJSON *j=cJSON_CreateObject();
    cJSON_AddStringToObject(j,"version",esp_app_get_description()->version);
    cJSON_AddNumberToObject(j,"profile_index",0);cJSON_AddNumberToObject(j,"layer_index",0);
    cJSON_AddBoolToObject(j,"battery_valid",state.battery_valid);
    if(state.battery_valid){cJSON_AddNumberToObject(j,"battery",state.battery_percent);cJSON_AddBoolToObject(j,"is_charging",state.charging);}
    cJSON_AddNumberToObject(j,"battery_mv",state.battery_mv);
    cJSON_AddBoolToObject(j,"inputs_ready",state.ready&&!state.fault);
    if(!j)return "{}";
    char *out=cJSON_PrintUnformatted(j);std::string text=out?out:"{}";cJSON_free(out);cJSON_Delete(j);return text;
}

void handleMessage(char *text, uint32_t session) {
    cJSON *request=cJSON_Parse(text);
    const cJSON *method=cJSON_GetObjectItemCaseSensitive(request,"method");
    char name[80]="invalid";
    if(cJSON_IsString(method)) {
        size_t n=std::min(strlen(method->valuestring),sizeof(name)-1);
        for(size_t i=0;i<n;++i) {
            char c=method->valuestring[i];
            name[i]=((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='.'||c=='_')?c:'?';
        }
        name[n]=0;
    }
    ++messages;
    bool version=!strcmp(name,"sys.version"),status=!strcmp(name,"device.status");
    bool rgb=!strcmp(name,"v.oai.rgbcfg"),agent=!strcmp(name,"v.oai.thstatus");
    versions+=version;statuses+=status;rgbQueries+=rgb;agentQueries+=agent;
    unsupported+=!(version||status||rgb||agent);
    // Vendor handler applies a validated batch atomically and returns result:true for lighting.
    auto previous=protocol.lights;
    std::string reply=protocol.request(text);
    cJSON *response=reply.empty()?nullptr:cJSON_Parse(reply.c_str());
    const cJSON *error=cJSON_GetObjectItemCaseSensitive(response,"error");
    bool failed=error!=nullptr || protocol.last_error!=0;
    if((rgb||agent)&&!failed) {
        esp_err_t result=lightFault?ESP_FAIL:render_lights(protocol.lights,esp_timer_get_time()/1000,inputLinkReady(),management.store.current(),bleError==ESP_OK&&aim::ble_pairing(),management.power.sleeping());
        if(result!=ESP_OK) {
            lightFault=true;protocol.lights=previous;failed=true;
            if(response) {
                cJSON_DeleteItemFromObjectCaseSensitive(response,"result");
                auto *e=cJSON_AddObjectToObject(response,"error");
                cJSON_AddNumberToObject(e,"code",-32603);cJSON_AddStringToObject(e,"message","Lighting output failed");
                char *encoded=cJSON_PrintUnformatted(response);reply=encoded?encoded:"";cJSON_free(encoded);
            }
        }
    }
    rpcErrors+=failed;
    if(!failed&&rgb)logLine("event=rgb ambient=%06lx brightness=%.3f effect=%u commands=%06lx brightness=%.3f effect=%u",
        (unsigned long)protocol.lights.ambient.rgb,protocol.lights.ambient.brightness,unsigned(protocol.lights.ambient.effect),
        (unsigned long)protocol.lights.commands.rgb,protocol.lights.commands.brightness,unsigned(protocol.lights.commands.effect));
    if(!failed&&agent)for(unsigned i=0;i<6;++i){const auto &light=protocol.lights.agents[i];
        logLine("event=agent slot=%u color=%06lx brightness=%.3f effect=%u",i,(unsigned long)light.rgb,light.brightness,unsigned(light.effect));}

    bool sent=false;
    if(!reply.empty()){sent=sendMessage(reply.c_str(),session);if(sent)++replies;else{++txFailures;needsSync=true;armed=false;}}
    logLine("event=request method=%s error=%d code=%d notification=%d tx_queued=%d light_fault=%d",name,failed,protocol.last_error?protocol.last_error:(failed?-32603:0),reply.empty(),sent,lightFault);
    cJSON_Delete(response);cJSON_Delete(request);
}

bool sendInput(const std::string &json,uint32_t session) {
    if(!json.empty()&&sendMessage(json.c_str(),session)){++inputSent;return true;}
    ++txFailures;needsSync=true;armed=false;return false;
}
std::string encoderStep(bool clockwise) {
    // Codex detents are step events (act=2), not held key presses.
    return clockwise ? R"({"method":"v.oai.hid","params":{"k":"ENC_CW","act":2}})"
                     : R"({"method":"v.oai.hid","params":{"k":"ENC_CC","act":2}})";
}
std::array<board::Binding,board::control_count> heldShortcuts{};
std::array<bool,board::control_count> shortcutDown{};
int previousDirection=0;
int quickCandidate=0;
bool quickCompleted=false;
bool quickCancelled=false, knobPending=false, knobHeld=false;
int64_t knobStarted=0;
void resetCustomGestures() { quickCandidate=0; quickCancelled=false; knobPending=false; knobHeld=false; set_preview_cancelled(false); }

bool sendKeyboard(uint32_t session) {
    uint8_t codes[6]{},mods=0;unsigned count=0;bool seen[256]{};
    for(size_t i=0;i<board::control_count;++i)if(shortcutDown[i]) {
        const auto b=heldShortcuts[i];mods|=b.modifiers;
        auto add=[&](unsigned key){if(key>=224&&key<=231){mods|=1U<<(key-224);return;}if(key&&!seen[key]){seen[key]=true;if(count<6)codes[count]=key;++count;}};
        if(b.key_count)for(unsigned k=0;k<b.key_count;++k)add(b.keys[k]);else add(b.usage);
    }
    if(count>6)for(auto &code:codes)code=1; // HID ErrorRollOver, released keys remain tracked.
    const int64_t deadline=esp_timer_get_time()+500000;
    if(activeLink.load()==2) {
        uint8_t report[8]={mods,0};memcpy(report+2,codes,6);
        bool ok=false;
        while(inputLinkReady()&&epoch.load()==session&&esp_timer_get_time()<deadline) {
            if(aim::ble_report(1,report,sizeof(report))){ok=true;break;}vTaskDelay(1);
        }
        if(ok)++keyboardSent;else{++txFailures;armed=false;needsSync=true;}
        return ok;
    }
    while(!tud_hid_n_ready(0)) {
        if(!usbDataReady()||epoch.load()!=session||esp_timer_get_time()>=deadline) {
            ++txFailures;armed=false;needsSync=true;return false;
        }
        vTaskDelay(1);
    }
    bool ok=usbDataReady()&&epoch.load()==session&&tud_hid_n_keyboard_report(0,1,mods,codes);
    if(ok)++keyboardSent;else{++txFailures;armed=false;needsSync=true;}
    return ok;
}
bool customInput(unsigned control,board::Binding binding,bool down,uint32_t session) {
    if(board::is_host(binding.kind)) {
        if(down)management.trigger_host(control,binding);
        return true;
    }
    if(binding.kind==board::Kind::Disabled||binding.kind==board::Kind::Cancel||!inputLinkReady())return true;
    heldShortcuts[control]=binding;shortcutDown[control]=down;
    bool ok=sendKeyboard(session);
    logLine("event=custom_key control=%u down=%d tx_queued=%d layer=%u revision=%lu",control,down,ok,
        management.store.current().active().id,(unsigned long)management.store.current().revision);
    return ok;
}
board::Binding bindingFor(unsigned control) {
    const auto &config=management.store.current();return config.resolve(config.active().id,control);
}
bool pulseControl(unsigned control, uint32_t session) {
    auto b = bindingFor(control);
    if (b.kind == board::Kind::Native || b.kind == board::Kind::Cancel) { return true; }
    return customInput(control, b, true, session) && customInput(control, b, false, session);
}
bool stickInput(int direction,bool down,uint32_t session) {
    if(!direction)return true;
    const unsigned control=15+direction;auto binding=bindingFor(control);
    if(binding.kind!=board::Kind::Native)return customInput(control,binding,down,session);
    if(!inputLinkReady())return true;
    const float angles[]={0,0.75f,0,0.25f,0.5f};
    return sendInput(aim::Protocol::radial(down?angles[direction]:0,down?1:0),session);
}
bool releaseAll(uint32_t session) {
    // Re-establish a released state before accepting fresh physical presses.
    shortcutDown.fill(false);previousDirection=0;resetCustomGestures();
    if(!sendKeyboard(session))return false;
    for(int i=0;i<14;++i)if(!sendInput(aim::Protocol::key(keyNames[i],false,i<6?i:-1),session))return false;
    if(!sendInput(aim::Protocol::radial(0,0),session))return false;
    ++resyncs;return true;
}
bool cancelPairingFromKey() {
    if(!aim::ble_cancel_pairing())return false;
    pairingTouchConsumed=true;touchStarted=0;
    // Discard the cancelling gesture including repeats/release. Re-arm only
    // after all controls are released, and resync any old host state first.
    armed=false;needsSync=true;clear_inputs();
    management.power.activity(esp_timer_get_time());
    logLine("event=ble_pair_cancel source=key");
    return true;
}
void processInputs(uint32_t session) {
    quickCompleted=false;
    static bool touchSuppressed = false;
    auto state=input_snapshot();
    if(state.touched && management.automatic_active())touchSuppressed=true;
    // Local layer selection must also work without a usable HID host. Host
    // input is discarded below; link/epoch changes still require release/resync.
    const bool linkReady=inputLinkReady();
    if (needsSync || !linkReady) { resetCustomGestures(); }
    if(needsSync&&linkReady) {
        armed=false;clear_inputs();
        if(!releaseAll(session))return;
        needsSync=false;
        logLine("event=input_resync count=%lu",(unsigned long)resyncs);
    }
    if(!state.ready||state.fault) {resetCustomGestures();armed=false;clear_inputs();return;}
    if(!armed) {
        clear_inputs();
        if(!state.keys&&!state.direction&&!state.quick_direction&&!state.touched){armed=true;logLine("event=inputs_armed");}
        return;
    }
    const uint32_t dropsBefore=input_drops();
    InputEvent event;
    for(int count=0;count<16&&next_input(event);++count) {
        if(event.epoch!=session)continue;
        if(event.kind==InputKind::Key||event.kind==InputKind::Encoder||event.kind==InputKind::Stick||event.kind==InputKind::QuickStick||event.kind==InputKind::Touch)
            {management.power.activity(esp_timer_get_time());note_light_input(event,esp_timer_get_time()/1000);}
        if(epoch.load()!=session||input_snapshot().fault||input_drops()!=dropsBefore){needsSync=true;armed=false;break;}
        if(event.kind==InputKind::Key&&event.down&&cancelPairingFromKey())return;

        bool ok=true,dispatched=true;
        switch(event.kind) {
        case InputKind::Key: {
            if(event.value<0||event.value>=14){ok=false;needsSync=true;armed=false;break;}
            if (event.value == 13 && management.store.current().active().id != 1) {
                if (!linkReady) { resetCustomGestures(); break; }
                if (event.down) { knobPending=true; knobHeld=false; knobStarted=esp_timer_get_time(); }
                else if (knobPending) {
                    if (!knobHeld) { ok=pulseControl(esp_timer_get_time()-knobStarted>=600000 ? 20 : 13,session); }
                    knobPending=false;
                }
                break;
            }
            auto binding=bindingFor(event.value);
            if(binding.kind!=board::Kind::Native){dispatched=binding.kind==board::Kind::Shortcut;ok=customInput(event.value,binding,event.down,session);}
            else if(linkReady)ok=sendInput(aim::Protocol::key(keyNames[event.value],event.down,event.value<6?event.value:-1),session);
            break;
        }
        case InputKind::Encoder: {
            if(std::abs(event.value)>32){needsSync=true;armed=false;ok=false;break;}
            unsigned control=event.value<0?14:15;auto binding=bindingFor(control);
            dispatched=binding.kind!=board::Kind::Disabled;
            for(int i=0;i<std::abs(event.value)&&ok;++i) {
                if(binding.kind==board::Kind::Native){if(linkReady)ok=sendInput(encoderStep(event.value<0),session);}
                else {ok=customInput(control,binding,true,session);if(ok)ok=customInput(control,binding,false,session);}
            }
            logLine("event=encoder_step control=%u steps=%d tx_queued=%d",control,std::abs(event.value),ok&&dispatched);
            break;
        }
        case InputKind::QuickStick: {
            if (management.store.current().active().id == 1 || !linkReady) { dispatched=false; break; }
            constexpr unsigned controls[] = {0,16,21,17,22,18,23,19,24};
            if (event.value < 0 || event.value > 8) { needsSync=true; armed=false; ok=false; break; }
            if (event.value) {
                // The last stable direction wins, including entering or leaving Cancel.
                quickCandidate = controls[event.value];
                quickCancelled = bindingFor(quickCandidate).kind == board::Kind::Cancel;
                set_preview_cancelled(quickCancelled);
                dispatched=false;
            } else {
                if (!quickCancelled && quickCandidate) { ok=pulseControl(quickCandidate,session); }
                quickCompleted=true;
                quickCandidate=0;quickCancelled=false;set_preview_cancelled(false);
            }
            break;
        }
        case InputKind::Stick: {
            if (management.store.current().active().id != 1) { dispatched=false; break; }
            if(event.value<0||event.value>4){ok=false;needsSync=true;armed=false;break;}
            if(previousDirection!=event.value){ok=stickInput(previousDirection,false,session);if(ok)ok=stickInput(event.value,true,session);previousDirection=event.value;}
            break;
        }
        case InputKind::Touch:
            if(pairingTouchConsumed) {
                if(!event.down){pairingTouchConsumed=false;touchSuppressed=false;}
                break;
            }
            if(event.down) {
                touchSuppressed=management.automatic_active();
                break;
            }
            // A touch begun under automatic matching is ignored even if focus
            // leaves the application before release. Never accumulate fallback steps.
            if(touchSuppressed||management.automatic_active()) {
                touchSuppressed=false;
                logLine("event=touch_layer_skipped reason=automatic_match manual=%u",management.store.current().manual_layer);
                break;
            }
            // Switch on release only. Ignore a tap while another control is held.
            if(!event.down&&management.prepare_change&&management.prepare_change()) {
                const auto &config=management.store.current();size_t index=0;
                for(size_t i=0;i<config.layers.size();++i)if(config.layers[i].id==config.manual_layer)index=i;
                management.select_manual(config.layers[(index+1)%config.layers.size()].id);
                management.finish_change();
                logLine("event=layer_select source=touch layer=%u",management.store.current().active().id);
                return;
            }
            if(!event.down) {
                auto blocked=input_snapshot();
                logLine("event=touch_layer_skipped keys=%u direction=%d touched=%d ready=%d fault=%d",
                    unsigned(blocked.keys),blocked.direction,blocked.touched,blocked.ready,blocked.fault);
            }
            break;
        case InputKind::Fault: needsSync=true;armed=false;ok=false;break;
        case InputKind::Ready: break;
        }
        logLine("event=input kind=%d value=%d down=%d tx_queued=%d",int(event.kind),event.value,event.down,
                ok&&dispatched&&event.kind!=InputKind::Touch&&event.kind!=InputKind::Ready);
        if(!ok)break;
    }
    if (armed && !needsSync && inputLinkReady() && epoch.load()==session && knobPending && !knobHeld &&
        (input_snapshot().keys & (1U<<13)) && esp_timer_get_time()-knobStarted>=600000) {
        knobHeld=true;
        if (!pulseControl(20,session)) { needsSync=true;armed=false; }
    }
}

void updateQuickOverlay() {
    const auto state=input_snapshot();const auto &config=management.store.current();
    management.quick_overlay.update(armed&&!needsSync&&inputLinkReady()&&state.ready&&!state.fault&&config.active().id!=1,
        state.preview_x,state.preview_y,quickCandidate,quickCompleted,config.active().id,config.revision);
}

// Stateful object framing tolerates fragment boundaries inside JSON strings.
struct Assembly {
    char data[kMessageSize + 1]{};
    size_t size = 0; int depth = 0; bool quoted = false, escaped = false, discarding = false;
    char closing[16]{};
    int64_t lastByte = 0;
    void clear() { size = 0; depth = 0; quoted = false; escaped = false; discarding = false; lastByte = 0; }
    void push(uint8_t c, uint32_t session) {
        if (discarding) { lastByte = esp_timer_get_time(); if (c == '\n') clear(); return; }
        if (!size) {
            if (c == '\r' || c == '\n' || c == ' ' || c == '\t') return;
            if (c != '{') { ++parseErrors; return; }
        }
        if (size == kMessageSize || c == 0) { ++parseErrors; clear(); discarding = true; lastByte = esp_timer_get_time(); return; }
        data[size++] = static_cast<char>(c); lastByte = esp_timer_get_time();
        if (quoted) {
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') quoted = false;
        } else {
            if (c == '"') quoted = true;
            else if (c == '{' || c == '[') {
                if(depth==16){++parseErrors;clear();discarding=true;lastByte=esp_timer_get_time();return;}
                closing[depth++]=c=='{'?'}':']';
            } else if (c == '}' || c == ']') {
                if(!depth||closing[depth-1]!=c){++parseErrors;clear();discarding=true;lastByte=esp_timer_get_time();return;}
                --depth;
            }
        }
        if (depth > 16) { ++parseErrors; clear(); discarding = true; lastByte = esp_timer_get_time(); return; }
        if (!quoted && depth <= 0) {
            data[size] = 0;
            handleMessage(data, session);
            clear();
        }
    }
};
} // namespace

extern "C" const uint8_t *tud_hid_descriptor_report_cb(uint8_t instance) {
    return instance == 0 ? kReportDescriptor : nullptr;
}
extern "C" uint16_t tud_hid_get_report_cb(uint8_t, uint8_t, hid_report_type_t, uint8_t *, uint16_t) {
    return 0; // No feature report in the protocol; replies use interrupt IN.
}
extern "C" void tud_hid_set_report_cb(uint8_t instance, uint8_t id, hid_report_type_t type,
                                      const uint8_t *buffer, uint16_t length) {
    // Interrupt OUT may include ID in data with id=0; control SET_REPORT supplies id separately.
    if (instance != 0 || type != HID_REPORT_TYPE_OUTPUT) { ++rejected; return; }
    // Standard keyboard LED output belongs to report1, not the Codex JSON channel.
    if((id==1&&length==1)||(id==0&&length==2&&buffer[0]==1))return;
    if (length == 64 && buffer[0] == kReportId && (id == 0 || id == kReportId)) {
        ++buffer; --length; id = kReportId;
    }
    if (id != kReportId || length != kBodySize || buffer[0] != 2 || buffer[1] > kChunkSize) {
        ++rejected; return;
    }
    Packet packet{}; packet.epoch = epoch.load(); packet.length = buffer[1];
    memcpy(packet.data, buffer + 2, packet.length);
    ++received;
    if (xQueueSend(rxQueue, &packet, 0) != pdTRUE) ++dropped;
}
bool receiveBle(aim::Link,const uint8_t *buffer,size_t length) {
    if(activeLink.load()!=2){aim::ble_trace("rx_wrong_link",activeLink.load(),length);return false;}
    if(length!=kBodySize||buffer[0]!=2||buffer[1]>kChunkSize){++rejected;return false;}
    Packet packet{};packet.epoch=epoch.load();packet.length=buffer[1];
    memcpy(packet.data,buffer+2,packet.length);++received;
    if(xQueueSend(rxQueue,&packet,0)!=pdTRUE){++dropped;return false;}return true;
}
extern "C" void tud_mount_cb() { ++epoch; mounted.store(true); aim::ble_trace("usb_mount"); }
extern "C" void tud_umount_cb() { mounted.store(false); ++epoch; aim::ble_trace("usb_unmount"); }
extern "C" void tud_suspend_cb(bool) {mounted.store(false);++epoch;aim::ble_trace("usb_suspend");}
extern "C" void tud_resume_cb() {++epoch;mounted.store(true);aim::ble_trace("usb_resume");}
uint32_t usb_epoch() {return epoch.load();}

extern "C" void app_main() {
    const bool deepWake=esp_reset_reason()==ESP_RST_DEEPSLEEP&&esp_sleep_get_wakeup_cause()==ESP_SLEEP_WAKEUP_EXT0;
    ESP_ERROR_CHECK(rtc_gpio_deinit(GPIO_NUM_11));
    rxQueue = xQueueCreate(80, sizeof(Packet));
    configASSERT(rxQueue);
    uint8_t mac[6]; ESP_ERROR_CHECK(esp_read_mac(mac, ESP_MAC_WIFI_STA));
    snprintf(serial, sizeof(serial), "CM3-%02X%02X%02X%02X%02X%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    management.initialize(serial);
    unsigned restoredLayer=0,wakeCount=0;
    if(deepWake&&sleepMemory.magic==sleepMagic) {
        wakeCount=sleepMemory.count+1;
        if(sleepMemory.revision==management.store.current().revision&&management.store.select(sleepMemory.manual)) {
            restoredLayer=sleepMemory.manual;management.store.activate(restoredLayer);
        }
    }
    sleepMemory={0,0,0,wakeCount};
    management.power.recordWake(deepWake,restoredLayer,wakeCount);
    management.diagnostic_reader=[] {traceCursor=0;traceReaderEpoch=epoch.load();traceReaderPresent=true;};
    management.prepare_change=[] {
        auto state=input_snapshot();
        if(!state.ready||state.fault||state.keys||state.direction||state.quick_direction||state.touched)return false;
        armed=false;needsSync=true;clear_inputs();
        if(inputLinkReady()&&!releaseAll(epoch.load()))return false;
        return true;
    };
    management.finish_change=[] {armed=false;needsSync=true;clear_inputs();};
    // USB initialization first; application input calibration starts after CDC is available.
    tinyusb_config_t config{};
    config.device_descriptor = &kDevice;
    config.string_descriptor = strings;
    config.string_descriptor_count = sizeof(strings) / sizeof(strings[0]);
    config.configuration_descriptor = kConfiguration;
    ESP_ERROR_CHECK(tinyusb_driver_install(&config));
    tinyusb_config_cdcacm_t cdc{};
    cdc.usb_dev = TINYUSB_USBDEV_0;
    cdc.cdc_port = TINYUSB_CDC_ACM_0;
    cdc.callback_line_coding_changed = [](int, cdcacm_event_t *event) {
        updateBaud.store(event->line_coding_changed_data.p_line_coding->bit_rate == 1200);
    };
    cdc.callback_line_state_changed = [](int, cdcacm_event_t *event) {
        if (updateBaud.load() && !event->line_state_changed_data.dtr) downloadRequested.store(true);
    };
    ESP_ERROR_CHECK(tusb_cdc_acm_init(&cdc));
    start_lights();
    start_inputs();
    bleError=aim::ble_begin(receiveBle);
    aim::ble_trace("power_wake",deepWake,restoredLayer,wakeCount);
    protocol.status=deviceStatus;
    static Assembly assembly;
    uint32_t lastEpoch = epoch.load(), lastDrop = 0, lastRejected = 0;
    int64_t nextHeartbeat = 0, nextIdentity = 0, nextFrame=0;
    uint32_t lastInputDrop=0;bool lastFault=false;
    uint32_t lastBleGeneration=0;
    bool wasTouched=false;uint16_t previousPairKeys=0;
    uint32_t usbAbsentLoops=0,usbSuspendedLoops=0,bleEnabledLoops=0;
    int64_t usbUnavailableSince=0;
    int lastUsbGate=-1;
    unsigned managementLink=0;uint32_t managementEpoch=0,lastManagementGeneration=0,lastManagementUsbEpoch=0;
    for (;;) {
        if (downloadRequested.exchange(false)) {
            if (inputLinkReady()) releaseAll(epoch.load());
            armed = false;
            resetCustomGestures();
            logLine("event=firmware_download requested=usb_1200_dtr");
            vTaskDelay(pdMS_TO_TICKS(80));
            REG_SET_BIT(RTC_CNTL_OPTION1_REG, RTC_CNTL_FORCE_DOWNLOAD_BOOT);
            esp_restart();
        }
        const auto physical=input_snapshot();
        // Covers a press while input dispatch is unarmed (e.g. the long touch
        // is still held or HID is reconnecting). Only new key-down edges cancel.
        const bool cancelledPair=physical.ready&&!physical.fault&&(physical.keys&~previousPairKeys)&&cancelPairingFromKey();
        previousPairKeys=physical.keys;
        if(bleError==ESP_OK)aim::ble_pair_tick();
        const int64_t touchNow=esp_timer_get_time();
        if(physical.ready&&!physical.fault) {
            if(physical.touched&&!wasTouched&&!cancelledPair){touchStarted=touchNow;pairingTouchConsumed=false;}
            if(physical.touched&&touchStarted&&!pairingTouchConsumed&&touchNow-touchStarted>=3000000) {
                pairingTouchConsumed=true;
                if(bleError==ESP_OK){aim::ble_pair();logLine("event=ble_pair_window seconds=60 bonds=%u",aim::ble_bonds());}
            }
            if(!physical.touched)touchStarted=0;
            wasTouched=physical.touched;
        }
        // Release the old BLE host before USB takes ownership; no held action
        // is replayed on the new link. Physical release is required to re-arm.
        if(activeLink.load()==2&&usbDataReady()&&aim::ble_ready())releaseAll(epoch.load());
        if(!tud_mounted())++usbAbsentLoops;
        if(tud_suspended())++usbSuspendedLoops;
        // Battery-backed USB can remain enumerated after cable removal and only
        // deliver SUSPEND. Use the mount/resume vs suspend/unmount callback state,
        // with a short grace interval. Enumeration can also clear without an
        // unmount callback, so neither cached state alone proves USB is usable.
        const bool callbackMounted=mounted.load(),suspended=tud_suspended(),enumerated=tud_mounted();
        const int usbGate=(callbackMounted?1:0)|(suspended?2:0)|(enumerated?4:0);
        if(usbGate!=lastUsbGate){aim::ble_trace("usb_gate",callbackMounted,suspended,enumerated);lastUsbGate=usbGate;}
        const bool usbUsable=callbackMounted&&enumerated&&!suspended;
        if(usbUsable)usbUnavailableSince=0;
        else if(!usbUnavailableSince)usbUnavailableSince=touchNow;
        const bool allowBleFallback=!usbUsable&&touchNow-usbUnavailableSince>=500000;
        if(bleError==ESP_OK) {
            const bool enableBle=aim::ble_pairing()||(allowBleFallback&&aim::ble_bonds()>0);
            if(enableBle)++bleEnabledLoops;
            aim::ble_enable(enableBle);
            if(physical.battery_valid)aim::ble_battery(physical.battery_percent);
        }
        const unsigned nextLink=usbUsable?1:(allowBleFallback&&bleError==ESP_OK&&aim::ble_ready()?2:0);
        const uint32_t generation=bleError==ESP_OK?aim::ble_generation():0;
        if(nextLink!=activeLink.load()||(nextLink==2&&generation!=lastBleGeneration)) {
            aim::ble_trace("active_link",activeLink.load(),nextLink);
            activeLink=nextLink;++epoch;
            logLine("event=active_link link=%u",nextLink);
        }
        lastBleGeneration=generation;
        uint32_t current = epoch.load(), loss = dropped.load(), bad = rejected.load();
        if (current != lastEpoch || loss != lastDrop || bad != lastRejected) {
            assembly.clear();
            if(current!=lastEpoch) {protocol.lights={};armed=false;needsSync=true;clear_inputs();}
            // Lost fragments must never be assembled into a different request.
            if (loss != lastDrop || bad != lastRejected) xQueueReset(rxQueue);
            logLine("event=transport_reset mounted=%d epoch=%lu dropped=%lu rejected=%lu", mounted.load(),
                    (unsigned long)current, (unsigned long)loss, (unsigned long)bad);
            lastEpoch = current; lastDrop = loss; lastRejected = bad;
        }
        Packet packet;
        if (xQueueReceive(rxQueue, &packet, pdMS_TO_TICKS(20)) == pdTRUE && packet.epoch == lastEpoch) {
            for (size_t i = 0; i < packet.length; ++i) assembly.push(packet.data[i], packet.epoch);
        }
        int64_t now = esp_timer_get_time();
        auto state=input_snapshot();
        if(input_drops()!=lastInputDrop || (state.fault&&!lastFault)) {
            lastInputDrop=input_drops();lastFault=state.fault;armed=false;needsSync=true;
            logLine("event=input_fault dropped=%lu sensor_fault=%d",(unsigned long)lastInputDrop,state.fault);
        }
        const unsigned nextManagementLink=usbDataReady()?1:(aim::ble_management_ready()?2:0);
        const auto mg=aim::ble_management_generation();
        if(nextManagementLink!=managementLink||(nextManagementLink==2&&mg!=lastManagementGeneration)
           ||(nextManagementLink==1&&epoch.load()!=lastManagementUsbEpoch)) {
            managementLink=nextManagementLink;++managementEpoch;
            aim::ble_trace("management_link",managementLink);
        }
        lastManagementGeneration=mg;lastManagementUsbEpoch=epoch.load();
        management.tick(managementEpoch,managementLink!=0,managementLink==2);
        processInputs(epoch.load());
        updateQuickOverlay();
        management.power.tick(now,usbDataReady()||state.charging||state.full,
            !state.ready||state.fault||state.keys||state.direction||state.quick_direction||state.touched,aim::ble_pairing());
        if(management.power.deepDue()&&!management.pending()&&!lightFault) {
            // Require a final settled/released snapshot before shutting down.
            vTaskDelay(pdMS_TO_TICKS(60));
            processInputs(epoch.load());
            updateQuickOverlay();
            const auto finalState=input_snapshot();
            management.power.tick(esp_timer_get_time(),usbDataReady()||finalState.charging||finalState.full,
                !finalState.ready||finalState.fault||finalState.keys||finalState.direction||finalState.quick_direction||finalState.touched,aim::ble_pairing());
            if(!management.power.deepDue()||usbDataReady()||finalState.charging||finalState.full||!finalState.ready||finalState.fault
               ||finalState.keys||finalState.direction||finalState.quick_direction||finalState.touched||!gpio_get_level(GPIO_NUM_11)) {
                management.power.activity(esp_timer_get_time());
            } else {
                armed=false;needsSync=true;clear_inputs();
                if(inputLinkReady())releaseAll(epoch.load());
                // EXT0 keeps RTC IO pull-up powered; no touch/timer wake source.
                ESP_ERROR_CHECK(esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL));
                ESP_ERROR_CHECK(esp_sleep_enable_ext0_wakeup(GPIO_NUM_11,0));
                ESP_ERROR_CHECK(rtc_gpio_pullup_en(GPIO_NUM_11));
                ESP_ERROR_CHECK(rtc_gpio_pulldown_dis(GPIO_NUM_11));
                ESP_ERROR_CHECK(prepare_lights_for_sleep());
                ESP_ERROR_CHECK(aim::ble_stop_for_sleep());
                const auto &saved=management.store.current();
                sleepMemory={sleepMagic,saved.revision,saved.manual_layer,wakeCount};
                esp_deep_sleep_start();
            }
        }
        static bool previousSleeping=false;
        if(previousSleeping!=management.power.sleeping()) {
            previousSleeping=management.power.sleeping();
            logLine("event=power_lights sleeping=%d",previousSleeping);
        }
        // Replay retained history only after a device.info reader handshake.
        // Never remove records on CDC queue success; a reconnect can replay them.
        if(traceReaderPresent&&traceReaderEpoch==epoch.load()&&mounted.load()&&!tud_suspended()
           &&tud_mounted()&&!management.pending()&&tud_cdc_n_write_available(0)>=512) {
            aim::BleTrace entry;
            if(aim::ble_trace_after(traceCursor,entry)&&logLine("event=ble_trace seq=%lu at_ms=%lu kind=%s a=%d b=%d c=%d lost=%lu",
                (unsigned long)entry.sequence,(unsigned long)entry.ms,entry.event,entry.a,entry.b,entry.c,
                (unsigned long)aim::ble_trace_drops()))traceCursor=entry.sequence;
        }

        if(now>=nextFrame&&!lightFault) {
            nextFrame=now+33000;
            esp_err_t error=render_lights(protocol.lights,now/1000,inputLinkReady(),management.store.current(),bleError==ESP_OK&&aim::ble_pairing(),management.power.sleeping());
            if(error!=ESP_OK){lightFault=true;logLine("event=light_error code=%d",int(error));}
        }
        if ((assembly.size || assembly.discarding) && now - assembly.lastByte > 2000000) { assembly.clear(); ++parseErrors; logLine("event=rx_timeout"); }
        if (now >= nextIdentity) {
            nextIdentity = now + 30000000;
            const auto *app = esp_app_get_description();
            char sha[65];
            for (int i = 0; i < 32; ++i) snprintf(sha + i * 2, 3, "%02x", app->app_elf_sha256[i]);
            logLine("event=identity version=%s serial=%s elf_sha256=%s inputs=mixed_layers touch=layer_cycle", app->version, serial, sha);
        }
        if (now >= nextHeartbeat) {
            nextHeartbeat = now + 5000000;
            if(bleError==ESP_OK) {
                const auto d=aim::ble_diagnostics();
                logLine("event=ble_reconnect directed_starts=%lu",(unsigned long)aim::ble_directed_starts());
                logLine("event=ble_diag enabled=%d advertising=%d encrypted=%d key_notify=%d vendor_notify=%d adv_starts=%lu connects=%lu disconnects=%lu encryptions=%lu subscriptions=%lu repeats=%lu adv_rc=%d connect_rc=%d security_start_rc=%d mtu_start_rc=%d last_mtu=%d usb_absent_loops=%lu usb_suspended_loops=%lu ble_enabled_loops=%lu",
                    d.enabled,d.advertising,d.encrypted,d.keyboard_notify,d.vendor_notify,
                    (unsigned long)d.adv_starts,(unsigned long)d.connects,(unsigned long)d.disconnects,
                    (unsigned long)d.encryptions,(unsigned long)d.subscriptions,(unsigned long)d.repeats,
                    d.adv_status,d.connect_status,d.security_start_status,d.mtu_start_status,d.mtu,
                    (unsigned long)usbAbsentLoops,(unsigned long)usbSuspendedLoops,(unsigned long)bleEnabledLoops);
            }
            logLine("event=ble init=%s connected=%d ready=%d pairing=%d bonds=%u security=%d disconnect=%d link=%u",
                esp_err_to_name(bleError),bleError==ESP_OK&&aim::ble_connected(),bleError==ESP_OK&&aim::ble_ready(),
                bleError==ESP_OK&&aim::ble_pairing(),bleError==ESP_OK?aim::ble_bonds():0,
                bleError==ESP_OK?aim::ble_security_status():0,bleError==ESP_OK?aim::ble_disconnect_reason():0,activeLink.load());
            logLine("event=host_actions dropped=%lu",(unsigned long)management.host_drops);
            logLine("event=config revision=%lu layer=%u storage_ok=%d storage_error=%s keyboard_tx=%lu management_errors=%lu management_last_error=%s",
                (unsigned long)management.store.current().revision,unsigned(management.store.current().active().id),
                management.store.writable(),management.store.error().c_str(),(unsigned long)keyboardSent,(unsigned long)management.errors,management.last_error);
            logLine("event=heartbeat version=%s mounted=%d epoch=%lu rx=%lu messages=%lu replies=%lu version_queries=%lu status_queries=%lu unsupported=%lu rejected=%lu dropped=%lu parse_errors=%lu tx_failures=%lu log_drops=%lu",
                    esp_app_get_description()->version, mounted.load(), (unsigned long)epoch.load(),
                    (unsigned long)received.load(), (unsigned long)messages, (unsigned long)replies,
                    (unsigned long)versions, (unsigned long)statuses, (unsigned long)unsupported,
                    (unsigned long)rejected.load(), (unsigned long)dropped.load(), (unsigned long)parseErrors,
                    (unsigned long)txFailures, (unsigned long)logDrops);
            // Repeat latched diagnostics so a host connecting after startup still receives the cause.
            if(state.fault && state.fault_reason==2) logLine("event=input_fault_detail reason=calibration_failed x=%d y=%d touch=%lu x_span=%d y_span=%d touch_span=%lu",
                state.fault_x,state.fault_y,(unsigned long)state.fault_touch,
                state.fault_x_span,state.fault_y_span,(unsigned long)state.fault_touch_span);
            else if(state.fault) logLine("event=input_fault_detail reason=sensor_read_failed adc_x_error=%d adc_y_error=%d touch_error=%d raw_touch=%lu",
                state.fault_x,state.fault_y,state.fault_x_span,(unsigned long)state.fault_touch);
            logLine("event=state ready=%d fault=%d armed=%d input_tx=%lu input_drops=%lu resyncs=%lu rgb=%lu agents=%lu rpc_errors=%lu light_fault=%d battery_valid=%d battery_mv=%d battery_percent=%d charging=%d full=%d",
                state.ready,state.fault,armed,(unsigned long)inputSent,(unsigned long)input_drops(),(unsigned long)resyncs,
                (unsigned long)rgbQueries,(unsigned long)agentQueries,(unsigned long)rpcErrors,lightFault,
                state.battery_valid,state.battery_mv,state.battery_percent,state.charging,state.full);
        }
    }
}
