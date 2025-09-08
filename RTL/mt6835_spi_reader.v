module mt6835_spi_reader (
    input  wire clk,        // системная частота, например 50 МГц
    input  wire rst,        // сброс
    input  wire start,      // запуск чтения
    output reg  ready,      // данные готовы
    output reg [15:0] data_out, // результат (угол)

    // SPI линии
    output reg csn,
    output reg sck,
    output reg mosi,
    input  wire miso
);

    parameter CMD = 8'h83;   // команда чтения угла
    parameter CLK_DIV = 4;   // делитель для SCK

    reg [7:0] clk_cnt;
    reg [7:0] bit_cnt;
    reg [23:0] shift_reg;
    reg busy;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            csn      <= 1'b1;
            sck      <= 1'b1;  // Mode 3: CPOL=1
            mosi     <= 1'b0;
            clk_cnt  <= 0;
            bit_cnt  <= 0;
            busy     <= 0;
            ready    <= 0;
            data_out <= 16'd0;
            shift_reg <= 24'd0;
        end else begin
            ready <= 0;

            if (start && !busy) begin
                // старт транзакции
                busy      <= 1;
                csn       <= 0;
                shift_reg <= {CMD, 16'd0};  // команда + место под данные
                bit_cnt   <= 8'd24;
                sck       <= 1'b1;
                clk_cnt   <= 0;
            end else if (busy) begin
                clk_cnt <= clk_cnt + 1;

                if (clk_cnt == (CLK_DIV/2)) begin
                    sck <= 0; // спадающий фронт
                    mosi <= shift_reg[23];
                end

                if (clk_cnt == CLK_DIV) begin
                    clk_cnt <= 0;
                    sck <= 1; // восходящий фронт

                    // сдвиг
                    shift_reg <= {shift_reg[22:0], miso};
                    bit_cnt <= bit_cnt - 1;

                    if (bit_cnt == 0) begin
                        busy <= 0;
                        csn  <= 1;
                        data_out <= shift_reg[15:0];
                        ready <= 1;
                    end
                end
            end
        end
    end
endmodule
