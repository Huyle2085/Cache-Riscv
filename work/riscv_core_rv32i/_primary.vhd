library verilog;
use verilog.vl_types.all;
entity riscv_core_rv32i is
    generic(
        RESET_PC        : integer := 0
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        imem_addr       : out    vl_logic_vector(31 downto 0);
        imem_rdata      : in     vl_logic_vector(31 downto 0);
        dcache_req      : out    vl_logic;
        dcache_we       : out    vl_logic;
        dcache_wstrb    : out    vl_logic_vector(3 downto 0);
        dcache_addr     : out    vl_logic_vector(31 downto 0);
        dcache_wdata    : out    vl_logic_vector(31 downto 0);
        dcache_rdata    : in     vl_logic_vector(31 downto 0);
        dcache_stall    : in     vl_logic;
        dcache_ready    : in     vl_logic;
        halted          : out    vl_logic;
        cycle_cnt       : out    vl_logic_vector(31 downto 0);
        instr_cnt       : out    vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of RESET_PC : constant is 1;
end riscv_core_rv32i;
