// Apple //e Memory Subsystem (RAM and ROMs) for Tang Nano 20K
// 64KB RAM (32 SP blocks), 16KB System ROM (8 SP blocks), 8KB Character ROM (4 SP blocks)

module apple2_system_rom (
    input  wire        clk,
    input  wire [13:0] addr, // 16KB space (0x0000 = $C000, 0x3FFF = $FFFF)
    output reg  [7:0]  dout
);
    reg [7:0] mem [0:16383];

    initial begin
        $readmemh("roms/apple2e_rom.hex", mem);
    end

    always @(posedge clk) begin
        dout <= mem[addr];
    end
endmodule


module apple2_char_rom (
    input  wire        clk,
    input  wire [11:0] addr, // 4KB primary bank
    output reg  [7:0]  dout
);
    reg [7:0] mem [0:8191];

    initial begin
        $readmemh("roms/apple2e_char.hex", mem);
    end

    always @(posedge clk) begin
        dout <= mem[addr];
    end
endmodule


module apple2_ram_64k (
    input  wire        clk,
    input  wire [15:0] addr,
    input  wire [7:0]  din,
    input  wire        we,
    output reg  [7:0]  dout
);
    reg [7:0] mem [0:65535];
`ifndef SYNTHESIS
    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1)
            mem[i] = 8'h00;
    end
`endif

    always @(posedge clk) begin
        if (we)
            mem[addr] <= din;
        dout <= mem[addr];
    end
endmodule
