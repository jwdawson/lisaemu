#include "shim.h"
#include "include/m68k.h"
/* Pulls in the full m68ki_cpu_core definition (and the CPU_STOPPED macro,
 * i.e. m68ki_cpu.stopped) so lisa_cpu_stopped() below can read the core's
 * internal STOP/HALT state, which the public m68k.h does not expose. */
#include "m68kcpu.h"

static lisa_bus_t g_bus;

void lisa_bus_install(lisa_bus_t bus) { g_bus = bus; }

unsigned int m68k_read_memory_8(unsigned int a)  { return g_bus.read8(g_bus.ctx, a); }
unsigned int m68k_read_memory_16(unsigned int a) { return g_bus.read16(g_bus.ctx, a); }
unsigned int m68k_read_memory_32(unsigned int a) { return g_bus.read32(g_bus.ctx, a); }
void m68k_write_memory_8(unsigned int a, unsigned int v)  { g_bus.write8(g_bus.ctx, a, v); }
void m68k_write_memory_16(unsigned int a, unsigned int v) { g_bus.write16(g_bus.ctx, a, v); }
void m68k_write_memory_32(unsigned int a, unsigned int v) { g_bus.write32(g_bus.ctx, a, v); }
/* Disassembler fetches must not have side effects; route to plain reads. */
unsigned int m68k_read_disassembler_16(unsigned int a) { return g_bus.read16(g_bus.ctx, a); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return g_bus.read32(g_bus.ctx, a); }

unsigned int lisa_cpu_stopped(void) { return CPU_STOPPED; }

unsigned int lisa_cpu_supervisor(void) { return m68ki_cpu.s_flag; }

void lisa_cpu_force_halt(void) { m68ki_cpu.stopped |= STOP_LEVEL_HALT; }
