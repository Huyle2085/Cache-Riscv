library verilog;
use verilog.vl_types.all;
entity var_latency_mem is
    generic(
        ADDR_WIDTH      : integer := 32;
        DATA_WIDTH      : integer := 32;
        MEM_WORDS       : integer := 16384;
        BASE_DELAY      : vl_logic_vector(0 to 2) := (Hi0, Hi1, Hi0);
        VAR_ENABLE      : integer := 1
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        mem_req         : in     vl_logic;
        mem_we          : in     vl_logic;
        mem_wstrb       : in     vl_logic_vector(3 downto 0);
        mem_addr        : in     vl_logic_vector;
        mem_wdata       : in     vl_logic_vector;
        mem_rdata       : out    vl_logic_vector;
        mem_ready       : out    vl_logic;
        addr_error      : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of ADDR_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of DATA_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of MEM_WORDS : constant is 1;
    attribute mti_svvh_generic_type of BASE_DELAY : constant is 1;
    attribute mti_svvh_generic_type of VAR_ENABLE : constant is 1;
end var_latency_mem;
