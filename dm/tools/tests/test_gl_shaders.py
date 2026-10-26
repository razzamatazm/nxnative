"""gl_shaders.py text steps before glslang: desktop GLSL older than 1.40 is raised to 3.30 (attribute / varying, gl_FragColor / gl_FragData, a shader's own function named as a newer
built-in), and a shader's own function named as a Metal sampling argument type is renamed (30XX's #version 120 shaders, its trunc and bias)."""
import importlib.util
from pathlib import Path
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/gfx/tools'))
spec = importlib.util.spec_from_file_location('gl_shaders', REPO / 'dm/gfx/tools/gl_shaders.py')
gl = importlib.util.module_from_spec(spec); spec.loader.exec_module(gl)

VERT = '''#version 120
attribute vec3 a_Pos;
varying vec4 v_Diff;
float trunc(float x) { return x < 0.0 ? -floor(abs(x)) : floor(x); }
void main() { v_Diff = vec4(trunc(a_Pos.x)); gl_Position = vec4(a_Pos, 1.0); }
'''
FRAG = '''#version 120
varying vec4 v_Diff;
void main() { gl_FragColor = v_Diff; gl_FragData[1] = v_Diff; }
'''


class Upgrade(unittest.TestCase):
    def test_vertex(self):
        t = gl.upgrade_old(VERT, 'vert')
        self.assertTrue(t.startswith('#version 330\n'))
        self.assertIn('in vec3 a_Pos;', t); self.assertIn('out vec4 v_Diff;', t)
        self.assertIn('float trunc_g(float x)', t); self.assertIn('vec4(trunc_g(a_Pos.x))', t)
        self.assertNotIn('attribute', t)

    def test_fragment(self):
        t = gl.upgrade_old(FRAG, 'frag')
        self.assertIn('in vec4 v_Diff;', t)
        self.assertIn('layout(location = 0) out vec4 dm_FragColor;', t); self.assertIn('dm_FragColor = v_Diff;', t)
        self.assertIn('layout(location = 1) out vec4 dm_FragData1;', t); self.assertIn('dm_FragData1 = v_Diff;', t)
        self.assertNotIn('gl_FragColor', t)

    def test_newer_and_es_unchanged(self):
        for src in ('#version 330\nattribute vec3 a;\n', '#version 100 es\nattribute vec3 a;\n', '#version 320 es\nvoid main() {}\n'):
            self.assertEqual(gl.upgrade_old(src, 'vert'), src)

    def test_metal_clash(self):
        t = gl.fixups('float bias(float t, float b) { return t; }\nvoid main() { float x = bias(1.0, 0.5); }\n')
        self.assertIn('float bias_g(float t, float b)', t); self.assertIn('bias_g(1.0, 0.5)', t)
        self.assertEqual(gl.fixups('void main() { float bias = 1.0; }\n'), 'void main() { float bias = 1.0; }\n')   # a variable, not a function: left alone


if __name__ == '__main__':
    unittest.main()
