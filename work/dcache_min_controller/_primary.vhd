library verilog;
use verilog.vl_types.all;
entity dcache_min_controller is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        cpu_req         : in     vl_logic;
        cpu_we          : in     vl_logic;
        cpu_ready       : out    vl_logic;
        cpu_stall       : out    vl_logic;
        mem_req         : out    vl_logic;
        mem_we          : out    vl_logic;
        mem_ready       : in     vl_logic;
        cache_hit       : in     vl_logic;
        victim_dirty    : in     vl_logic;
        dp_hit_read     : out    vl_logic;
        dp_hit_write    : out    vl_logic;
        dp_wb_start     : out    vl_logic;
        dp_alloc_start  : out    vl_logic;
        dp_alloc_done   : out    vl_logic;
        ev_access       : out    vl_logic;
        ev_hit          : out    vl_logic;
        ev_miss         : out    vl_logic;
        ev_writeback    : out    vl_logic;
        ev_stall        : out    vl_logic;
        ev_mem_xfer     : out    vl_logic;
        state           : out    vl_logic_vector(1 downto 0)
    );
end dcache_min_controller;
