#!/usr/bin/env python3
"""Simula input X (clic + rueda) via libXtst, sin xdotool ni sudo."""
import ctypes, sys, time
from ctypes import c_char_p, c_void_p, c_uint, c_bool, c_ulong, c_int

xlib  = ctypes.CDLL("libX11.so.6")
xtest = ctypes.CDLL("libXtst.so.6")

xlib.XOpenDisplay.restype = c_void_p
xlib.XOpenDisplay.argtypes = [c_char_p]
xlib.XFlush.argtypes = [c_void_p]
xlib.XDefaultRootWindow.restype = c_ulong
xlib.XDefaultRootWindow.argtypes = [c_void_p]
xtest.XTestFakeButtonEvent.argtypes = [c_void_p, c_uint, c_bool, c_ulong]
xtest.XTestFakeKeyEvent.argtypes = [c_void_p, c_uint, c_bool, c_ulong]
xlib.XKeysymToKeycode.restype = c_uint
xlib.XKeysymToKeycode.argtypes = [c_void_p, c_char_p]

display = sys.argv[1].encode() if len(sys.argv) > 1 else b":1"
d = xlib.XOpenDisplay(display)
if not d:
    sys.exit(f"no se pudo abrir display {display.decode()}")

root = xlib.XDefaultRootWindow(d)

xlib.XWarpPointer.argtypes = [c_void_p, c_ulong, c_ulong, c_int, c_int,
                               c_uint, c_uint, c_int, c_int]

def warp(x, y):
    xlib.XWarpPointer(d, 0, root, 0, 0, 0, 0, x, y)
    xlib.XFlush(d)
    time.sleep(0.25)

def btn(b, press):
    xtest.XTestFakeButtonEvent(d, b, press, 0)
    xlib.XFlush(d)

def click(x, y, buttons=(1,)):
    warp(x, y)
    for b in buttons:
        btn(b, True);  time.sleep(0.08); btn(b, False); time.sleep(0.08)

def scroll(x, y, clicks=6, direction=4):
    """direction 4 = zoom in, 5 = zoom out"""
    warp(x, y)
    for _ in range(clicks):
        btn(direction, True); time.sleep(0.05); btn(direction, False); time.sleep(0.06)

def raise_window(title_substr):
    """Busca una ventana por título y la trae al frente (XRaiseWindow)."""
    xlib.XFetchName.restype = c_bool
    xlib.XFetchName.argtypes = [c_void_p, c_ulong, ctypes.POINTER(c_char_p)]
    xlib.XQueryTree.argtypes = [c_void_p, c_ulong,
                                ctypes.POINTER(c_ulong), ctypes.POINTER(c_ulong),
                                ctypes.POINTER(ctypes.POINTER(c_ulong)),
                                ctypes.POINTER(c_uint)]
    xlib.XQueryTree.restype = c_int
    xlib.XRaiseWindow.argtypes = [c_void_p, c_ulong]

    root_ret = c_ulong(); parent = c_ulong()
    children = ctypes.POINTER(c_ulong)(); n = c_uint()
    found = None
    needle = title_substr.lower().encode()

    def walk(win, depth=0):
        nonlocal found
        if found or depth > 6:
            return
        name = c_char_p()
        if xlib.XFetchName(d, win, ctypes.byref(name)) and name.value:
            if needle in name.value.lower():
                found = win
                return
        ch = ctypes.POINTER(c_ulong)(); cnt = c_uint()
        if xlib.XQueryTree(d, win, ctypes.byref(root_ret), ctypes.byref(parent),
                           ctypes.byref(ch), ctypes.byref(cnt)):
            for i in range(cnt.value):
                walk(ch[i], depth + 1)
            if ch:
                ctypes.cast(ch, c_void_p)

    walk(root)
    if not found:
        return False
    xlib.XRaiseWindow(d, found)
    xlib.XFlush(d)
    return True

act = sys.argv[2] if len(sys.argv) > 2 else "scroll"
# centro aproximado del viewport 3D (ajustar si cambia la resolución)
VX, VY = 716, 400

if act == "click":
    # click en coordenadas opcionales: click [x y]
    cx = int(sys.argv[3]) if len(sys.argv) > 3 else VX
    cy = int(sys.argv[4]) if len(sys.argv) > 4 else VY
    click(cx, cy)
elif act == "scroll":                 # zoom in sobre el viewport
    click(VX, VY)                      # enfoca el viewport
    time.sleep(0.3)
    scroll(VX, VY, clicks=int(sys.argv[3]) if len(sys.argv) > 3 else 6, direction=4)
elif act == "scrollout":
    click(VX, VY)
    time.sleep(0.3)
    scroll(VX, VY, clicks=6, direction=5)
elif act == "raise":
    # raise "<subcadena del título>"
    sub = sys.argv[3] if len(sys.argv) > 3 else "Roblox Studio"
    ok = raise_window(sub)
    print(f"{'OK' if ok else 'NO ENCONTRADA'}: ventana '{sub}' "
          f"{'elevada' if ok else 'no encontrada'}")
    sys.exit(0 if ok else 1)
else:
    sys.exit(f"acción desconocida: {act}")

print(f"OK: '{act}' ejecutado en {display.decode()}")
