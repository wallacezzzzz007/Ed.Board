#include "configuration.hpp"
#include <cmath>
#include <cstring>
#include "nvs.h"
#include "nvs_flash.h"
namespace board {
bool valid_integer(const cJSON *v,uint32_t max) {
    return cJSON_IsNumber(v)&&std::isfinite(v->valuedouble)&&v->valuedouble>=0&&v->valuedouble<=max&&std::floor(v->valuedouble)==v->valuedouble;
}
bool exact_fields(const cJSON *j,const char *const *names,size_t count) {
    if(!cJSON_IsObject(j)||size_t(cJSON_GetArraySize(j))!=count)return false;
    for(size_t i=0;i<count;++i){unsigned found=0;for(auto *c=j->child;c;c=c->next)if(c->string&&!strcmp(c->string,names[i]))++found;if(found!=1)return false;}
    return true;
}
const Layer *Configuration::layer(unsigned id) const {for(const auto &l:layers)if(l.id==id)return &l;return nullptr;}
const Layer &Configuration::active() const {auto *l=layer(active_layer);return l?*l:layers.front();}
int Configuration::favorite_index(unsigned id) const {for(size_t i=0;i<favorites.size();++i)if(favorites[i]==id)return int(i);return -1;}
unsigned Configuration::next_favorite(unsigned after) const {if(favorites.empty())return 1;int i=favorite_index(after);return favorites[(i+1)%favorites.size()];}
Binding Configuration::resolve(unsigned id,unsigned control) const {
    if(control>=control_count)return {Kind::Disabled};
    for(size_t n=0;n<max_layers;++n){auto *l=layer(id);if(!l)return {Kind::Disabled};if(l->native||(id==1&&control>=13))return {};
        auto b=l->bindings[control];if(b.kind!=Kind::Inherit)return b;id=b.source;}
    return {Kind::Disabled};
}
static const cJSON *field(const cJSON *j,const char *name){return cJSON_GetObjectItemCaseSensitive(j,name);}
static bool number(const cJSON *j,const char *name,unsigned max){return valid_integer(field(j,name),max);}
static unsigned integer(const cJSON *j,const char *name){return unsigned(field(j,name)->valuedouble);}
static bool decode_light(const cJSON *j,LightSpec &v) {
    if(cJSON_IsNull(j)){v={};return true;}
    if(!cJSON_IsArray(j)||cJSON_GetArraySize(j)!=4)return false;
    for(int i=0;i<4;++i)if(!valid_integer(cJSON_GetArrayItem(j,i),i==0?4:i==1?0xffffff:100))return false;
    v.custom=true;v.effect=cJSON_GetArrayItem(j,0)->valueint;v.color=cJSON_GetArrayItem(j,1)->valueint;
    v.brightness=cJSON_GetArrayItem(j,2)->valueint;v.active=cJSON_GetArrayItem(j,3)->valueint;
    return v.effect!=4||v.active>=v.brightness;
}
static bool decode_binding(const cJSON *j,Binding &out,bool legacy=false,bool allow_host=false,bool extended=false) {
    const char *fields[]={"kind","usage","modifiers","source","keys"};
    bool has_keys=extended&&field(j,"keys");
    if(!exact_fields(j,fields,legacy?3:has_keys?5:4)||!cJSON_IsString(field(j,"kind"))||!number(j,"usage",255)||!number(j,"modifiers",15)||(!legacy&&!number(j,"source",0x7fffffff)))return false;
    Binding b;const char *k=field(j,"kind")->valuestring;
    if(!strcmp(k,"native"))b.kind=Kind::Native;else if(!strcmp(k,"shortcut"))b.kind=Kind::Shortcut;
    else if(!strcmp(k,"disabled"))b.kind=Kind::Disabled;else if(!legacy&&!strcmp(k,"inherit"))b.kind=Kind::Inherit;
    else if(allow_host&&!strcmp(k,"application"))b.kind=Kind::Application;
    else if(allow_host&&!strcmp(k,"open"))b.kind=Kind::Open;
    else if(allow_host&&!strcmp(k,"text"))b.kind=Kind::Text;else if(extended&&!strcmp(k,"media"))b.kind=Kind::Media;else if(extended&&!strcmp(k,"cancel"))b.kind=Kind::Cancel;else return false;
    b.usage=integer(j,"usage");b.modifiers=integer(j,"modifiers");b.source=legacy?0:integer(j,"source");
    if(has_keys) {
        auto *keys=field(j,"keys");int count=cJSON_GetArraySize(keys);bool seen[256]{};unsigned normal=0;
        if(b.kind!=Kind::Shortcut||b.usage||b.modifiers||b.source||!cJSON_IsArray(keys)||count<1||count>14)return false;
        for(int i=0;i<count;++i){auto *v=cJSON_GetArrayItem(keys,i);if(!valid_integer(v,231))return false;unsigned k=v->valueint;
            if(!((k>=4&&k<=164)||(k>=224&&k<=231))||seen[k])return false;
            seen[k]=true;if(k<224)++normal;b.keys[i]=k;}
        if (normal > 6) { return false; }
        b.key_count = count;
    }
    if(b.kind==Kind::Shortcut){if((!b.key_count&&(b.usage<4||b.usage>115))||b.source)return false;}
    else if(b.kind==Kind::Media){if(!media_bit(b.usage)||b.modifiers||b.source||has_keys)return false;}
    else if(is_host(b.kind)){if(b.usage||b.modifiers||!b.source)return false;}
    else if(b.usage||b.modifiers||(b.kind==Kind::Inherit?(!b.source||b.source>255):bool(b.source)))return false;
    out=b;return true;
}
static bool decode_expanded(const cJSON *j,Configuration &out,unsigned legacy_version) {
    const bool legacy_v2=legacy_version==2;
    const char *fields[]={"schemaVersion","layers"};
    const char *oldFields[]={"schemaVersion","defaultLayer","manualLayer","layers"};
    if(!exact_fields(j,legacy_v2?oldFields:fields,legacy_v2?4:2)||!number(j,"schemaVersion",6)||integer(j,"schemaVersion")!=(legacy_version?legacy_version:6U))return false;
    if(legacy_v2&&(!number(j,"defaultLayer",255)||!number(j,"manualLayer",255)))return false;
    auto *array=field(j,"layers");int count=cJSON_GetArraySize(array);
    if(!cJSON_IsArray(array)||count<1||count>int(legacy_v2?4:6))return false;
    Configuration next;next.layers.clear();
    const char *lf[]={"id","name","mode","color","ringColor","brightness","bindings","effects","keyLights"};
    for(auto *l=array->child;l;l=l->next){
        bool effects=(!legacy_version||legacy_version==5)&&field(l,"effects");
        if(!exact_fields(l,lf,effects?9:7)||!number(l,"id",255)||integer(l,"id")==0||!cJSON_IsString(field(l,"name"))||!cJSON_IsString(field(l,"mode"))||!number(l,"color",0xffffff)||!number(l,"ringColor",0xffffff)||!number(l,"brightness",100))return false;
        Layer layer;layer.id=integer(l,"id");layer.name=field(l,"name")->valuestring;
        if(layer.name.empty()||layer.name.size()>48||next.layer(layer.id))return false;
        for(unsigned char c:layer.name)if(c<32||c==127)return false;
        const char *mode=field(l,"mode")->valuestring;
        if(!strcmp(mode,"native"))layer.native=true;else if(!strcmp(mode,"custom"))layer.native=false;else return false;
        if(layer.id!=1&&layer.native)return false;
        layer.color=integer(l,"color");layer.ring_color=integer(l,"ringColor");layer.brightness=integer(l,"brightness");
        auto *bindings=field(l,"bindings");if(!cJSON_IsArray(bindings)||cJSON_GetArraySize(bindings)!=int(legacy_version?20:control_count))return false;
        for(size_t i=0;i<(legacy_version?20:control_count);++i)if(!decode_binding(cJSON_GetArrayItem(bindings,i),layer.bindings[i],false,!legacy_version||legacy_version>=4,!legacy_version||legacy_version==5))return false;
        if(effects){auto *fx=field(l,"effects"),*kl=field(l,"keyLights");
            if(!cJSON_IsArray(fx)||cJSON_GetArraySize(fx)!=5||!cJSON_IsArray(kl)||cJSON_GetArraySize(kl)!=13)return false;
            for(int i=0;i<5;++i){auto *v=cJSON_GetArrayItem(fx,i);if(i==3&&cJSON_IsNumber(v)&&v->valuedouble==-1)layer.effects[i]=-1;
                else {if(!valid_integer(v,i==0?4:i==2?5:100))return false;layer.effects[i]=v->valueint;}}
            if(layer.effects[2]==2||(layer.effects[0]==4&&layer.effects[1]<layer.brightness)||(layer.effects[2]==4&&layer.effects[4]<(layer.effects[3]<0?layer.brightness:layer.effects[3])))return false;
            for(int i=0;i<13;++i)if(!decode_light(cJSON_GetArrayItem(kl,i),layer.key_lights[i]))return false;
        }
        if (legacy_version) {
            for (unsigned i = 20; i < control_count; ++i) { layer.bindings[i] = {Kind::Disabled}; }
            for (unsigned i = 13; i < control_count; ++i) {
                auto &b = layer.bindings[i];
                if (layer.id == 1) { b = {}; }
                else if (b.kind == Kind::Native || (b.kind == Kind::Inherit && b.source == 1)) { b = {Kind::Disabled}; }
            }
            next.migration_note = "Knob and joystick settings were upgraded. Codex controls are managed by Codex; ordinary-layer native controls and Codex links were disabled. Review and save your settings.";
        }
        for (unsigned i = 0; i < control_count; ++i) {
            auto b = layer.bindings[i];
            const bool stick = i >= 16 && i != 20;
            if (b.kind == Kind::Cancel && !stick) { return false; }
            if (i >= 13 && ((layer.id == 1 && b.kind != Kind::Native) ||
                (layer.id != 1 && (b.kind == Kind::Native || (b.kind == Kind::Inherit && b.source == 1))))) { return false; }
        }
        next.layers.push_back(layer);
    }
    if(!next.layer(1))return false;
    if(legacy_v2&&(!next.layer(integer(j,"defaultLayer"))||(integer(j,"manualLayer")&&!next.layer(integer(j,"manualLayer")))))return false;
    next.favorites.clear();for(const auto &l:next.layers)next.favorites.push_back(l.id);
    next.manual_layer=next.active_layer=next.favorites.front();
    // Validate dormant custom plans as well: a mode toggle must not expose a cycle.
    for(const auto &l:next.layers)for(size_t c=0;c<control_count;++c){
        unsigned id=l.id;bool done=false;bool seen[256]{};
        for(size_t n=0;n<max_layers;++n){auto *source=next.layer(id);if(!source||seen[id])return false;seen[id]=true;
            auto b=source->bindings[c];if(b.kind!=Kind::Inherit){done=true;break;}id=b.source;}
        if(!done)return false;
    }
    out=next;return true;
}
// Compact schema 7 / snapshot 8. The high nibble preserves ordered chord length.
static bool valid_utf8(const std::string &text) {
    size_t at=0;
    while(at<text.size()) {
        unsigned lead=uint8_t(text[at++]), count=0, value=0, minimum=0;
        if(lead<128)continue;
        if(lead>=0xc2&&lead<=0xdf){count=1;value=lead&31;minimum=0x80;}
        else if(lead>=0xe0&&lead<=0xef){count=2;value=lead&15;minimum=0x800;}
        else if(lead>=0xf0&&lead<=0xf4){count=3;value=lead&7;minimum=0x10000;}
        else return false;
        if(at+count>text.size())return false;
        while(count--){unsigned ch=uint8_t(text[at++]);if((ch&0xc0)!=0x80)return false;value=(value<<6)|(ch&63);}
        if(value<minimum||value>0x10ffff||(value>=0xd800&&value<=0xdfff))return false;
    }
    return true;
}
static bool valid_config(const Configuration &c) {
    if(c.layers.empty()||c.layers.size()>max_layers||!c.layer(1)||c.favorites.empty()||c.favorites.size()>6)return false;
    bool ids[256]{},favorites[256]{};
    for(auto id:c.favorites){if(!id||!c.layer(id)||favorites[id])return false;favorites[id]=true;}
    for(const auto &l:c.layers){
        if(!l.id||ids[l.id]||l.name.empty()||l.name.size()>48||!valid_utf8(l.name)||(l.id!=1&&l.native)||l.color>0xffffff||l.ring_color>0xffffff||l.brightness>100)return false;
        ids[l.id]=true;for(unsigned char ch:l.name)if(ch<32||ch==127)return false;
        for(unsigned i=0;i<5;++i)if(l.effects[i]<(i==3?-1:0)||l.effects[i]>(i==0?4:i==2?5:100))return false;
        if(l.effects[2]==2||(l.effects[0]==4&&l.effects[1]<l.brightness)||(l.effects[2]==4&&l.effects[4]<(l.effects[3]<0?l.brightness:l.effects[3])))return false;
        for(auto v:l.key_lights)if(v.custom&&(v.effect>4||v.color>0xffffff||v.brightness>100||v.active>100||(v.effect==4&&v.active<v.brightness)))return false;
        for(unsigned i=0;i<control_count;++i){auto b=l.bindings[i];
            if(unsigned(b.kind)>8||b.key_count>14)return false;
            if(b.key_count){
                if(b.kind!=Kind::Shortcut||b.usage||b.modifiers||b.source)return false;
                bool seen[256]{};unsigned normal=0;
                for(unsigned k=0;k<b.key_count;++k){auto key=b.keys[k];if(!((key>=4&&key<=164)||(key>=224&&key<=231))||seen[key])return false;seen[key]=true;if(key<224)++normal;}
                if(normal>6)return false;
            }else if(b.kind==Kind::Shortcut){if(b.usage<4||b.usage>115||b.modifiers>15||b.source)return false;}
            else if(b.kind==Kind::Media){if(!media_bit(b.usage)||b.modifiers||b.source)return false;}
            else if(is_host(b.kind)){if(b.usage||b.modifiers||!b.source||b.source>0x7fffffff)return false;}
            else if(b.usage||b.modifiers||(b.kind==Kind::Inherit?(!b.source||b.source>255):bool(b.source)))return false;
            if(b.kind==Kind::Cancel&&!(i>=16&&i!=20))return false;
            if(i>=13&&((l.id==1&&b.kind!=Kind::Native)||(l.id!=1&&(b.kind==Kind::Native||(b.kind==Kind::Inherit&&b.source==1)))))return false;
            bool seen[256]{};unsigned id=l.id;bool done=false;
            for(size_t depth=0;depth<max_layers;++depth){if(id>255)return false;auto *source=c.layer(id);if(!source||seen[id])return false;seen[id]=true;auto link=source->bindings[i];if(link.kind!=Kind::Inherit){done=true;break;}id=link.source;}
            if(!done)return false;
        }
    }
    return true;
}
static std::vector<uint8_t> pack8(const Configuration &c,bool snapshot=false) {
    std::vector<uint8_t> data;
    auto put=[&](uint32_t n,unsigned bytes=1){for(unsigned i=0;i<bytes;++i)data.push_back((n>>(i*8))&255);};
    put(8);if(snapshot)put(c.revision,4);put(c.layers.size());put(c.favorites.size());for(auto id:c.favorites)put(id);
    for(const auto &l:c.layers){
        put(l.id);put(l.name.size());for(unsigned char ch:l.name)put(ch);
        put(l.native);put(l.color,3);put(l.ring_color,3);put(l.brightness);for(int e:l.effects)put(e<0?255:e);
        for(auto b:l.bindings){put(unsigned(b.kind)|(b.key_count<<4));
            if(b.kind==Kind::Shortcut){if(b.key_count){for(unsigned i=0;i<b.key_count;++i)put(b.keys[i]);}else{put(b.usage);put(b.modifiers);}}
            else if(b.kind==Kind::Inherit)put(b.source);
            else if(is_host(b.kind))put(b.source,4);
            else if(b.kind==Kind::Media)put(b.usage);
        }
        for(auto v:l.key_lights){put(v.custom?(128|v.effect):0);if(v.custom){put(v.color,3);put(v.brightness);put(v.active);}}
    }
    return data;
}
static bool unpack8(const std::vector<char> &data,size_t size,Configuration &out,bool snapshot=false) {
    size_t at=0;bool ok=true;
    auto get=[&](unsigned bytes=1)->uint32_t{if(at+bytes>size){ok=false;return 0;}uint32_t n=0;for(unsigned i=0;i<bytes;++i)n|=uint32_t(uint8_t(data[at++]))<<(8*i);return n;};
    if(size>config_bytes||get()!=8)return false;
    Configuration c;c.layers.clear();c.favorites.clear();if(snapshot)c.revision=get(4);
    unsigned count=get(),favorites=get();if(count<1||count>max_layers||favorites<1||favorites>6)return false;
    for(unsigned i=0;i<favorites;++i)c.favorites.push_back(get());
    for(unsigned n=0;n<count;++n){Layer l;l.id=get();unsigned len=get();if(!len||len>48)return false;l.name.clear();for(unsigned i=0;i<len;++i)l.name+=char(get());
        auto native=get();if(native>1)return false;l.native=native;
        l.color=get(3);l.ring_color=get(3);l.brightness=get();for(unsigned i=0;i<5;++i){auto e=get();l.effects[i]=(i==3&&e==255)?-1:int(e);}
        for(auto &b:l.bindings){auto header=get();b.kind=Kind(header&15);b.key_count=header>>4;if(b.key_count>14||(b.key_count&&b.kind!=Kind::Shortcut))return false;
            if(b.kind==Kind::Shortcut){if(b.key_count){for(unsigned i=0;i<b.key_count;++i)b.keys[i]=get();}else{b.usage=get();b.modifiers=get();}}
            else if(b.kind==Kind::Inherit)b.source=get();else if(is_host(b.kind))b.source=get(4);else if(b.kind==Kind::Media)b.usage=get();
        }
        for(auto &v:l.key_lights){auto h=get();if(h!=0&&(h<128||h>132))return false;v.custom=h!=0;if(v.custom){v.effect=h&7;v.color=get(3);v.brightness=get();v.active=get();}}
        c.layers.push_back(l);
    }
    if(!ok||at!=size||c.revision>0x7fffffff||!valid_config(c))return false;
    c.manual_layer=c.active_layer=c.favorites.front();out=std::move(c);return true;
}
cJSON *encode_config(const Configuration &c) {
    if(!valid_config(c))return nullptr;
    auto *j=cJSON_CreateObject();cJSON_AddNumberToObject(j,"schemaVersion",7);
    const auto bytes=pack8(c);std::string hex;hex.reserve(bytes.size()*2);const char digits[]="0123456789abcdef";
    for(auto b:bytes){hex+=digits[b>>4];hex+=digits[b&15];}
    cJSON_AddStringToObject(j,"payload",hex.c_str());return j;
}
bool decode_config(const cJSON *j,Configuration &out,unsigned legacy_version) {
    if(legacy_version||!number(j,"schemaVersion",7)||integer(j,"schemaVersion")!=7)return decode_expanded(j,out,legacy_version);
    const char *fields[]={"schemaVersion","payload"};auto *payload=field(j,"payload");
    if(!exact_fields(j,fields,2)||!cJSON_IsString(payload))return false;
    auto length=strlen(payload->valuestring);if(length>config_bytes*2||length%2)return false;
    std::vector<char> bytes;bytes.reserve(length/2);
    auto nibble=[](char c)->int{return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:-1;};
    for(size_t i=0;i<length;i+=2){int a=nibble(payload->valuestring[i]),b=nibble(payload->valuestring[i+1]);if(a<0||b<0)return false;bytes.push_back(char((a<<4)|b));}
    return unpack8(bytes,bytes.size(),out);
}

cJSON *encode_snapshot(const Configuration &c){auto *j=cJSON_CreateObject();cJSON_AddNumberToObject(j,"revision",c.revision);cJSON_AddItemToObject(j,"config",encode_config(c));return j;}
// Legacy compact JSON is read-only; v5 uses a bounded binary snapshot.
static bool expand_storage(cJSON *config,bool host) {
    auto *layers=cJSON_GetObjectItemCaseSensitive(config,"layers");
    if(!cJSON_IsArray(layers)||cJSON_GetArraySize(layers)>int(max_layers))return false;
    const char *kinds[]={"native","shortcut","disabled","inherit","application","open","text"};
    for(auto *layer=layers->child;layer;layer=layer->next){auto *array=cJSON_GetObjectItemCaseSensitive(layer,"bindings");
        if(!cJSON_IsArray(array)||cJSON_GetArraySize(array)!=20)return false;
        for(int i=0;i<20;++i){auto *a=cJSON_GetArrayItem(array,i);
            if(!cJSON_IsArray(a)||cJSON_GetArraySize(a)!=4)return false;
            for(int k=0;k<4;++k)if(!valid_integer(cJSON_GetArrayItem(a,k),k==0?(host?6:3):k==3?0x7fffffff:255))return false;
            auto *o=cJSON_CreateObject();cJSON_AddStringToObject(o,"kind",kinds[cJSON_GetArrayItem(a,0)->valueint]);
            cJSON_AddNumberToObject(o,"usage",cJSON_GetArrayItem(a,1)->valueint);
            cJSON_AddNumberToObject(o,"modifiers",cJSON_GetArrayItem(a,2)->valueint);
            cJSON_AddNumberToObject(o,"source",cJSON_GetArrayItem(a,3)->valueint);cJSON_ReplaceItemInArray(array,i,o);
        }
    }return true;
}
static bool unpack_binary(const std::vector<char> &data,size_t size,Configuration &out) {
    size_t at=0;bool ok=true;auto get=[&](unsigned bytes=1)->uint32_t{if(at+bytes>size){ok=false;return 0;}uint32_t n=0;for(unsigned i=0;i<bytes;++i)n|=uint32_t(uint8_t(data[at++]))<<(i*8);return n;};
    unsigned version = get();
    if (version != 5 && version != 6 && version != 7) { return false; }
    Configuration c;
    c.revision = get(4);
    unsigned count = get();
    if (count < 1 || count > 6) { return false; }
    c.layers.clear();
    for(unsigned n=0;n<count;++n){Layer l;l.id=get();unsigned len=get();if(len<1||len>48)return false;l.name.clear();for(unsigned i=0;i<len;++i)l.name+=char(get());unsigned native=get();if(native>1)return false;l.native=native;
        l.color=get(3);l.ring_color=get(3);l.brightness=get();for(unsigned i=0;i<5;++i){unsigned e=get();l.effects[i]=(i==3&&e==255)?-1:int(e);}
        for(unsigned i=0;i<(version==5?20:control_count);++i){auto &b=l.bindings[i];unsigned kind=get();if(kind>(version==5?6:version==6?7:8))return false;b.kind=Kind(kind);b.usage=get();b.modifiers=get();b.source=get(4);b.key_count=get();if(b.key_count>14)return false;for(auto &k:b.keys)k=get();}
        for(auto &v:l.key_lights){unsigned custom=get();if(custom>1)return false;v.custom=custom;v.effect=get();v.color=get(3);v.brightness=get();v.active=get();}
        if (version == 5) {
            for (unsigned i=20; i<control_count; ++i) { l.bindings[i] = {Kind::Disabled}; }
            for (unsigned i=13; i<control_count; ++i) {
                auto &b = l.bindings[i];
                if (l.id == 1) { b = {}; }
                else if (b.kind == Kind::Native || (b.kind == Kind::Inherit && b.source == 1)) { b = {Kind::Disabled}; }
            }
        }
        c.layers.push_back(l);
    }
    if (!ok || at != size || c.revision > 0x7fffffff) { return false; }
    c.favorites.clear();for(const auto &layer:c.layers)c.favorites.push_back(layer.id);
    if(!valid_config(c))return false;
    c.manual_layer=c.active_layer=c.favorites.front();
    Configuration checked=std::move(c);
    if (version == 5) { checked.migration_note = "Knob and joystick settings were upgraded. Codex controls are managed by Codex; ordinary-layer native controls and Codex links were disabled. Review and save your settings."; }
    out = checked;
    return true;
}
// Old snapshots may occupy the spare NVS pages needed by the next blob update.
// Call only after a verified snapshot8 exists; failures leave the store read-only.
static esp_err_t cleanup_legacy(nvs_handle_t handle) {
    bool changed=false;
    for(const char *key:{"snapshot","snapshot2","snapshot3","snapshot4","snapshot5","snapshot6","snapshot7"}) {
        auto error=nvs_erase_key(handle,key);
        if(error!=ESP_OK&&error!=ESP_ERR_NVS_NOT_FOUND)return error;
        if(error==ESP_OK)changed=true;
    }
    return changed?nvs_commit(handle):ESP_OK;
}
void ConfigStore::load(){
    value_={};writable_=false;error_.clear();esp_err_t e=nvs_flash_init_partition("edboard");if(e!=ESP_OK){error_=esp_err_to_name(e);return;}
    nvs_handle_t handle;e=nvs_open_from_partition("edboard","config",NVS_READWRITE,&handle);if(e!=ESP_OK){error_=esp_err_to_name(e);return;}
    size_t size=0;const char *key="snapshot8";int format=8;
    e=nvs_get_blob(handle,key,nullptr,&size);
    if(e==ESP_ERR_NVS_NOT_FOUND){format=7;key="snapshot7";e=nvs_get_blob(handle,key,nullptr,&size);}
    if(e==ESP_ERR_NVS_NOT_FOUND){format=6;key="snapshot6";e=nvs_get_blob(handle,key,nullptr,&size);}
    if(e==ESP_ERR_NVS_NOT_FOUND){format=5;key="snapshot5";e=nvs_get_blob(handle,key,nullptr,&size);}
    if(e==ESP_ERR_NVS_NOT_FOUND){format=4;key="snapshot4";e=nvs_get_blob(handle,key,nullptr,&size);}
    if(e==ESP_ERR_NVS_NOT_FOUND){format=3;key="snapshot3";e=nvs_get_blob(handle,key,nullptr,&size);}
    if(e==ESP_ERR_NVS_NOT_FOUND){format=2;key="snapshot2";e=nvs_get_blob(handle,key,nullptr,&size);}
    if(e==ESP_ERR_NVS_NOT_FOUND){format=1;key="snapshot";e=nvs_get_str(handle,key,nullptr,&size);}
    if(e==ESP_ERR_NVS_NOT_FOUND){nvs_close(handle);writable_=true;return;}
    if(e!=ESP_OK||size==0||size>(format>=6?8192:format>=3?4096:config_bytes)){nvs_close(handle);error_=e==ESP_OK?"snapshot_too_large":esp_err_to_name(e);return;}
    std::vector<char> data(size+1,0);e=format==1?nvs_get_str(handle,key,data.data(),&size):nvs_get_blob(handle,key,data.data(),&size);nvs_close(handle);
    if(e!=ESP_OK){error_=esp_err_to_name(e);return;}
    if(format>=5){
        Configuration next;
        if(!(format==8?unpack8(data,size,next,true):unpack_binary(data,size,next))){error_="invalid_snapshot";return;}
        value_=std::move(next);writable_=true;
        if(format==8){
            e=nvs_open_from_partition("edboard","config",NVS_READWRITE,&handle);
            if(e==ESP_OK){e=cleanup_legacy(handle);nvs_close(handle);}
            if(e!=ESP_OK){writable_=false;error_="legacy_cleanup_failed";}
        }
        return;
    }
    auto *j=cJSON_ParseWithOpts(data.data(),nullptr,true);const char *sf[]={"revision","config"};Configuration next;
    bool valid=exact_fields(j,sf,2)&&number(j,"revision",0x7fffffff);
    auto *config=cJSON_GetObjectItemCaseSensitive(j,"config");
    if(valid&&format==1){const char *f[]={"schemaVersion","controlId","binding"};Binding b;
        valid=exact_fields(config,f,3)&&number(config,"schemaVersion",1)&&integer(config,"schemaVersion")==1&&cJSON_IsString(field(config,"controlId"))&&!strcmp(field(config,"controlId")->valuestring,"key.r3c1")&&decode_binding(field(config,"binding"),b,true);
        if(valid){next.layers[0].bindings[6]=b;next.layers[0].native=b.kind==Kind::Native;}
    }else if(valid){if(format>=3)valid=expand_storage(config,format==4);if(valid)valid=decode_config(config,next,format);}
    if(valid){next.revision=integer(j,"revision");value_=next;writable_=true;}else error_="invalid_snapshot";
    cJSON_Delete(j);
}
bool ConfigStore::activate(unsigned id){if(!value_.layer(id))return false;value_.active_layer=id;return true;}
bool ConfigStore::select(unsigned id){if(value_.favorite_index(id)<0)return false;value_.manual_layer=id;return true;}
bool ConfigStore::save(const Configuration &config){
    if(!writable_||value_.revision==0x7fffffff)return false;
    Configuration next=config;next.migration_note.clear();next.revision=value_.revision+1;
    if(!valid_config(next)){error_="invalid_config";return false;}
    next.manual_layer=next.favorite_index(value_.manual_layer)>=0?value_.manual_layer:next.favorites.front();
    next.active_layer=next.manual_layer; // Config changes clear the temporary auto override.
    auto bytes=pack8(next,true);size_t size=bytes.size();const auto *encoded=bytes.data();
    if(size>8192){error_="snapshot_too_large";return false;}
    nvs_handle_t handle;esp_err_t e=nvs_open_from_partition("edboard","config",NVS_READWRITE,&handle);
    esp_err_t cleanup=ESP_OK;
    if(e==ESP_OK){e=nvs_set_blob(handle,"snapshot8",encoded,size);if(e==ESP_OK)e=nvs_commit(handle);
        std::vector<char> check(size,0);size_t read=size;if(e==ESP_OK)e=nvs_get_blob(handle,"snapshot8",check.data(),&read);
        if(e==ESP_OK&&(read!=size||memcmp(check.data(),encoded,size)))e=ESP_FAIL;
        // Reclaim legacy snapshots only after the new revision was committed and read back.
        // The 24 KiB partition must retain space for the next atomic blob replacement.
        if(e==ESP_OK)cleanup=cleanup_legacy(handle);
        nvs_close(handle);}
    if(e!=ESP_OK){writable_=false;error_=esp_err_to_name(e);return false;}
    value_=std::move(next);writable_=cleanup==ESP_OK;error_=writable_?"":"legacy_cleanup_failed";return true;
}
}
