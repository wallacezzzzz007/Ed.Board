"""User-run host checks of the firmware display reducer. No device or dependencies."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class JoystickStateTests(unittest.TestCase):
    def test_gesture_lifecycle(self):
        source = r'''
#include "quick_overlay.hpp"
#include <cassert>
int main() {
    board::QuickOverlay q;
    q.update(true,0,0,0,false,2,146);
    assert(!q.visible);
    q.update(true,130,0,0,false,2,146); // Before stable direction: visible.
    assert(q.visible && q.candidate==0 && q.gesture==1);
    q.update(true,650,0,17,false,2,146);
    auto held=q;
    for(int i=0;i<100000;++i)q.update(true,650,0,17,false,2,146);
    assert(q==held); // No idle heartbeat state changes or hold timeout.
    q.update(true,656,0,17,false,2,146);
    assert(q==held); // Small ADC noise does not generate traffic.
    q.update(true,0,0,17,false,2,146);
    assert(q.visible); // Wait for firmware's stable return/action processing.
    q.update(true,150,0,0,true,2,146);
    assert(!q.visible);
    q.update(true,140,0,0,false,2,146);
    assert(!q.visible); // Do not reopen until physically centered.
    q.update(true,0,0,0,false,2,146);
    q.update(true,130,0,0,false,2,146);
    assert(q.visible && q.gesture==2);
    q.update(true,0,0,0,false,2,146);
    assert(!q.visible); // Small move with no candidate also ends.
    q.update(true,700,0,17,false,2,146);
    q.update(false,700,0,0,false,1,146);
    assert(!q.visible); // Codex/fault/disconnect suppression.
    q.update(true,700,0,17,false,2,146);
    assert(!q.visible); // Layer switch while off center cannot reuse gesture.
    q.update(true,0,0,0,false,2,146);
    q.update(true,700,0,17,false,2,146);
    assert(q.visible);
    q.update(true,700,0,17,false,2,147);
    assert(!q.visible); // Revision invalidation.
    q.update(true,0,0,0,false,2,147);
    auto previous=q.gesture;
    q.update(true,700,0,17,true,2,147); // End/new gesture drained in one loop.
    assert(q.visible && q.gesture==previous+1 && q.candidate==17);
}
'''
        with tempfile.TemporaryDirectory(prefix='edboard-joystick-') as folder:
            path = Path(folder)
            (path / 'state.cpp').write_text(source)
            subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            '-I', str(ROOT / 'firmware/usb-probe/src'),
                            str(path / 'state.cpp'), '-o', str(path / 'state')], check=True)
            subprocess.run([str(path / 'state')], check=True)


if __name__ == '__main__':
    unittest.main()
