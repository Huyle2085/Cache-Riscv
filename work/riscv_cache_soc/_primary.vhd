library verilog;
use verilog.vl_types.all;
entity riscv_cache_soc is
    generic(
        WAYS            : integer := 2;
        NUM_SETS        : integer := 64;
        IMEM_WORDS      : integer := 256;
        IMEM_INIT_FILE  : string  := "sw/program.hex"
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        cache_flush     : in     vl_logic;
        cache_invalidate: in     vl_logic;
        maint_done      : out    vl_logic;
        mem_req         : out    vl_logic;
        mem_we          : out    vl_logic;
        mem_wstrb       : out    vl_logic_vector(3 downto 0);
        mem_addr        : out    vl_logic_vector(31 downto 0);
        mem_wdata       : out    vl_logic_vector(31 downto 0);
        mem_rdata       : in     vl_logic_vector(31 downto 0);
        mem_ready       : in     vl_logic;
        cpu_halted      : out    vl_logic;
        cpu_cycles      : out    vl_logic_vector(31 downto 0);
        cpu_instrs      : out    vl_logic_vector(31 downto 0);
        cnt_accesses    : out    vl_logic_vector(31 downto 0);
        cnt_misses      : out    vl_logic_vector(31 downto 0);
        cnt_stall_cycles: out    vl_logic_vector(31 downto 0);
        cnt_mem_traffic : out    vl_logic_vector(31 downto 0);
        cnt_coherence_cyc: out    vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WAYS : constant is 1;
    attribute mti_svvh_generic_type of NUM_SETS : constant is 1;
    attribute mti_svvh_generic_type of IMEM_WORDS : constant is 1;
    attribute mti_svvh_generic_type of IMEM_INIT_FILE : constant is 1;
end riscv_cache_soc;
