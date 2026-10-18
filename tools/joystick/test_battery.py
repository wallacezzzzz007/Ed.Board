"""Offline battery estimator checks with synthetic voltages; no device records."""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class BatteryTests(unittest.TestCase):
    def test_curve_full_filter_and_invalid_reading(self):
        source = r'''
#include "battery_estimate.hpp"
#include <cassert>
int main() {
    int previous=0;
    for(int mv=2000;mv<=5000;++mv) {
        const int p=BatteryEstimate::percent(mv);
        assert(p>=previous && p>=0 && p<=99);previous=p;
    }
    assert(BatteryEstimate::percent(3100)==0);
    assert(BatteryEstimate::percent(3500)==12);
    assert(BatteryEstimate::percent(4000)==82);
    BatteryEstimate b;
    assert(b.update(4120,true,false,true)==100);
    assert(b.update(4120,true,true,false)<100);
    assert(b.update(3500,true,false,false)==12); // Falls must not conceal a low reading.
    assert(b.update(3000,true,false,false)==0);
    assert(b.update(0,false,false,true)==0 && !b.initialized);
    assert(b.update(3900,true,false,false)==65); // Reset after a failed conversion.
    const int settled=b.filtered_mv;
    b.update(4100,true,true,false);
    assert(b.filtered_mv>settled && b.filtered_mv<4100);
    for(int i=0;i<100;++i)b.update(4100,true,true,false);
    assert(b.filtered_mv>=4097 && b.filtered_mv<=4100);
    assert(b.update(2500,true,false,true)==100); // Full indication owns full display.
}
'''
        with tempfile.TemporaryDirectory(prefix='edboard-battery-') as folder:
            path=Path(folder);(path/'test.cpp').write_text(source)
            subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror','-I',str(ROOT/'firmware/usb-probe/src'),str(path/'test.cpp'),'-o',str(path/'test')],check=True)
            subprocess.run([str(path/'test')],check=True)
if __name__=='__main__':unittest.main()
