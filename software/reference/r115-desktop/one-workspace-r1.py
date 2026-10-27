#!/usr/bin/python3
"""Request one live X11 workspace; obxprop must verify WM acceptance separately.

Existing guest Python/ctypes/libX11 only. No generated input, direct property
forgery, window destruction, server restart, or external storage writes.
EWMH: https://specifications.freedesktop.org/wm/latest-single/
"""
import ctypes as c

P, U, L, I = c.c_void_p, c.c_ulong, c.c_long, c.c_int

class Message(c.Structure):
    _fields_ = [('type', I), ('serial', U), ('send_event', I),
                ('display', P), ('window', U), ('message_type', U),
                ('format', I), ('data', L * 5)]

class Event(c.Union):
    _fields_ = [('message', Message), ('pad', L * 24)]

assert c.sizeof(P) == 8 and c.sizeof(L) == 8
assert c.sizeof(Message) == 96 and c.sizeof(Event) == 192
x = c.CDLL('libX11.so.6')
def api(name, args, result):
    f = getattr(x, name)
    f.argtypes, f.restype = args, result
    return f
open_display = api('XOpenDisplay', [c.c_char_p], P)
root_window = api('XDefaultRootWindow', [P], U)
intern_atom = api('XInternAtom', [P, c.c_char_p, I], U)
send = api('XSendEvent', [P, U, I, L, c.POINTER(Event)], I)
sync = api('XSync', [P, I], I)
close = api('XCloseDisplay', [P], I)
d = open_display(b':0')
if not d:
    raise SystemExit('Cannot open current X display; nothing changed')
try:
    root = root_window(d)
    assert root
    for name, value in [(b'_NET_CURRENT_DESKTOP', 0),
                        (b'_NET_NUMBER_OF_DESKTOPS', 1)]:
        atom = intern_atom(d, name, 1)
        assert atom, 'Required EWMH atom absent'
        e = Event()
        m = e.message
        m.type, m.display, m.window = 33, d, root
        m.message_type, m.format, m.data[0] = atom, 32, value
        assert send(d, root, 0, (1 << 20) | (1 << 19), c.byref(e))
        sync(d, 0)
        print('REQUEST_SENT', name.decode(), value, flush=True)
finally:
    close(d)
