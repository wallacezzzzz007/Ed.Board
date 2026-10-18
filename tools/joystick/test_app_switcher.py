"""Offline App Switcher state and actual knob dispatch checks; synthetic data only."""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class AppSwitcherTests(unittest.TestCase):
    def compile_run(self, source):
        with tempfile.TemporaryDirectory(prefix='edboard-switcher-') as folder:
            path=Path(folder); (path/'test.cpp').write_text(source)
            subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror','-I',str(ROOT/'firmware/usb-probe/src'),str(path/'test.cpp'),'-o',str(path/'test')],check=True)
            subprocess.run([str(path/'test')],check=True)

    def test_command_tab_reverse_release_and_failures(self):
        self.compile_run(r'''
#include "app_switcher.hpp"
#include <cassert>
#include <vector>
#include <utility>
int main(){
 board::AppSwitcher s;std::vector<std::pair<unsigned,bool>> reports;
 auto send=[&]{reports.push_back({s.modifiers(),s.tab()});return true;};
 assert(s.begin(send));assert(s.active());assert(reports.size()==2);
 assert(reports[0]==std::make_pair(8U,true)&&reports[1]==std::make_pair(8U,false));
 assert(s.begin(send)&&reports.size()==2);
 assert(s.step(false,send));assert(s.step(true,send));
 assert(reports[4]==std::make_pair(10U,true)&&reports[5]==std::make_pair(8U,false));
 assert(s.finish(send));assert(!s.active()&&reports.back()==std::make_pair(0U,false));
 auto count=reports.size();assert(s.finish(send)&&s.step(true,send));assert(reports.size()==count);
 for(int failAt:{1,2}){int calls=0;assert(!s.begin([&]{return ++calls!=failAt;}));assert(!s.active()&&!s.modifiers()&&!s.tab());}
 assert(s.begin(send));s.reset();assert(!s.active()&&!s.tab()&&!s.modifiers());
 assert(s.begin(send));assert(!s.finish([]{return false;}));assert(!s.active());
}
''')

    def test_actual_knob_threshold_release_and_rotation_dispatch(self):
        text=(ROOT/'firmware/usb-probe/src/main.cpp').read_text()
        start=text.index('                if (event.down) { knobPending=true;')
        end=text.index('\n                break;',start)
        press=text[start:end]
        start=text.index('            // A detent arriving at the threshold')
        end=text.index('            unsigned control=event.value<0?14:15;',start)
        rotate=text[start:end]
        start=text.index('    if (armed && !needsSync && inputLinkReady() && epoch.load()==session && knobPending')
        end=text.index('\n}\n\nvoid updateQuickOverlay',start)
        timer=text[start:end]
        start=text.index('    // Release even if a burst of encoder events')
        end=text.index('    constexpr unsigned wheelControls[]',start)
        flush=text[start:end]
        self.compile_run(r'''
#include "app_switcher.hpp"
#include <cassert>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <vector>
namespace board {enum class Kind{AppSwitcher,Shortcut};struct Binding{Kind kind;};}
board::AppSwitcher appSwitcher;board::Kind action=board::Kind::AppSwitcher;
board::Binding bindingFor(unsigned){return {action};}
bool knobPending=false,knobHeld=false,ok=true,armed=true,needsSync=false;
int64_t knobStarted=0,now=0;unsigned session=1;std::atomic<unsigned>epoch{1};
struct State{unsigned keys=0;}state;
State input_snapshot(){return state;}bool inputLinkReady(){return true;}
int64_t esp_timer_get_time(){return now;}
std::vector<unsigned> reports,pulses;int normalTurns=0;
bool sendKeyboard(unsigned){reports.push_back(appSwitcher.modifiers()|(appSwitcher.tab()?256:0));return true;}
bool pulseControl(unsigned id,unsigned){pulses.push_back(id);return true;}
struct Event{bool down;int value;};
void press(bool down){Event event{down,0};state.keys=down?(1U<<13):0;
'''+press+r'''
}
void turn(int steps){Event event{false,steps};do{
'''+rotate+r'''
 ++normalTurns;
}while(false);}
void tick(){
'''+timer+r'''
}
void flushReleased(){const auto current=input_snapshot();
'''+flush+r'''
}
int main(){
 press(true);now=200000;turn(1);press(false);assert(normalTurns==1&&pulses==std::vector<unsigned>{13});assert(reports.empty());
 now=1000000;press(true);now+=600000;tick();assert(appSwitcher.active()&&knobHeld&&reports.size()==2);
 turn(-2);turn(1);assert(normalTurns==1&&reports.size()==8&&reports[6]==266&&reports[7]==8);
 press(false);assert(!appSwitcher.active()&&!knobPending&&reports.back()==0&&pulses.size()==1);
 // Boundary detent starts the hold before normal rotation; no volume/scroll leak.
 now=2000000;press(true);now+=600000;turn(1);assert(appSwitcher.active()&&normalTurns==1);press(false);
 // A delayed loop still performs a long hold, then releases Command.
 now=3000000;press(true);now+=700000;press(false);assert(!appSwitcher.active()&&reports.back()==0&&pulses.size()==1);
 // Physical release ends the switcher even before a queued release is consumed.
 now=3800000;press(true);now+=600000;tick();assert(appSwitcher.active());
 state.keys=0;flushReleased();assert(!appSwitcher.active()&&!knobPending&&reports.back()==0);
 press(false);assert(pulses.size()==1);
 // Existing non-switcher long holds retain exactly one pulse and normal turns.
 action=board::Kind::Shortcut;now=4000000;press(true);now+=600000;tick();turn(1);press(false);
 assert(pulses==std::vector<unsigned>({13,20})&&normalTurns==2);
}
''')

    def test_actual_keyboard_merges_and_releases_temporary_modifiers(self):
        text=(ROOT/'firmware/usb-probe/src/main.cpp').read_text()
        start=text.index('    uint8_t codes[6]{},mods=0;unsigned count=0;bool seen[256]{};')
        end=text.index('    const int64_t deadline=',start)
        assembly=text[start:end]
        self.compile_run(r'''
#include "app_switcher.hpp"
#include <array>
#include <cassert>
#include <cstdint>
namespace board {constexpr unsigned control_count=25;struct Binding{uint8_t modifiers=0,key_count=0,usage=0;std::array<uint8_t,14> keys{};};}
board::AppSwitcher appSwitcher;std::array<bool,25>shortcutDown{};std::array<board::Binding,25>heldShortcuts{};
std::array<uint8_t,8> report{};
bool send(){
'''+assembly+r'''
 report={mods,0,codes[0],codes[1],codes[2],codes[3],codes[4],codes[5]};return true;
}
int main(){
 shortcutDown[0]=true;heldShortcuts[0].usage=4;send();assert(report[0]==0&&report[2]==4);
 assert(appSwitcher.begin(send));assert(report[0]==8&&report[2]==4&&report[3]==0);
 assert(appSwitcher.step(true,send));assert(report[0]==8&&report[2]==4);
 assert(appSwitcher.finish(send));assert(report[0]==0&&report[2]==4);
 assert(appSwitcher.begin(send));appSwitcher.reset();shortcutDown.fill(false);send();
 assert((report==std::array<uint8_t,8>{}));
}
''')

if __name__=='__main__': unittest.main()
