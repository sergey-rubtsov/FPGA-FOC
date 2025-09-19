module top #(
    parameter CLK_DIV = 8    // делитель частоты SPI (подбирай под свою тактовую частоту)
)(
    input  wire        i_rst,
    input  wire        i_clk,
    // -------------------- SPI интерфейс ------------------------------------------------
    output reg         spi_cs,
    output reg         spi_sck,
    output reg         spi_mosi,
    input  wire        spi_miso,
    // -------------------- Логика пользователя ------------------------------------------
    //input  wire        i_start,      // запуск burst чтения (один импульс)
    output reg         o_valid,      // готовность результата (импульс 1 такт)
    output reg [20:0]  o_angle,      // угол (21 бит)
    output reg [2:0]   o_status,     // статус
    output reg [7:0]   o_crc         // CRC от чипа
);

    // FSM
    localparam ST_IDLE  = 0,
               ST_CMD   = 1,
               ST_READ  = 2,
               ST_DONE  = 3,
               ST_WAIT  = 4;

    reg [2:0] state;
    reg [7:0] clk_cnt;
    reg       sck_pre;
    reg [5:0] bit_cnt;

    reg [7:0]  tx_cmd;     // команда
    reg [31:0] rx_shift;   // сдвиг для данных
    reg [31:0] rx_latch;   // зафиксированные данные

    // SPI clock divider
    always @(posedge i_clk or negedge i_rst) begin
        if(!i_rst) begin
            clk_cnt <= 0;
            sck_pre <= 1'b0;
        end else begin
            if(clk_cnt == CLK_DIV-1) begin
                clk_cnt <= 0;
                sck_pre <= ~sck_pre;
            end else begin
                clk_cnt <= clk_cnt + 1;
            end
        end
    end

    always @(posedge i_clk or negedge i_rst) begin
        if(!i_rst) begin
            state    <= ST_IDLE;
            spi_cs   <= 1'b1;
            spi_sck  <= 1'b0;
            spi_mosi <= 1'b1;
            bit_cnt  <= 0;
            rx_shift <= 0;
            rx_latch <= 0;
            o_angle  <= 0;
            o_status <= 0;
            o_crc    <= 0;
            o_valid  <= 0;
        end else begin
            spi_sck <= sck_pre;
            o_valid <= 1'b0;

            case(state)
                ST_IDLE: begin
                    spi_cs <= 1'b1;
                    spi_mosi <= 1'b1;
                    bit_cnt <= 0;
                    //if(i_start) begin
                        tx_cmd <= 8'h83;   // команда READ ANGLE
                        state  <= ST_CMD;
                        spi_cs <= 1'b0;
                    //end
                end

                ST_CMD: begin
                    if(sck_pre == 1'b0 && clk_cnt == 0) begin
                        spi_mosi <= tx_cmd[7];
                        tx_cmd   <= {tx_cmd[6:0],1'b0};
                        bit_cnt  <= bit_cnt + 1;
                        if(bit_cnt == 7) begin
                            bit_cnt <= 0;
                            state   <= ST_READ;
                        end
                    end
                end

                ST_READ: begin
                    if(sck_pre == 1'b1 && clk_cnt == 0) begin
                        rx_shift <= {rx_shift[30:0], spi_miso};
                        bit_cnt  <= bit_cnt + 1;
                        if(bit_cnt == 31) begin
                            rx_latch <= {rx_shift[30:0], spi_miso};
                            state    <= ST_DONE;
                        end
                    end
                end

                ST_DONE: begin
                    spi_cs   <= 1'b1;
                    o_angle  <= rx_latch[31:11];
                    o_status <= rx_latch[10:8];
                    o_crc    <= rx_latch[7:0];
                    o_valid  <= 1'b1;
                    state    <= ST_WAIT;   // вернуться в ожидание
                end

                ST_WAIT: begin
                    if(sck_pre == 1'b1 && clk_cnt == 0) begin
                        //spi_cs   <= 1'b1;
                        bit_cnt  <= bit_cnt + 1;
                        if(bit_cnt == 32) begin
                            state    <= ST_IDLE;   // вернуться в ожидание
                        end
                    end
                end
            endcase
        end
    end

endmodule
