// sim/tools/vl_stubs.cpp
// Verilator expects a few symbols to be OPTIONAL (see verilated.mk LDFLAGS:
//   -Wl,-U,__Z15vl_time_stamp64v,-U,__Z13sc_time_stampv,-U,_vlog_startup_routines
// ).  zig's lld does not honour that "-U", so provide the trivial definitions here.

// Declared weak in verilated_funcs.h as:  extern double sc_time_stamp();
// Only used for time reporting; 0 is fine for a non-timed testbench.
double sc_time_stamp() { return 0.0; }
