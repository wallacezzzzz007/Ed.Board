"""Offline Consumer report and release-recovery checks; no hardware access."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class MediaTests(unittest.TestCase):
    def test_pulses_and_release_recovery(self):
        source = r'''
#include "media.hpp"
#include <cassert>
#include <vector>
int main() {
    board::MediaPulse pulse;
    std::vector<unsigned> sent;
    auto send=[&](uint8_t bits){sent.push_back(bits);return true;};
    const unsigned usages[]={233,234,226,205,182,181};
    for(unsigned i=0;i<6;++i) {
        sent.clear();assert(pulse.trigger(usages[i],true,send));
        assert((sent==std::vector<unsigned>{1U<<i,0}));
        assert(pulse.trigger(usages[i],false,send));assert(sent.size()==2);
        assert(pulse.release(send));assert(sent.size()==2);
    }
    for(unsigned usage=0;usage<512;++usage) {
        bool known=false;for(auto valid:usages)known|=valid==usage;
        assert(bool(board::media_bit(usage))==known);
    }
    sent.clear();assert(!pulse.trigger(0,true,send));assert(sent.empty());
    // Failure to enqueue a press must not invent a pending release.
    assert(!pulse.trigger(205,true,[](uint8_t){return false;}));
    assert(pulse.release(send));assert(sent.empty());
    // Accepted press + failed release is retried before another action.
    assert(!pulse.trigger(205,true,[](uint8_t b){return b!=0;}));
    assert(!pulse.release([](uint8_t){return false;}));
    assert(pulse.trigger(233,true,send));
    assert((sent==std::vector<unsigned>{0,1,0}));
    assert(!pulse.trigger(205,true,[](uint8_t b){return b!=0;}));
    pulse.reset();sent.clear();assert(pulse.release(send));assert(sent.empty());
}
'''
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);(root/'test.cpp').write_text(source)
            subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror','-I',str(ROOT/'firmware/usb-probe/src'),str(root/'test.cpp'),'-o',str(root/'test')],check=True)
            subprocess.run([str(root/'test')],check=True)

    def test_usb_and_ble_consumer_descriptors(self):
        expected=[0x05,0x0c,0x09,0x01,0xa1,0x01,0x85,0x02,
                  0x15,0,0x25,1,0x75,1,0x95,6,
                  0x09,233,0x09,234,0x09,226,0x09,205,0x09,182,0x09,181,0x81,2,
                  0x75,2,0x95,1,0x81,1,0xc0]
        for path in ['main.cpp','ble/hid.hpp']:
            text=(ROOT/'firmware/usb-probe/src'/path).read_text()
            start=text.index('0x05,0x0C')
            report=text[start:text.index('};',start)]
            self.assertEqual([int(v,16) for v in re.findall(r'0x[0-9a-fA-F]+',report)],expected)

if __name__=='__main__': unittest.main()
