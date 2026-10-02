// Animation logic adapted from AI Micro Basic 0.1.0 (MIT), see vendor/LICENSE.
// RMT LED signaling and physical pixel mapping for AI Micro Board3.
#include "lights.hpp"
#include "inputs.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include "driver/gpio.h"
#include "driver/rmt_tx.h"
#include "driver/rmt_encoder.h"
namespace {
constexpr unsigned agent_pixels[]={20,19,15,16,17,18};
constexpr unsigned command_pixels[]={14,13,12,11,8,9,10};
constexpr gpio_num_t indicators[]={GPIO_NUM_40,GPIO_NUM_39,GPIO_NUM_38};
rmt_channel_handle_t channel;
rmt_encoder_handle_t encoder;
rmt_symbol_word_t symbols[21*24+1];
std::array<uint32_t,21> colors{},previous{};
bool first=true;
std::array<int64_t,13> pressedAt{};
int64_t activityAt=-10000;
uint16_t oldKeys=0;uint32_t oldLeft=0,oldRight=0,oldTouch=0;int oldX=0,oldY=0;
uint32_t lightRevision=0xffffffff;unsigned lightLayer=0;
float customLevel(const board::LightSpec &v,int64_t now,bool held,int64_t trigger) {
    float base=v.brightness/100.0f;
    float pulse=held?1.0f:std::clamp(1.0f-float(now-trigger)/300.0f,0.0f,1.0f);
    switch(v.effect){case 0:return 0;case 2:return base*(0.1f+0.9f*(0.5f-0.5f*std::cos(float(now%4000)/4000*6.2831853f)));
        case 3:return base*pulse;case 4:return base+(v.active/100.0f-base)*pulse;default:return base;}
}

void pixel(unsigned i,uint32_t rgb,float b) {
    b=std::clamp(b,0.0f,1.0f);
    colors[i]=(uint32_t(((rgb>>16)&255)*b)<<16)|(uint32_t(((rgb>>8)&255)*b)<<8)|uint32_t((rgb&255)*b);
}
void region(unsigned group,uint32_t rgb,float b) {
    if(group==0)for(unsigned i=0;i<8;++i)pixel(i,rgb,b);
    else if(group==1)for(auto i:command_pixels)pixel(i,rgb,b);
    else pixel(agent_pixels[group-2],rgb,b);
}
esp_err_t show() {
    if(!first&&colors==previous)return ESP_OK;
    size_t n=0;
    for(auto rgb:colors) {
        const uint32_t grb=((rgb&0xff00)<<8)|((rgb&0xff0000)>>8)|(rgb&255);
        for(int bit=23;bit>=0;--bit) {
            bool one=grb&(1U<<bit);auto &symbol=symbols[n++];symbol={};
            symbol.level0=1;symbol.duration0=one?9:3;symbol.duration1=one?3:9;
        }
    }
    symbols[n]={};symbols[n].duration0=1500;symbols[n].duration1=1500;
    rmt_transmit_config_t tx{};
    esp_err_t error=rmt_transmit(channel,encoder,symbols,sizeof(symbols),&tx);
    if(error==ESP_OK)error=rmt_tx_wait_all_done(channel,100);
    if(error==ESP_OK){previous=colors;first=false;}
    return error;
}
}
void note_light_input(const InputEvent &event,int64_t now) {
    activityAt=now;
    if(event.kind==InputKind::Key&&event.value>=0&&event.value<13)pressedAt[event.value]=now;
}
void start_lights() {
    gpio_deep_sleep_hold_dis();
    for(auto pin:indicators)gpio_hold_dis(pin);
    gpio_hold_dis(GPIO_NUM_3);
    for(auto pin:indicators){ESP_ERROR_CHECK(gpio_set_level(pin,1));ESP_ERROR_CHECK(gpio_set_direction(pin,GPIO_MODE_OUTPUT));}
    rmt_tx_channel_config_t config{};config.gpio_num=GPIO_NUM_3;config.clk_src=RMT_CLK_SRC_DEFAULT;
    config.resolution_hz=10000000;config.mem_block_symbols=64;config.trans_queue_depth=1;
    ESP_ERROR_CHECK(rmt_new_tx_channel(&config,&channel));
    rmt_copy_encoder_config_t copy{};ESP_ERROR_CHECK(rmt_new_copy_encoder(&copy,&encoder));
    ESP_ERROR_CHECK(rmt_enable(channel));ESP_ERROR_CHECK(show());
}
esp_err_t render_lights(const aim::Lights &lights,int64_t now,bool connected,const board::Configuration &config, bool pairing, bool sleeping) {
    if(sleeping&&!pairing) {
        colors.fill(0);
        for(auto pin:indicators)gpio_set_level(pin,1);
        return show();
    }
    auto apply=[&](unsigned group,const aim::Light& light) {
        float b=light.brightness;uint32_t rgb=light.rgb;
        float phase=std::fmod(float(now)/1000*(0.2f+light.speed*2),1.0f);
        if(light.effect==0)b=0;
        else if(light.effect==4)b*=0.5f-0.5f*std::cos(phase*6.2831853f);
        else if(light.effect==6)b*=0.75f-0.25f*std::cos(phase*6.2831853f);
        else if(light.effect==5)b*=0.4f+0.6f*phase;
        else if(light.effect==3) {
            auto wave=[&](float offset) {return uint32_t((0.5f+0.5f*std::sin((phase+offset)*6.2831853f))*255);};
            rgb=(wave(0)<<16)|(wave(0.3333f)<<8)|wave(0.6667f);
        }
        if(light.effect==2&&group<2) {
            unsigned count=group==0?8:7,active=unsigned(phase*count)%count;
            for(unsigned i=0;i<count;++i)pixel(group==0?i:command_pixels[i],rgb,i==active?b:0);
        } else region(group,rgb,b);
    };
    apply(0,lights.ambient);apply(1,lights.commands);
    for(unsigned i=0;i<6;++i)apply(i+2,lights.agents[i]);
    // Read-only visual feedback; never feeds actions or power activity.
    auto state=input_snapshot();
    const auto &layer=config.active();
    if(lightRevision!=config.revision||lightLayer!=layer.id){pressedAt.fill(-10000);activityAt=-10000;lightRevision=config.revision;lightLayer=layer.id;}
    for(unsigned i=0;i<13;++i)if(state.keys&(1U<<i))pressedAt[i]=now;
    bool held=state.keys||state.touched||state.direction;
    if(held||state.keys!=oldKeys||state.preview_left!=oldLeft||state.preview_right!=oldRight||state.preview_touch!=oldTouch||std::abs(state.preview_x-oldX)>50||std::abs(state.preview_y-oldY)>50)activityAt=now;
    oldKeys=state.keys;oldLeft=state.preview_left;oldRight=state.preview_right;oldTouch=state.preview_touch;oldX=state.preview_x;oldY=state.preview_y;
    if(!layer.native) {
        board::LightSpec outer{true,uint8_t(layer.effects[2]),layer.ring_color,uint8_t(layer.effects[3]<0?layer.brightness:layer.effects[3]),uint8_t(layer.effects[4])};
        float level=connected?customLevel(outer,now,held,activityAt):0;
        if(outer.effect==5){float phase=float(now%8000)/1000;for(unsigned i=0;i<8;++i){float distance=std::fmod(phase+8-i,8.0f);pixel(i,outer.color,level*std::max(0.0f,1-distance/3));}}
        else region(0,outer.color,level);
        for(unsigned i=0;i<13;++i) {
            auto binding=config.resolve(layer.id,i);
            if(i<6&&binding.kind==board::Kind::Native)continue;
            board::LightSpec v{true,uint8_t(layer.effects[0]),layer.color,layer.brightness,uint8_t(layer.effects[1])};
            unsigned id=layer.id;
            for (unsigned depth = 0; depth < board::max_layers; ++depth) {
                auto *source = config.layer(id);
                if (!source || source->native) { break; }
                auto b = source->bindings[i];
                if (b.kind == board::Kind::Inherit) {
                    id = b.source;
                    continue;
                }
                if (source->key_lights[i].custom) { v = source->key_lights[i]; }
                break;
            }
            pixel(i<6?agent_pixels[i]:command_pixels[i-6],v.color,connected?customLevel(v,now,state.keys&(1U<<i),pressedAt[i]):0);
        }
    }
    // Physical order is top, middle, bottom; outputs are active low.
    constexpr unsigned masks[]={1,2,4,3,6,7};size_t index=0;
    for(size_t i=0;i<config.layers.size();++i)if(config.layers[i].id==layer.id)index=i;
    for(unsigned i=0;i<3;++i)gpio_set_level(indicators[i],(pairing ? ((now/300)%2!=0) : (masks[index]&(1U<<i))!=0)?0:1);
    return show();
}

esp_err_t prepare_lights_for_sleep() {
    colors.fill(0);
    auto error=show();if(error!=ESP_OK)return error;
    error=rmt_disable(channel);if(error!=ESP_OK)return error;
    for(auto pin:indicators) {
        gpio_set_level(pin,1);gpio_hold_en(pin);
    }
    gpio_set_direction(GPIO_NUM_3,GPIO_MODE_OUTPUT);
    gpio_set_level(GPIO_NUM_3,0);gpio_hold_en(GPIO_NUM_3);
    gpio_deep_sleep_hold_en();
    return ESP_OK;
}
