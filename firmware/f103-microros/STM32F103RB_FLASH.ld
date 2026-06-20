/* STM32F103RB linker script
 * Flash 128K @ 0x08000000, RAM 20K @ 0x20000000 (Cortex-M3, 无 FPU).
 * 为 FreeRTOS 预留:本工程 task 栈来自 FreeRTOS heap(动态)或静态数组;
 * _Min_Heap_Size/_Min_Stack_Size 是 C 运行时(main 之前 / ISR)的栈与 newlib 堆下界保护,
 * 不是 FreeRTOS 的 heap。FreeRTOS 自己的 heap_4 用 ucHeap[configTOTAL_HEAP_SIZE](在 .bss)。
 *
 * 入口与中断向量来自 CMSIS startup_stm32f103xb.s(.isr_vector 段)。
 */

ENTRY(Reset_Handler)

/* 主栈(MSP)栈顶 = RAM 末尾,向下生长。这是上电/ISR 用的栈。 */
_estack = ORIGIN(RAM) + LENGTH(RAM);

/* C 运行时下界保护(链接期检查,不实际占用,除非真用到):
 * Min_Heap = newlib malloc 用的堆(本工程几乎不用,留 512B 兜底 sbrk);
 * Min_Stack = MSP 最小栈余量(ISR + scheduler 启动前)。 */
_Min_Heap_Size  = 0x200;   /* 512 B */
_Min_Stack_Size = 0x400;   /* 1 KB  */

MEMORY
{
  FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 128K
  RAM   (xrw) : ORIGIN = 0x20000000, LENGTH = 20K
}

SECTIONS
{
  /* 中断向量表必须在 Flash 起始。 */
  .isr_vector :
  {
    . = ALIGN(4);
    KEEP(*(.isr_vector))
    . = ALIGN(4);
  } >FLASH

  /* 代码 */
  .text :
  {
    . = ALIGN(4);
    *(.text)
    *(.text*)
    *(.glue_7)
    *(.glue_7t)
    *(.eh_frame)
    KEEP(*(.init))
    KEEP(*(.fini))
    . = ALIGN(4);
    _etext = .;
  } >FLASH

  /* 只读数据 */
  .rodata :
  {
    . = ALIGN(4);
    *(.rodata)
    *(.rodata*)
    . = ALIGN(4);
  } >FLASH

  .ARM.extab : { *(.ARM.extab* .gnu.linkonce.armextab.*) } >FLASH
  .ARM :
  {
    __exidx_start = .;
    *(.ARM.exidx*)
    __exidx_end = .;
  } >FLASH

  /* C++ 静态构造/析构(本工程基本无,但留着保险) */
  .preinit_array :
  {
    PROVIDE_HIDDEN(__preinit_array_start = .);
    KEEP(*(.preinit_array*))
    PROVIDE_HIDDEN(__preinit_array_end = .);
  } >FLASH
  .init_array :
  {
    PROVIDE_HIDDEN(__init_array_start = .);
    KEEP(*(SORT(.init_array.*)))
    KEEP(*(.init_array*))
    PROVIDE_HIDDEN(__init_array_end = .);
  } >FLASH
  .fini_array :
  {
    PROVIDE_HIDDEN(__fini_array_start = .);
    KEEP(*(SORT(.fini_array.*)))
    KEEP(*(.fini_array*))
    PROVIDE_HIDDEN(__fini_array_end = .);
  } >FLASH

  /* .data 的加载地址(在 Flash) */
  _sidata = LOADADDR(.data);

  /* 初始化数据:链接在 RAM,镜像存 Flash,startup 启动时拷贝 */
  .data :
  {
    . = ALIGN(4);
    _sdata = .;
    *(.data)
    *(.data*)
    . = ALIGN(4);
    _edata = .;
  } >RAM AT> FLASH

  /* 未初始化数据(含所有静态 buffer:DMA RX/TX、FreeRTOS ucHeap) */
  .bss :
  {
    . = ALIGN(4);
    _sbss = .;
    __bss_start__ = _sbss;
    *(.bss)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
    __bss_end__ = _ebss;
  } >RAM

  /* 链接期检查:确保 .bss 之后还有 Min_Heap + Min_Stack 的余量,否则报错 */
  ._user_heap_stack :
  {
    . = ALIGN(8);
    PROVIDE(end = .);
    PROVIDE(_end = .);
    . = . + _Min_Heap_Size;
    . = . + _Min_Stack_Size;
    . = ALIGN(8);
  } >RAM

  /DISCARD/ : { libc.a(*) libm.a(*) libgcc.a(*) }

  .ARM.attributes 0 : { *(.ARM.attributes) }
}
