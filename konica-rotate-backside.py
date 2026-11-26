#!/usr/bin/python3
"""Rotate even (back-side) pages 180 degrees in a CUPS raster for duplex long-edge."""
import ctypes, os, sys

libc = ctypes.CDLL("libcups.so.2")
class H(ctypes.Structure):
    _fields_=[('MediaClass',ctypes.c_char*64),('MediaColor',ctypes.c_char*64),('MediaType',ctypes.c_char*64),('OutputType',ctypes.c_char*64),
    ('AdvanceDistance',ctypes.c_uint),('AdvanceMedia',ctypes.c_int),('Collate',ctypes.c_int),('CutMedia',ctypes.c_int),('Duplex',ctypes.c_int),
    ('HWResolution',ctypes.c_uint*2),('ImagingBoundingBox',ctypes.c_uint*4),('InsertSheet',ctypes.c_int),('Jog',ctypes.c_int),('LeadingEdge',ctypes.c_int),
    ('Margins',ctypes.c_uint*2),('ManualFeed',ctypes.c_int),('MediaPosition',ctypes.c_uint),('MediaWeight',ctypes.c_uint),('MirrorPrint',ctypes.c_int),
    ('NegativePrint',ctypes.c_int),('NumCopies',ctypes.c_uint),('Orientation',ctypes.c_int),('OutputFaceUp',ctypes.c_int),('PageSize',ctypes.c_uint*2),
    ('Separations',ctypes.c_int),('TraySwitch',ctypes.c_int),('Tumble',ctypes.c_int),
    ('cupsWidth',ctypes.c_uint),('cupsHeight',ctypes.c_uint),('cupsMediaType',ctypes.c_uint),('cupsBitsPerColor',ctypes.c_uint),
    ('cupsBitsPerPixel',ctypes.c_uint),('cupsBytesPerLine',ctypes.c_uint),('cupsColorOrder',ctypes.c_int),('cupsColorSpace',ctypes.c_int),
    ('cupsCompression',ctypes.c_uint),('cupsRowCount',ctypes.c_uint),('cupsRowFeed',ctypes.c_uint),('cupsRowStep',ctypes.c_uint),
    ('cupsNumColors',ctypes.c_uint),('cupsBorderlessScalingFactor',ctypes.c_float),('cupsPageSize',ctypes.c_float*2),
    ('cupsImagingBBox',ctypes.c_float*4),('cupsInteger',ctypes.c_uint*16),('cupsReal',ctypes.c_float*16),('cupsString',ctypes.c_char*64*16),
    ('cupsMarkerType',ctypes.c_char*64),('cupsRenderingIntent',ctypes.c_char*64),('cupsPageSizeName',ctypes.c_char*64)]
libc.cupsRasterOpen.argtypes=[ctypes.c_int,ctypes.c_int]; libc.cupsRasterOpen.restype=ctypes.c_void_p
libc.cupsRasterReadHeader2.argtypes=[ctypes.c_void_p,ctypes.POINTER(H)]
libc.cupsRasterReadPixels.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_uint]
libc.cupsRasterWriteHeader2.argtypes=[ctypes.c_void_p,ctypes.POINTER(H)]
libc.cupsRasterWritePixels.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_uint]
libc.cupsRasterClose.argtypes=[ctypes.c_void_p]

src, dst = sys.argv[1], sys.argv[2]
inf = os.open(src, os.O_RDONLY)
outf = os.open(dst, os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
rin = libc.cupsRasterOpen(inf, 0)
rout = libc.cupsRasterOpen(outf, 1)
page = 0
while True:
    h = H()
    if not libc.cupsRasterReadHeader2(rin, ctypes.byref(h)):
        break
    page += 1
    size = h.cupsBytesPerLine * h.cupsHeight
    buf = ctypes.create_string_buffer(size)
    got = libc.cupsRasterReadPixels(rin, buf, size)
    data = buf.raw[:got]
    if page % 2 == 0 and h.Duplex != 0 and h.Tumble == 0 and h.cupsBitsPerPixel == 8 and h.cupsBitsPerColor == 8:
        w, rows = h.cupsBytesPerLine, h.cupsHeight
        out = bytearray(size)
        for y in range(rows):
            chunk = data[y*w:(y+1)*w]
            out[(rows-1-y)*w:(rows-y)*w] = chunk[::-1]
        data = bytes(out)
    outb = ctypes.create_string_buffer(data)
    libc.cupsRasterWriteHeader2(rout, ctypes.byref(h))
    libc.cupsRasterWritePixels(rout, outb, len(data))
libc.cupsRasterClose(rin); libc.cupsRasterClose(rout)
os.close(inf); os.close(outf)
