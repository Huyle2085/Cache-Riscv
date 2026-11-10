library verilog;
use verilog.vl_types.all;
entity dcache_minimal is
    generic(
        ADDR_WIDTH      : integer := 32;
        DATA_WIDTH      : integer := 32;
        NUM_SETS        : integer := 64;
        INDEX_BITS      : integer := 6
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        cpu_req         : in     vl_logic;
        cpu_we          : in     vl_logic;
        cpu_wstrb       : in     vl_logic_vector(3 downto 0);
        cpu_addr        : in     vl_logic_vector;
        cpu_wdata       : in     vl_logic_vector;
        cpu_rdata       : out    vl_logic_vector;
        cpu_stall       : out    vl_logic;
        cpu_ready       : out    vl_logic;
        mem_req         : out    vl_logic;
        mem_we          : out    vl_logic;
        mem_addr        : out    vl_logic_vector;
        mem_wdata       : out    vl_logic_vector;
        mem_rdata       : in     vl_logic_vector;
        mem_ready       : in     vl_logic;
        cnt_accesses    : out    vl_logic_vector(31 downto 0);
        cnt_hits        : out    vl_logic_vector(31 downto 0);
        cnt_read_hits   : out    vl_logic_vector(31 downto 0);
        cnt_write_hits  : out    vl_logic_vector(31 downto 0);
        cnt_misses      : out    vl_logic_vector(31 downto 0);
        cnt_read_misses : out    vl_logic_vector(31 downto 0);
        cnt_write_misses: out    vl_logic_vector(31 downto 0);
        cnt_writebacks  : out    vl_logic_vector(31 downto 0);
        cnt_stall_cycles: out    vl_logic_vector(31 downto 0);
        cnt_mem_traffic : out    vl_logic_vector(31 downto 0);
        dbg_state       : out    vl_logic_vector(1 downto 0);
        dbg_cache_hit   : out    vl_logic;
        dbg_victim_dirty: out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of ADDR_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of DATA_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of NUM_SETS : constant is 1;
    attribute mti_svvh_generic_type of INDEX_BITS : constant is 1;
end dcache_minimal;
