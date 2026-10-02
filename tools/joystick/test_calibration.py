"""Offline regression checks with synthetic sensor readings; no hardware access."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class CalibrationTests(unittest.TestCase):
    def test_recovery_and_safety(self):
        source = r'''
#include "input_calibration.hpp"
#include <cassert>
using R=InputCalibration::Result;
R window(InputCalibration &c,int64_t &now,int x=1800,int y=1900,unsigned touch=30000,bool released=true) {
    R r=R::Waiting;
    for(int i=0;i<100;++i) {now+=20000;r=c.add(now,x,y,touch,released);}
    return r;
}
int main() {
    InputCalibration c; int64_t t=0;
    // Startup motion with a valid mean must still fail stability checks.
    for(int i=0;i<99;++i) {t+=20000;assert(c.add(t,1800,i%2?1000:2800,30000,true)==R::Waiting);}
    t+=20000;assert(c.add(t,1800,1900,30000,true)==R::Failed);
    c.fail(t);assert(c.retry_at==t+1000000 && c.samples==0);
    assert(c.add(t+999999,1800,1900,30000,true)==R::Waiting && c.samples==0);
    t=c.retry_at;assert(window(c,t)==R::Ready); // Recovery without a reboot.
    assert(c.failures==0);
    // Runtime read failure: old baselines survive; held touch cannot become neutral.
    c.fail(t);t=c.retry_at;assert(window(c,t,1800,1900,40000)==R::Failed);
    c.fail(t);t=c.retry_at;assert(window(c,t,2100)==R::Failed);
    c.fail(t);t=c.retry_at;assert(window(c,t,1800,1900,30000,false)==R::Failed);
    c.fail(t);t=c.retry_at;assert(window(c,t)==R::Ready);
    // Ongoing hardware failure backs off to a bounded interval without overflow.
    for(int i=0;i<10000;++i){c.fail(t);assert(c.retry_at-t<=8000000);t=c.retry_at;}
    assert(c.retry_at-t==0 && c.failures==4);
    InputCalibration bad; t=0;assert(window(bad,t,1000)==R::Failed);
    bad.fail(t);t=bad.retry_at;assert(window(bad,t,1800,1900,10000)==R::Failed);
    bad.fail(t);t=bad.retry_at;assert(window(bad,t)==R::Ready);
    // One held-key sample anywhere in the window prevents acceptance.
    InputCalibration held;t=0;
    assert(held.add(t,1800,1900,30000,false)==R::Waiting);
    for(int i=0;i<98;++i){t+=20000;assert(held.add(t,1800,1900,30000,true)==R::Waiting);}
    t+=20000;assert(held.add(t,1800,1900,30000,true)==R::Failed);
}
'''
        with tempfile.TemporaryDirectory(prefix='edboard-calibration-') as folder:
            path=Path(folder)
            (path/'test.cpp').write_text(source)
            subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror','-I',str(ROOT/'firmware/usb-probe/src'),str(path/'test.cpp'),'-o',str(path/'test')],check=True)
            subprocess.run([str(path/'test')],check=True)

if __name__=='__main__': unittest.main()
