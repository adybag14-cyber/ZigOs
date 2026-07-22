#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, struct
from pathlib import Path

CODE_BASE=0x0000008000000000
DATA_BASE=0x0000008000002000
CODE_OFFSET=0x1000
DATA_OFFSET=0x2000
PAGE_SIZE=0x1000
DATA_FILE_SIZE=0x800
DATA_MEMORY_SIZE=0x2000
RECORDS={0x500:b'WORKER1!',0x508:b'WORKER2!',0x510:b'EXECCHLD',0x518:b'REUSE003'}
MAGICS={'main':0x4D50524F43363431,'exec':0x4558454336343031}

def fnv(data:bytes)->int:
 v=0xCBF29CE484222325
 for x in data:
  v^=x; v=(v*0x100000001B3)&0xffffffffffffffff
 return v

def build(code:bytes,kind:str)->bytes:
 if not code or len(code)>PAGE_SIZE: raise ValueError(len(code))
 data=bytearray(DATA_FILE_SIZE)
 for off,value in RECORDS.items(): data[off:off+len(value)]=value
 data[0x200:0x208]=struct.pack('<II',0,1)
 data[0x7C0:0x7C8]=struct.pack('<Q',MAGICS[kind])
 data[0x7C8:0x7D0]=struct.pack('<Q',fnv(code))
 data[0x7D0:0x7D8]=struct.pack('<Q',fnv(data[:0x7D0]))
 ident=bytearray(16); ident[:4]=b'\x7fELF'; ident[4:8]=bytes((2,1,1,0))
 eh=struct.pack('<16sHHIQQQIHHHHHH',bytes(ident),2,0x3e,1,CODE_BASE,64,0,0,64,56,2,0,0,0)
 ph1=struct.pack('<IIQQQQQQ',1,5,CODE_OFFSET,CODE_BASE,0,len(code),len(code),PAGE_SIZE)
 ph2=struct.pack('<IIQQQQQQ',1,6,DATA_OFFSET,DATA_BASE,0,len(data),DATA_MEMORY_SIZE,PAGE_SIZE)
 out=bytearray(DATA_OFFSET+len(data)); out[:64]=eh; out[64:120]=ph1; out[120:176]=ph2
 out[CODE_OFFSET:CODE_OFFSET+len(code)]=code; out[DATA_OFFSET:]=data
 return bytes(out)

def main():
 ap=argparse.ArgumentParser(); ap.add_argument('--payload',type=Path,required=True); ap.add_argument('--output',type=Path,required=True); ap.add_argument('--kind',choices=('main','exec'),required=True); a=ap.parse_args()
 image=build(a.payload.read_bytes(),a.kind); a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_bytes(image)
 print(f'Created {a.kind} ELF64 process image: {a.output}')
 print(f'  payload bytes: {len(a.payload.read_bytes())}')
 print(f'  image bytes:   {len(image)}')
 print(f'  code FNV-1a64: {fnv(a.payload.read_bytes()):016X}')
 print(f'  ELF FNV-1a64:  {fnv(image):016X}')
 print(f'  ELF SHA-256:   {hashlib.sha256(image).hexdigest().upper()}')
if __name__=='__main__': main()
