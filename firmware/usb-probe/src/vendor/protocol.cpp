// SPDX-License-Identifier: MIT
#include "protocol.hpp"
#include "cJSON.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
namespace aim {
void Framer::reset() { text.clear(); depth=0; quoted=escaped=discard=false; last_ms=0; }
void Framer::feed(const uint8_t* b,size_t n,int64_t now,const Message& complete) {
    if(!b || n<2 || b[0]!=2 || b[1]>fragment_size || n<size_t(b[1])+2) { ++errors; reset(); return; }
    if(depth && now-last_ms>1000) { ++errors; reset(); }
    last_ms=now;
    for(size_t i=2;i<size_t(b[1])+2;++i) {
        char c=char(b[i]);
        if(discard) { if(c=='\n') reset(); continue; }
        if(!depth) {
            if(c==' '||c=='\r'||c=='\n'||c=='\t') continue;
            if(c!='{') { ++errors; discard=true; continue; }
        }
        if(text.size()>=json_limit || c==0) { ++errors; reset(); discard=true; continue; }
        text+=c;
        if(quoted) { if(escaped) escaped=false; else if(c=='\\') escaped=true; else if(c=='"') quoted=false; }
        else if(c=='"') quoted=true;
        else if(c=='{' || c=='[') {
            if(depth==closing.size()) { ++errors; reset(); discard=true; continue; }
            closing[depth++]=(c=='{'?'}':']');
        } else if(c=='}'||c==']') {
            if(!depth || closing[depth-1]!=c) { ++errors; reset(); discard=true; continue; }
            if(--depth==0) { std::string finished=std::move(text); reset(); complete(finished); }
        }
    }
    if(depth)last_ms=now;
}
bool send_fragments(const std::string& json,const std::function<bool(const uint8_t*,size_t)>& send) {
    if(json.empty()||json.size()>json_limit) return false;
    std::string wire=json+"\n";
    for(size_t offset=0;offset<wire.size();offset+=fragment_size) {
        std::array<uint8_t,report_size> b{};
        b[0]=2; b[1]=uint8_t(std::min(fragment_size,wire.size()-offset));
        std::memcpy(b.data()+2,wire.data()+offset,b[1]);
        if(!send(b.data(),b.size())) return false;
    }
    return true;
}
namespace {
using Json=std::unique_ptr<cJSON,decltype(&cJSON_Delete)>;
std::string encode(const cJSON* j) { char* p=cJSON_PrintUnformatted(j); if(!p)return {}; std::string s(p); cJSON_free(p); return s; }
bool number(const cJSON* j,double low,double high) { return cJSON_IsNumber(j)&&std::isfinite(j->valuedouble)&&j->valuedouble>=low&&j->valuedouble<=high; }
bool parse_light(const cJSON* obj,Light& light) {
    if(!cJSON_IsObject(obj)) return false;
    const cJSON* v=cJSON_GetObjectItemCaseSensitive(obj,"c");
    if(v) { if(!number(v,0,0xffffff)||std::floor(v->valuedouble)!=v->valuedouble)return false; light.rgb=uint32_t(v->valuedouble); }
    v=cJSON_GetObjectItemCaseSensitive(obj,"b");
    if(v) { if(!number(v,0,1))return false; light.brightness=float(v->valuedouble); }
    v=cJSON_GetObjectItemCaseSensitive(obj,"s");
    if(v) { if(!number(v,0,1))return false; light.speed=float(v->valuedouble); }
    v=cJSON_GetObjectItemCaseSensitive(obj,"e");
    if(v) {
        if(number(v,0,6)&&std::floor(v->valuedouble)==v->valuedouble) light.effect=uint8_t(v->valueint);
        else if(cJSON_IsString(v)) {
            const char* names[]={"off","solid","snake","rainbow","breath","gradient","shallowBreath"};
            bool found=false;
            for(int i=0;i<7;++i) if(std::strcmp(v->valuestring,names[i])==0) { light.effect=uint8_t(i); found=true; }
            if(!found)return false;
        } else return false;
    }
    return true;
}
}
std::string Protocol::request(const std::string& text) {
    last_error=0;
    const char* end=nullptr;
    Json input(cJSON_ParseWithLengthOpts(text.c_str(),text.size()+1,&end,true),cJSON_Delete);
    Json reply(cJSON_CreateObject(),cJSON_Delete);
    const cJSON* id=input?cJSON_GetObjectItemCaseSensitive(input.get(),"id"):nullptr;
    const bool notification=input&&cJSON_IsObject(input.get())&&!id;
    auto error=[&](int code,const char* message) {
        last_error=code;
        if(notification)return std::string{};
        cJSON_AddItemToObject(reply.get(),"id",id?cJSON_Duplicate(id,true):cJSON_CreateNull());
        cJSON* e=cJSON_AddObjectToObject(reply.get(),"error");
        cJSON_AddNumberToObject(e,"code",code);cJSON_AddStringToObject(e,"message",message);
        return encode(reply.get());
    };
    if(text.size()>json_limit||!input)return error(-32700,"Parse error");
    const cJSON* m=cJSON_GetObjectItemCaseSensitive(input.get(),"method");
    if(!cJSON_IsObject(input.get())||!cJSON_IsString(m)|| (id&&!cJSON_IsNumber(id)&&!cJSON_IsString(id)&&!cJSON_IsNull(id)))return error(-32600,"Invalid request");
    const cJSON* p=cJSON_GetObjectItemCaseSensitive(input.get(),"params");
    cJSON* result=nullptr;
    if(std::strcmp(m->valuestring,"sys.version")==0) { result=cJSON_CreateObject();cJSON_AddStringToObject(result,"version",version_.c_str()); }
    else if(std::strcmp(m->valuestring,"device.status")==0) { std::string s=status?status():"{}";result=cJSON_Parse(s.c_str()); }
    else if(std::strcmp(m->valuestring,"v.oai.thstatus")==0) {
        if(!cJSON_IsArray(p)||cJSON_GetArraySize(p)>6)return error(-32602,"Expected up to six light slots");
        Lights next=lights; unsigned seen=0;
        const cJSON* item=nullptr;
        cJSON_ArrayForEach(item,p) {
            const cJSON* slot=cJSON_GetObjectItemCaseSensitive(item,"id");
            if(!number(slot,0,5)||std::floor(slot->valuedouble)!=slot->valuedouble)return error(-32602,"Invalid slot");
            unsigned bit=1U<<slot->valueint;
            if((seen&bit)||!parse_light(item,next.agents[slot->valueint]))return error(-32602,"Invalid light");
            seen|=bit;
        }
        lights=next; result=cJSON_CreateBool(true);
    } else if(std::strcmp(m->valuestring,"v.oai.rgbcfg")==0) {
        if(!cJSON_IsObject(p))return error(-32602,"Expected light configuration");
        Lights next=lights;
        const cJSON* a=cJSON_GetObjectItemCaseSensitive(p,"ambient");
        const cJSON* k=cJSON_GetObjectItemCaseSensitive(p,"keys");
        if(!a&&!k)return error(-32602,"Expected ambient or keys");
        if((a&&!parse_light(a,next.ambient))||(k&&!parse_light(k,next.commands)))return error(-32602,"Invalid light");
        lights=next; result=cJSON_CreateBool(true);
    } else return error(-32601,"Method not found");
    if(!result)return error(-32603,"Internal error");
    if(notification) { cJSON_Delete(result); return {}; }
    cJSON_AddItemToObject(reply.get(),"id",cJSON_Duplicate(id,true));
    cJSON_AddItemToObject(reply.get(),"result",result);
    return encode(reply.get());
}
std::string Protocol::key(const char* pos,bool down,int agent) {
    Json j(cJSON_CreateObject(),cJSON_Delete);cJSON_AddStringToObject(j.get(),"method","v.oai.hid");
    cJSON* p=cJSON_AddObjectToObject(j.get(),"params");cJSON_AddStringToObject(p,"k",pos);cJSON_AddNumberToObject(p,"act",down?1:0);
    if(agent>=0&&agent<6)cJSON_AddNumberToObject(p,"ag",agent);
    return encode(j.get());
}
std::string Protocol::radial(float degrees,float distance) {
    Json j(cJSON_CreateObject(),cJSON_Delete);cJSON_AddStringToObject(j.get(),"method","v.oai.rad");
    cJSON* p=cJSON_AddObjectToObject(j.get(),"params");cJSON_AddNumberToObject(p,"a",degrees);cJSON_AddNumberToObject(p,"d",distance);
    return encode(j.get());
}
}
