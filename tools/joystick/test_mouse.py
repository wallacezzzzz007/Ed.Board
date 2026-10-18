"""Offline relative-wheel and HID/BLE routing checks; synthetic data only."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]

class MouseTests(unittest.TestCase):
    def compile_run(self, source):
        with tempfile.TemporaryDirectory(prefix='edboard-mouse-') as folder:
            path=Path(folder);(path/'test.cpp').write_text(source)
            subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror','-I',str(ROOT/'firmware/usb-probe/src'),str(path/'test.cpp'),'-o',str(path/'test')],check=True)
            subprocess.run([str(path/'test')],check=True)
    def test_one_relative_event_no_pointer_or_release(self):
        self.compile_run(r'''
#include "mouse.hpp"
#include <cassert>
#include <vector>
int main(){
 std::vector<std::array<uint8_t,4>> reports;
 auto send=[&](auto r){reports.push_back(r);return true;};
 for(unsigned id:{1,2}){
  reports.clear();assert(board::trigger_wheel(id,true,send));assert(reports.size()==1);
  assert(reports[0][0]==0&&reports[0][1]==0&&reports[0][2]==0);
  assert(int8_t(reports[0][3])==(id==1?1:-1));
  assert(board::trigger_wheel(id,false,send));assert(reports.size()==1);
 }
 reports.clear();assert(!board::trigger_wheel(0,true,send));assert(!board::trigger_wheel(3,true,send));assert(reports.empty());
 assert(!board::trigger_wheel(1,true,[](auto){return false;}));
 assert(board::trigger_wheel(1,true,send));assert(reports.size()==1);
 reports.clear();for(int i=0;i<32;++i)assert(board::trigger_wheel(2,true,send));assert(reports.size()==32);
}
''')
    def test_joystick_fixed_rate_stop_reverse_and_no_catchup(self):
        self.compile_run(r'''
#include "mouse.hpp"
#include <cassert>
#include <vector>
int main(){
 board::WheelRepeat wheel;std::vector<int> reports;
 auto send=[&](auto r){assert(r[0]==0&&r[1]==0&&r[2]==0);reports.push_back(int8_t(r[3]));return true;};
 wheel.select(2,1000);assert(wheel.tick(1000,send));assert(reports.size()==1&&reports.back()==-1);
 for(int64_t t=2000;t<81000;t+=1000){wheel.select(2,t);assert(wheel.tick(t,send));}assert(reports.size()==1);
 assert(wheel.tick(81000,send));assert(reports.size()==2);
 wheel.select(0,82000);assert(wheel.tick(900000,send));assert(reports.size()==2);
 wheel.select(1,900000);assert(wheel.tick(900000,send));assert(reports.back()==1);
 assert(wheel.tick(9000000,send));assert(reports.size()==4);
 assert(wheel.tick(9000000,send));assert(reports.size()==4);
 wheel.reset();assert(wheel.tick(10000000,send));assert(reports.size()==4);
 wheel.select(2,10000000);assert(!wheel.tick(10000000,[](auto){return false;}));
 assert(wheel.tick(11000000,send));assert(reports.size()==4);
 wheel.select(99,12000000);assert(wheel.tick(12000000,send));assert(reports.size()==4);
}
''')
    def test_real_joystick_scheduler_gates(self):
        text=(ROOT/'firmware/usb-probe/src/main.cpp').read_text()
        start=text.index('    // Check fresh physical state')
        end=text.index('    if (armed && !needsSync && inputLinkReady() && epoch.load()==session && knobPending',start)
        block=text[start:end]
        self.compile_run(r'''
#include "mouse.hpp"
#include <atomic>
#include <cassert>
namespace board {enum class Kind {Disabled,Mouse,Shortcut,Cancel};struct Binding {Kind kind=Kind::Disabled;unsigned usage=0;};}
struct State {bool ready=true,fault=false;int quick_direction=5;unsigned keys=0;} state;
State input_snapshot(){return state;}
struct Switcher {bool active(){return false;}template<class Send>bool finish(Send send){return send();}}appSwitcher;
bool sendKeyboard(unsigned){return true;}
bool knobPending=false;
bool armed=true,needsSync=false,ready=true,quickCancelled=false;
int quickCandidate=18;unsigned drops=0;std::atomic<unsigned> epoch{1};
unsigned input_drops(){return drops;}bool inputLinkReady(){return ready;}
struct Active {int id=2;};struct Config {Active active(){return {};}};
struct Store {Config current(){return {};}};struct Management {Store store;} management;
board::Binding binding{board::Kind::Mouse,2};board::Binding bindingFor(unsigned){return binding;}
int64_t now=0;int64_t esp_timer_get_time(){return now;}
board::WheelRepeat joystickWheel;int sends=0;bool sendOK=true;
bool sendWheel(const std::array<uint8_t,4>& r,unsigned,int){assert(int8_t(r[3])==-1);++sends;return sendOK;}
void process(unsigned session=1){const unsigned dropsBefore=0;
'''+block+r'''
}
int main(){
 process();assert(sends==1);now=80000;process();assert(sends==2);
 state.quick_direction=0;now+=80000;process();assert(sends==2);
 state.quick_direction=5;now+=80000;process();assert(sends==3);
 quickCandidate=16;now+=80000;process();assert(sends==3);quickCandidate=18;
 quickCancelled=true;process();assert(sends==3);quickCancelled=false;
 state.fault=true;process();assert(sends==3);state.fault=false;
 armed=false;process();assert(sends==3);armed=true;
 needsSync=true;process();assert(sends==3);needsSync=false;
 ready=false;process();assert(sends==3);ready=true;
 drops=1;process();assert(sends==3);drops=0;
 epoch=2;process();assert(sends==3);epoch=1;
 binding.kind=board::Kind::Shortcut;process();assert(sends==3);binding.kind=board::Kind::Mouse;
 sendOK=false;process();assert(sends==4&&!armed&&needsSync);
}
''')
    def test_real_return_to_centre_skips_mouse_but_keeps_other_actions(self):
        text=(ROOT/'firmware/usb-probe/src/main.cpp').read_text()
        start=text.index('        case InputKind::QuickStick: {')+len('        case InputKind::QuickStick: {')
        end=text.index('        case InputKind::Stick:',start)
        case=text[start:end].rsplit('}',1)[0]
        self.compile_run(r'''
#include "mouse.hpp"
#include <cassert>
namespace board {enum class Kind{Disabled,Mouse,Shortcut,Cancel};struct Binding{Kind kind;};}
enum class InputKind{QuickStick};struct Event{int value;};
struct Active{int id=2;};struct Config{Active active(){return {};}};struct Store{Config current(){return {};}};struct Management{Store store;}management;
bool dispatched=true,linkReady=true,needsSync=false,armed=true,ok=true,quickCancelled=false,quickCompleted=false;
int quickCandidate=0,pulses=0;unsigned session=1;board::WheelRepeat joystickWheel;
board::Kind kind=board::Kind::Mouse;board::Binding bindingFor(unsigned){return {kind};}
void set_preview_cancelled(bool){}bool pulseControl(unsigned,unsigned){++pulses;return true;}
void event(int value){Event event{value};switch(InputKind::QuickStick){case InputKind::QuickStick:{
'''+case+r'''
}}}
int main(){
 event(5);assert(quickCandidate==18);event(0);assert(!pulses&&quickCompleted&&!quickCandidate);
 kind=board::Kind::Shortcut;event(5);event(0);assert(pulses==1);
 kind=board::Kind::Cancel;event(5);event(0);assert(pulses==1);
}
''')
    def test_usb_ble_descriptor_lengths_and_relative_wheel(self):
        reports=[]
        for name in ('main.cpp','ble/hid.hpp'):
            text=(ROOT/'firmware/usb-probe/src'/name).read_text();start=text.index('// Mouse report 3:')
            reports.append([int(x,16) for x in re.findall('0x[0-9A-Fa-f]+',text[start:text.index('};',start)])])
        self.assertEqual(reports[0],reports[1])
        data=reports[0];at=0;rid=0;size=count=0;bits=0;page=0;usages=[];inputs=[];depth=0
        while at<len(data):
            prefix=data[at];at+=1;n=prefix&3;n=4 if n==3 else n
            value=int.from_bytes(bytes(data[at:at+n]),'little');at+=n;tag=prefix&0xfc
            if tag==0x84:rid=value
            elif tag==0x74:size=value
            elif tag==0x94:count=value
            elif tag==0x04:page=value
            elif tag==0x08:usages.append((page,value))
            elif tag==0x80:bits+=size*count;inputs.append((list(usages),size,count,value));usages=[]
            elif tag==0xa0:depth+=1;usages=[]
            elif tag==0xc0:depth-=1
        self.assertEqual((rid,bits,depth),(3,32,0))
        self.assertEqual(inputs[-1][0],[(1,0x30),(1,0x31),(1,0x38)])
        self.assertEqual(inputs[-1][1:],(8,3,6)) # signed relative X/Y/Wheel, four-byte total
    def test_real_ble_sender_subscription_length_and_handle(self):
        text=(ROOT/'firmware/usb-probe/src/ble/ble.cpp').read_text();start=text.index('bool ble_report(');end=text.index('\n}\n}',start)+2
        function=text[start:end]
        source=r'''
#include <cstdint>
#include <cstddef>
#include <cassert>
#include <array>
#include <cstring>
bool enabled=true,connected=true,secure=true,subscribed=true,keyboard_subscribed=true,media_subscribed=true,mouse_subscribed=false;
unsigned handle=10,vendor_handle=60,keyboard_handle=11,media_handle=22,mouse_handle=33,notified=0;
struct os_mbuf {std::array<uint8_t,63> bytes{};size_t count=0;} packet;
unsigned ble_att_mtu(unsigned){return 80;}
os_mbuf* ble_hs_mbuf_from_flat(const void* b,size_t n){packet.count=n;memcpy(packet.bytes.data(),b,n);return &packet;}
int ble_gatts_notify_custom(unsigned,unsigned attr,os_mbuf*){notified=attr;return 0;}
'''+function+r'''
int main(){
 uint8_t report[63]{};report[3]=255;
 assert(!ble_report(3,report,4)&&!notified);
 mouse_subscribed=true;assert(!ble_report(3,report,3)&&!notified);
 assert(ble_report(3,report,4)&&notified==33&&packet.count==4&&packet.bytes[3]==255);
 secure=false;notified=0;assert(!ble_report(3,report,4)&&!notified);secure=true;
 assert(ble_report(1,report,8)&&notified==11);
 assert(ble_report(2,report,1)&&notified==22);
 assert(ble_report(6,report,63)&&notified==60);
 assert(!ble_report(4,report,4));
}
'''
        self.compile_run(source)
if __name__=='__main__':unittest.main()
