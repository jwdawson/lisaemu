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

#endif
