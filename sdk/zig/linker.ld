ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = 0x0000008000000000;
  .text : ALIGN(0x1000)
  {
    *(.text .text.* .ltext .ltext.*)
    *(.rodata .rodata.* .lrodata .lrodata.*)
  } :text

  . = ALIGN(0x1000);
  .data : ALIGN(0x1000)
  {
    *(.data .data.* .ldata .ldata.*)
  } :data

  .bss : ALIGN(16)
  {
    *(.bss .bss.* .lbss .lbss.*)
    *(COMMON)
  } :data

  /DISCARD/ :
  {
    *(.comment)
    *(.note .note.*)
    *(.eh_frame .eh_frame.* .eh_frame_hdr)
  }
}
