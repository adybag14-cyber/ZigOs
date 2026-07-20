#!/usr/bin/env python3
"""Create the deterministic ZigOs legacy FAT12 volume."""
from __future__ import annotations
import argparse
import struct
from pathlib import Path

BPS=512; TOTAL=2880; SPC=1; RESERVED=1; FATS=2; ROOT_ENTRIES=224; SPF=9
ROOT_SECTORS=(ROOT_ENTRIES*32+BPS-1)//BPS; FAT_START=1; ROOT_START=19; DATA_START=33
HELLO_NAME=b"HELLO   TXT"
HELLO=(b"ZigOs legacy FAT12 filesystem is online.\r\n" b"Loaded through ATA PIO by the i686 kernel.\r\n")
INIT_NAME=b"INIT    ELF"
INIT_MESSAGE=b"INIT.ELF executed in ring3 via FAT12.\r\n"
CAT_NAME=b"CAT     ELF"


def fnv1a32(data: bytes)->int:
    v=0x811C9DC5
    for b in data: v=((v^b)*0x01000193)&0xffffffff
    return v


def set_fat12_entry(fat: bytearray, cluster:int, value:int)->None:
    o=cluster+cluster//2; value&=0xfff
    if cluster&1:
        fat[o]=(fat[o]&0x0f)|((value<<4)&0xf0); fat[o+1]=(value>>4)&0xff
    else:
        fat[o]=value&0xff; fat[o+1]=(fat[o+1]&0xf0)|((value>>8)&0x0f)


def build_elf(segment:bytes,memory_size:int=0x200)->bytes:
    base=0x00400000
    file_size=0x100+len(segment)
    elf=bytearray(file_size)
    elf[:16]=b"\x7fELF\x01\x01\x01\x00"+bytes(8)
    struct.pack_into("<HHIIIIIHHHHHH",elf,16,2,3,1,base,52,0,0,52,32,1,0,0,0)
    struct.pack_into("<IIIIIIII",elf,52,1,0x100,base,base,len(segment),memory_size,5,0x1000)
    elf[0x100:]=segment
    return bytes(elf)


def build_init_elf()->bytes:
    base=0x00400000; message_va=base+0x80; pid_va=base+0x70
    code=bytearray()
    code += b"\xB8\x01\x00\x00\x00"
    code += b"\xBB"+struct.pack("<I",message_va)
    code += b"\xB9"+struct.pack("<I",len(INIT_MESSAGE))
    code += b"\xCD\x80"
    code += b"\xB8\x02\x00\x00\x00\xCD\x80"
    code += b"\xA3"+struct.pack("<I",pid_va)
    code += b"\xB8\x03\x00\x00\x00"
    code += b"\xBB\x33\x00\x00\x00\xCD\x80\xF4"
    segment=bytearray(0x80+len(INIT_MESSAGE)); segment[:len(code)]=code; segment[0x80:]=INIT_MESSAGE
    return build_elf(bytes(segment))


def build_cat_elf()->bytes:
    base=0x00400000
    name_offset=0x90; fd_offset=0xA0; read_offset=0xA4; buffer_offset=0xA8
    name_va=base+name_offset; fd_va=base+fd_offset; read_va=base+read_offset; buffer_va=base+buffer_offset
    code=bytearray()
    code += b"\xB8\x04\x00\x00\x00"                    # open(name, 11)
    code += b"\xBB"+struct.pack("<I",name_va)
    code += b"\xB9\x0B\x00\x00\x00\xCD\x80"
    code += b"\xA3"+struct.pack("<I",fd_va)
    code += b"\x89\xC3"                                  # fd -> ebx
    code += b"\xB8\x05\x00\x00\x00"                    # read(fd, buffer, 86)
    code += b"\xB9"+struct.pack("<I",buffer_va)
    code += b"\xBA"+struct.pack("<I",len(HELLO))
    code += b"\xCD\x80"
    code += b"\xA3"+struct.pack("<I",read_va)
    code += b"\x89\xC1"                                  # count -> ecx
    code += b"\xB8\x01\x00\x00\x00"                    # write(buffer, count)
    code += b"\xBB"+struct.pack("<I",buffer_va)
    code += b"\xCD\x80"
    code += b"\xB8\x06\x00\x00\x00"                    # close(fd)
    code += b"\x8B\x1D"+struct.pack("<I",fd_va)
    code += b"\xCD\x80"
    code += b"\xB8\x03\x00\x00\x00"                    # exit(0x44)
    code += b"\xBB\x44\x00\x00\x00\xCD\x80\xF4"
    if len(code)>name_offset: raise RuntimeError("CAT.ELF code overlaps data")
    segment=bytearray(buffer_offset+len(HELLO))
    segment[:len(code)]=code
    segment[name_offset:name_offset+11]=HELLO_NAME
    return build_elf(bytes(segment))


INIT_ELF=build_init_elf()
CAT_ELF=build_cat_elf()


def root_entry(volume:bytearray,index:int,name:bytes,cluster:int,data:bytes)->None:
    o=ROOT_START*BPS+index*32; volume[o:o+11]=name; volume[o+11]=0x20
    struct.pack_into("<H",volume,o+26,cluster); struct.pack_into("<I",volume,o+28,len(data))


def build_volume(hidden_sectors:int)->bytes:
    v=bytearray(TOTAL*BPS); boot=memoryview(v)[:BPS]
    boot[0:3]=b"\xEB\x3C\x90"; boot[3:11]=b"ZIGOS   "; struct.pack_into("<H",boot,11,BPS)
    boot[13]=SPC; struct.pack_into("<H",boot,14,RESERVED); boot[16]=FATS
    struct.pack_into("<H",boot,17,ROOT_ENTRIES); struct.pack_into("<H",boot,19,TOTAL); boot[21]=0xF0
    struct.pack_into("<H",boot,22,SPF); struct.pack_into("<H",boot,24,18); struct.pack_into("<H",boot,26,2)
    struct.pack_into("<I",boot,28,hidden_sectors); boot[36]=0x80; boot[38]=0x29; struct.pack_into("<I",boot,39,0x5A49474F)
    boot[43:54]=b"ZIGOS FAT12"; boot[54:62]=b"FAT12   "; message=b"ZigOs FAT12 data volume"; boot[62:62+len(message)]=message; boot[510:512]=b"\x55\xAA"
    fat=bytearray(SPF*BPS); fat[:3]=b"\xF0\xFF\xFF"
    for cluster in (2,3,4): set_fat12_entry(fat,cluster,0xfff)
    for i in range(FATS):
        o=(FAT_START+i*SPF)*BPS; v[o:o+len(fat)]=fat
    root_entry(v,0,HELLO_NAME,2,HELLO); root_entry(v,1,INIT_NAME,3,INIT_ELF); root_entry(v,2,CAT_NAME,4,CAT_ELF)
    v[DATA_START*BPS:DATA_START*BPS+len(HELLO)]=HELLO
    v[(DATA_START+1)*BPS:(DATA_START+1)*BPS+len(INIT_ELF)]=INIT_ELF
    v[(DATA_START+2)*BPS:(DATA_START+2)*BPS+len(CAT_ELF)]=CAT_ELF
    return bytes(v)


def main()->None:
    ap=argparse.ArgumentParser(); ap.add_argument("--output",type=Path,required=True); ap.add_argument("--hidden-sectors",type=int,default=256); a=ap.parse_args()
    if a.hidden_sectors < 64 or a.hidden_sectors > 0xffff: raise SystemExit("hidden sector count outside supported range")
    volume=build_volume(a.hidden_sectors); a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_bytes(volume)
    print(f"Created FAT12 volume: {a.output} | hidden={a.hidden_sectors} sectors={TOTAL} root={ROOT_START} data={DATA_START} hello={len(HELLO)} init_elf={len(INIT_ELF)} init_fnv={fnv1a32(INIT_ELF):08X} cat_elf={len(CAT_ELF)} cat_fnv={fnv1a32(CAT_ELF):08X}")
if __name__=="__main__": main()
