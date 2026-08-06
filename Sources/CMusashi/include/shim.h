#ifndef LISA_SHIM_H
#define LISA_SHIM_H

typedef unsigned int (*lisa_bus_read_fn)(void *ctx, unsigned int address);
typedef void (*lisa_bus_write_fn)(void *ctx, unsigned int address,
                                  unsigned int value);

typedef struct {
    void *ctx;
    lisa_bus_read_fn  read8;
    lisa_bus_read_fn  read16;
    lisa_bus_read_fn  read32;
    lisa_bus_write_fn write8;
    lisa_bus_write_fn write16;
    lisa_bus_write_fn write32;
} lisa_bus_t;

/* Install the bus callbacks Musashi's memory macros forward to. */
void lisa_bus_install(lisa_bus_t bus);

/* Raw value of the Musashi core's internal `stopped` bitfield (m68ki_cpu.stopped).
 * Bit STOP_LEVEL_STOP (1) means the core executed a STOP instruction (low-power
 * wait; resumes on interrupt -- not fatal). Bit STOP_LEVEL_HALT (2) means a
 * double bus fault halted the core (fatal until reset). The two constants are
 * not exposed in the public m68k.h, so Swift decodes this raw value against
 * the well-known bit positions (see M68K.swift). */
unsigned int lisa_cpu_stopped(void);

/* Raw value of the Musashi core's internal `s_flag` bitfield
 * (m68ki_cpu.s_flag). Nonzero when the core is in supervisor mode; zero in
 * user mode. Swift compares this against zero rather than relying on a
 * specific bit pattern, since Musashi stores the flag pre-shifted. */
unsigned int lisa_cpu_supervisor(void);

/* Records fault details for the pending 68000 group-0 (bus error/address
 * error) exception frame, mirroring the three globals Musashi's own
 * address-error path (m68ki_check_address_error, m68kcpu.h) sets before
 * every group-0 exception: m68ki_aerr_address, m68ki_aerr_write_mode,
 * m68ki_aerr_fc. Must be called before m68k_pulse_bus_error() -- see
 * M68K.pulseBusError(address:isWrite:), the sole caller.
 *
 * `is_write` follows Musashi's MODE_READ(0x10)/MODE_WRITE(0) convention
 * (m68kcpu.h) for the R/W bit of the pushed special-status word.
 *
 * The function code is synthesized as user/supervisor DATA
 * (FUNCTION_CODE_USER_DATA=1 / FUNCTION_CODE_SUPERVISOR_DATA=5, selected by
 * `is_supervisor`) rather than read from live Musashi state: our vendored
 * m68kconf.h has M68K_EMULATE_FC == M68K_OPT_OFF (confirmed by reading it),
 * so m68ki_set_fc()/the "current fc" state Musashi would otherwise track are
 * compiled out entirely, and Bus.swift's `access()` does not distinguish
 * instruction-fetch vs. data-access at the fault site either. DATA matches
 * Musashi's own FC-off fallback (m68kcpu.h's `m68ki_get_address_space()`
 * macro literally expands to FUNCTION_CODE_USER_DATA when FC emulation is
 * off) -- this is not a new approximation, it's the same one upstream
 * already makes elsewhere in this configuration. The supervisor/user split
 * is real (from `is_supervisor`), using Musashi's own FLAG_S encoding
 * (SFLAG_SET == 4, matching FUNCTION_CODE_SUPERVISOR_DATA == 4|1 == 5). */
void lisa_set_bus_error_fault(unsigned int address, unsigned int is_write,
                               unsigned int is_supervisor);

/* Force the core into the fatal HALT stop level (sets STOP_LEVEL_HALT in
 * m68ki_cpu.stopped), the same terminal state a real double bus fault
 * produces. Used by Bus's consecutive-fault detection: a translated CPU
 * access that faults while a previous fault's exception stack frame is
 * still being pushed (i.e. no successful access happened in between) is a
 * real 68000 double-fault condition, but pulsing a second bus error into
 * Musashi's WSF "catastrophic failure" branch (m68ki_exception_bus_error)
 * itself performs a live bus access before setting CPU_STOPPED, which would
 * recurse back into the same fault and never terminate -- so we halt
 * directly instead of pulsing again. See M68K.forceHalt(). */
void lisa_cpu_force_halt(void);

#endif
