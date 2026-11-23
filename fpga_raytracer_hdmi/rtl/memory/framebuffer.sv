module framebuffer #(
    parameter int WIDTH_PX   = 160,
    parameter int HEIGHT_PX  = 120,
    parameter int DATA_WIDTH = 24
) (
    input  logic                      clk,
    input  logic                      we,
    input  logic [$clog2(WIDTH_PX*HEIGHT_PX)-1:0] waddr,
    input  logic [DATA_WIDTH-1:0]     wdata,
    input  logic [$clog2(WIDTH_PX*HEIGHT_PX)-1:0] raddr,
    output logic [DATA_WIDTH-1:0]     rdata
);
    localparam int DEPTH = WIDTH_PX * HEIGHT_PX;

    (* ram_style = "block" *)
    logic [DATA_WIDTH-1:0] mem [DEPTH];

    // power-up contents = black (Vivado infers this as the BRAM init value; also keeps simulation free of X)
    initial for (int i = 0; i < DEPTH; i++) mem[i] = '0;

    always_ff @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    always_ff @(posedge clk) begin
        rdata <= mem[raddr];
    end
endmodule
