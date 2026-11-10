library verilog;
use verilog.vl_types.all;
entity dcache_min_datapath is
    generic(
        ADDR_WIDTH      : integer := 32;
        DATA_WIDTH      : integer := 32;
        NUM_SETS        : integer := 64;
        INDEX_BITS      : integer := 6;
        OFFSET_BITS     : integer := 2;
        TAG_BITS        : vl_notype
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        cpu_we          : in     vl_logic;
        cpu_wstrb       : in     vl_logic_vector(3 downto 0);
        cpu_addr        : in     vl_logic_vector;
        cpu_wdata       : in     vl_logic_vector;
        cpu_rdata       : out    vl_logic_vector;
        mem_addr        : out    vl_logic_vector;
        mem_wdata       : out    vl_logic_vector;
        mem_rdata       : in     vl_logic_vector;
        dp_hit_read     : in     vl_logic;
        dp_hit_write    : in     vl_logic;
        dp_wb_start     : in     vl_logic;
        dp_alloc_start  : in     vl_logic;
        dp_alloc_done   : in     vl_logic;
        cache_hit       : out    vl_logic;
        victim_dirty    : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of ADDR_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of DATA_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of NUM_SETS : constant is 1;
    attribute mti_svvh_generic_type of INDEX_BITS : constant is 1;
    attribute mti_svvh_generic_type of OFFSET_BITS : constant is 1;
    attribute mti_svvh_generic_type of TAG_BITS : constant is 3;
end dcache_min_datapath;
