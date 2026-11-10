library verilog;
use verilog.vl_types.all;
entity dcache_min_perf_counters is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        cpu_we          : in     vl_logic;
        ev_access       : in     vl_logic;
        ev_hit          : in     vl_logic;
        ev_miss         : in     vl_logic;
        ev_writeback    : in     vl_logic;
        ev_stall        : in     vl_logic;
        ev_mem_xfer     : in     vl_logic;
        cnt_accesses    : out    vl_logic_vector(31 downto 0);
        cnt_hits        : out    vl_logic_vector(31 downto 0);
        cnt_read_hits   : out    vl_logic_vector(31 downto 0);
        cnt_write_hits  : out    vl_logic_vector(31 downto 0);
        cnt_misses      : out    vl_logic_vector(31 downto 0);
        cnt_read_misses : out    vl_logic_vector(31 downto 0);
        cnt_write_misses: out    vl_logic_vector(31 downto 0);
        cnt_writebacks  : out    vl_logic_vector(31 downto 0);
        cnt_stall_cycles: out    vl_logic_vector(31 downto 0);
        cnt_mem_traffic : out    vl_logic_vector(31 downto 0)
    );
end dcache_min_perf_counters;
