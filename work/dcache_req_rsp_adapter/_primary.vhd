library verilog;
use verilog.vl_types.all;
entity dcache_req_rsp_adapter is
    generic(
        ADDR_WIDTH      : integer := 32;
        DATA_WIDTH      : integer := 32
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        req_valid       : in     vl_logic;
        req_ready       : out    vl_logic;
        req_we          : in     vl_logic;
        req_wstrb       : in     vl_logic_vector(3 downto 0);
        req_addr        : in     vl_logic_vector;
        req_wdata       : in     vl_logic_vector;
        rsp_valid       : out    vl_logic;
        rsp_rdata       : out    vl_logic_vector;
        cpu_req         : out    vl_logic;
        cpu_req_ready   : in     vl_logic;
        cpu_we          : out    vl_logic;
        cpu_wstrb       : out    vl_logic_vector(3 downto 0);
        cpu_addr        : out    vl_logic_vector;
        cpu_wdata       : out    vl_logic_vector;
        cpu_rdata       : in     vl_logic_vector;
        cpu_ready       : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of ADDR_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of DATA_WIDTH : constant is 1;
end dcache_req_rsp_adapter;
