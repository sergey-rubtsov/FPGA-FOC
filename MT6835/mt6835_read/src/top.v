module top #(
    parameter CLK_DIV = 16    // делитель частоты SPI
)(
    input  wire        i_rst,
    input  wire        i_clk,
    // -------------------- SPI интерфейс --------------------
    output reg         spi_cs,
    output reg         spi_sck,
    output reg         spi_mosi,
    input  wire        spi_miso,
    // -------------------- Логика пользователя --------------
    output reg         o_valid,       // готовность результата (импульс 1 такт)
    output reg [20:0]  o_angle,       // угол (21 бит)
    output reg [15:0]  o_angle_deg,   // угол в градусах *100 (фикс. точка)
    output reg [2:0]   o_status,      // статус
    output reg [7:0]   o_crc,         // CRC от чипа
    output reg         o_crc_ok       // 1 = CRC совпал, 0 = ошибка
);

    // ==============================
    // Внутренние регистры
    // ==============================
    reg [$clog2(CLK_DIV)-1:0] clk_cnt = 0;

    localparam ST_IDLE  = 0,
               ST_CMD   = 1,
               ST_READ  = 2,
               ST_DONE  = 3,
               ST_WAIT  = 4;

    reg [2:0] state;
    reg [5:0] bit_cnt;
    reg [15:0] tx_shift;
    reg [15:0] rx_shift;
    reg [2:0]  byte_cnt; // 0..3 для байтов 0x003..0x006

    reg [7:0] dbg_b0, dbg_b1, dbg_b2, dbg_b3;

    // Временное хранилище для CRC-вычисления
    reg [7:0] crc_calc;

    // ==============================
    // Генерация SPI тактов
    // ==============================
    always @(posedge i_clk or negedge i_rst) begin
        if(!i_rst) begin
            clk_cnt <= 0;
            spi_sck <= 1'b0;
        end else begin
            if (clk_cnt == CLK_DIV-1) begin
                clk_cnt <= 0;
                spi_sck <= ~spi_sck;
            end else begin
                clk_cnt <= clk_cnt + 1;
            end
        end
    end

    // ==============================
    // CRC-8 функция
    // ==============================
    function [7:0] crc8_update;
        input [7:0] crc_in;
        input [7:0] data;
        integer i;
        reg [7:0] crc;
    begin
        crc = crc_in ^ data;
        for (i=0; i<8; i=i+1) begin
            if (crc[7])
                crc = (crc << 1) ^ 8'h07;
            else
                crc = (crc << 1);
        end
        crc8_update = crc;
    end
    endfunction

    // ==============================
    // FSM
    // ==============================
    always @(posedge i_clk or negedge i_rst) begin
        if(!i_rst) begin
            state      <= ST_IDLE;
            spi_cs     <= 1'b1;
            spi_mosi   <= 1'b1;
            bit_cnt    <= 0;
            byte_cnt   <= 0;
            rx_shift   <= 0;
            o_angle    <= 0;
            o_angle_deg<= 0;
            o_status   <= 0;
            o_crc      <= 0;
            o_crc_ok   <= 0;
            o_valid    <= 0;
            crc_calc   <= 0;
        end else begin
            o_valid <= 1'b0; // по умолчанию
            case (state)

                // ---------------- IDLE ----------------
                ST_IDLE: begin
                    spi_cs   <= 1'b1;
                    bit_cnt  <= 0;
                    byte_cnt <= 0;
                    crc_calc <= 8'h00;     // сброс CRC
                    spi_cs   <= 1'b0;      // старт транзакции
                    tx_shift <= {4'b1010, 12'h003}; // команда burst read
                    state    <= ST_CMD;
                end

                // ---------------- отправляем 16 бит команды ----------------
                ST_CMD: begin
                    if (spi_sck == 1'b0 && clk_cnt == 0) begin
                        spi_mosi <= tx_shift[15];
                        tx_shift <= {tx_shift[14:0], 1'b0};
                        bit_cnt  <= bit_cnt + 1;
                        if (bit_cnt == 15) begin
                            bit_cnt  <= 0;
                            byte_cnt <= 0;
                            state    <= ST_READ;
                        end
                    end
                end

                // ---------------- читаем 4 байта подряд ----------------
                ST_READ: begin
                    if (spi_sck == 1'b0 && clk_cnt == 0) begin
                        rx_shift <= {rx_shift[14:0], spi_miso};
                        bit_cnt  <= bit_cnt + 1;
                        if (bit_cnt == 15) begin
                            case (byte_cnt)
                                0: begin
                                       o_angle[20:13] <= rx_shift[7:0];
                                       dbg_b0 <= rx_shift[7:0];
                                       crc_calc <= crc8_update(crc_calc, rx_shift[7:0]);
                                   end
                                1: begin
                                       o_angle[12:5]  <= rx_shift[7:0];
                                       dbg_b1 <= rx_shift[7:0];
                                       crc_calc <= crc8_update(crc_calc, rx_shift[7:0]);
                                   end
                                2: begin
                                       o_angle[4:0]   <= rx_shift[7:3];
                                       dbg_b2 <= rx_shift[7:0];
                                       crc_calc <= crc8_update(crc_calc, rx_shift[7:0]);
                                   end
                                3: begin
                                       dbg_b3   <= rx_shift[7:0];
                                       o_status <= rx_shift[2:0];
                                       o_crc    <= rx_shift[7:0];
                                       // финальная проверка CRC
                                       o_crc_ok <= (crc8_update(crc_calc, rx_shift[7:0]) == 8'h00);
                                   end
                            endcase
                            byte_cnt <= byte_cnt + 1;
                            bit_cnt  <= 0;

                            if (byte_cnt == 3) begin
                                state <= ST_DONE;
                            end
                        end
                    end

                    // MOSI во время чтения держим в 0
                    if (spi_sck == 1'b0 && clk_cnt == 0) begin
                        spi_mosi <= 1'b0;
                    end
                end

                // ---------------- конец транзакции ----------------
                ST_DONE: begin
                    spi_cs  <= 1'b1;
                    o_valid <= 1'b1;

                    // пересчёт угла в градусы *100
                    // угол = (o_angle * 36000) >> 21
                    o_angle_deg <= (o_angle * 16'd36000) >> 21;

                    state   <= ST_WAIT;
                end

                // ---------------- пауза ----------------
                ST_WAIT: begin
                    if (spi_sck == 1'b1 && clk_cnt == 0) begin
                        bit_cnt <= bit_cnt + 1;
                        if (bit_cnt == 2) begin
                            state   <= ST_IDLE;
                        end
                    end
                end

            endcase
        end
    end

endmodule
