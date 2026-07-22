#!/usr/bin/env python3
from __future__ import annotations
import argparse,hashlib,struct
from pathlib import Path
CODE_BASE=0x0000008000000000; DATA_BASE=0x0000008000002000
MAGICS={'main':0x4D50524F43363431,'exec':0x4558454336343031}
EXPECTED_PAYLOAD={'main':1657,'exec':175}
EXPECTED_SYSCALLS={'main':44,'exec':7}
EXPECTED_CODE_FNV={'main':0xD56BC3BAEAFFE340,'exec':0x98EA5EC32A047A98}
EXPECTED_ELF_FNV={'main':0xF4E0D9F25BF74D76,'exec':0x13F8A5B090C2F18A}
EXPECTED_SHA={'main':'A04BEBD46E4C95A9A34A5BD84B2B3A43A2C555FB1601F2A94EBDBA82D3DDDD40','exec':'41D3ED292B1BE84EF3A30969B9CF22D650A22FB8BA92E831C40838B771B97B65'}

def fnv(data:bytes)->int:
 v=0xCBF29CE484222325
 for x in data: v=((v^x)*0x100000001B3)&0xffffffffffffffff
 return v

def verify(path:Path,kind:str):
 b=path.read_bytes()
 if len(b)!=10240: raise SystemExit(f'{path}: size {len(b)}')
 ident,etype,machine,version,entry,phoff,shoff,flags,ehsize,phentsize,phnum,_,_,_=struct.unpack_from('<16sHHIQQQIHHHHHH',b,0)
 if ident[:8]!=b'\x7fELF\x02\x01\x01\x00' or etype!=2 or machine!=0x3e or version!=1: raise SystemExit('bad ELF identity')
 if entry!=CODE_BASE or phoff!=64 or ehsize!=64 or phentsize!=56 or phnum!=2 or shoff or flags: raise SystemExit('bad ELF header')
 p1=struct.unpack_from('<IIQQQQQQ',b,64); p2=struct.unpack_from('<IIQQQQQQ',b,120)
 if p1[:5]!=(1,5,0x1000,CODE_BASE,0) or p2[:5]!=(1,6,0x2000,DATA_BASE,0): raise SystemExit('bad program headers')
 if p1[5]!=EXPECTED_PAYLOAD[kind] or p1[6]!=p1[5] or p1[7]!=0x1000: raise SystemExit('bad RX sizing')
 if p2[5:]!=(0x800,0x2000,0x1000): raise SystemExit('bad RW sizing')
 code=b[0x1000:0x1000+p1[5]]; data=b[0x2000:0x2800]
 if code.count(b'\xcd\x80')!=EXPECTED_SYSCALLS[kind]: raise SystemExit('bad syscall count')
 if fnv(code)!=EXPECTED_CODE_FNV[kind]: raise SystemExit('unexpected code identity')
 if fnv(b)!=EXPECTED_ELF_FNV[kind]: raise SystemExit('unexpected ELF FNV identity')
 if hashlib.sha256(b).hexdigest().upper()!=EXPECTED_SHA[kind]: raise SystemExit('unexpected ELF SHA-256 identity')
 if struct.unpack_from('<Q',data,0x7c0)[0]!=MAGICS[kind]: raise SystemExit('bad magic')
 if struct.unpack_from('<Q',data,0x7c8)[0]!=fnv(code): raise SystemExit('bad code hash')
 if struct.unpack_from('<Q',data,0x7d0)[0]!=fnv(data[:0x7d0]): raise SystemExit('bad data hash')
 for off,val in ((0x500,b'WORKER1!'),(0x508,b'WORKER2!'),(0x510,b'EXECCHLD'),(0x518,b'REUSE003')):
  if data[off:off+8]!=val: raise SystemExit('bad record')
 print(f'Verified {kind} process ELF: {path}')
 print(f'  payload: {len(code)} bytes; syscalls: {code.count(bytes.fromhex("cd80"))}')
 print(f'  code FNV-1a64: {fnv(code):016X}')
 print(f'  SHA-256: {hashlib.sha256(b).hexdigest().upper()}')

def main():
 ap=argparse.ArgumentParser(); ap.add_argument('path',type=Path); ap.add_argument('--kind',choices=('main','exec'),required=True); a=ap.parse_args(); verify(a.path,a.kind)
if __name__=='__main__': main()
