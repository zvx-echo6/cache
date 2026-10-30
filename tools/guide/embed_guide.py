#!/usr/bin/env python3
"""Embed every manifest section with bge-m3, through the llama DLL that ships with the Cache command-line build.

usage: embed_guide.py --bin-dir DIR --model bge-m3-Q8_0.gguf MANIFEST.json OUT.json

DIR holds cache_llama.dll (and the DLLs next to it). Windows only. Writes a list of
{title, text_vec, title_text_vec}: the embedding of the section body, and of "<title>\\n\\n<body>". The library uses
title_text_vec (see BUILD.md). It loads the 0.6 GB model plus the llama runtime, so check free memory first.
"""
import argparse
import ctypes
import json
import os

ap = argparse.ArgumentParser()
ap.add_argument('--bin-dir', required=True)
ap.add_argument('--model', required=True)
ap.add_argument('manifest')
ap.add_argument('out')
a = ap.parse_args()

os.add_dll_directory(a.bin_dir)
lib = ctypes.CDLL(os.path.join(a.bin_dir, 'cache_llama.dll'))
lib.cl_embed_load.restype = ctypes.c_void_p
lib.cl_embed_load.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
lib.cl_embed_info.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
lib.cl_embed.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_float), ctypes.c_int, ctypes.c_int]
lib.cl_embed_free.argtypes = [ctypes.c_void_p]
eb = ctypes.create_string_buffer(512)
h = lib.cl_embed_load(a.model.encode(), 512, 4, eb, 512)
assert h, eb.value
ib = ctypes.create_string_buffer(2048)
lib.cl_embed_info(h, ib, 2048)
info = json.loads(ib.value)
print(info)
n = info['n_embd']


def emb(t):
    out = (ctypes.c_float * n)()
    r = lib.cl_embed(h, t.encode('utf-8'), out, n, 1)
    assert r == n, r
    return list(out)


man = json.load(open(a.manifest, encoding='utf-8'))
res = [{'title': m['title'], 'text_vec': emb(m['body']), 'title_text_vec': emb(m['title'] + '\n\n' + m['body'])} for m in man]
json.dump(res, open(a.out, 'w'))
print(len(res), len(res[0]['text_vec']))
lib.cl_embed_free(h)
