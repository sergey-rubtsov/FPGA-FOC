module top (
    input  wire i_clk,       // системная частота, например 26 MHz
    input  wire i_rst,       // глобальный сброс

    // SPI
    output reg  spi_clk = 0,
    output reg  spi_mosi = 1,
    output reg  spi_cs   = 1,
    input  wire spi_miso,

    // семисегментные индикаторы
    output wire [6:0] o_segments,
    output wire       o_sel
);

// ==============================
    // Настройки
    // ==============================
    parameter CLK_DIV = 8; // делитель тактовой частоты для SPI
    reg [$clog2(CLK_DIV)-1:0] clk_cnt = 0;

    reg [20:0] angle_raw;

    // Состояния
    localparam ST_IDLE   = 0,
               ST_CMD    = 1,
               ST_READ   = 2,
               ST_DONE   = 3;

    reg [2:0] state = ST_IDLE;
    reg [5:0] bit_cnt = 0;

    reg [15:0]  tx_shift;   // команда (0x83)
    reg [31:0] rx_shift;   // приём данных
    reg [2:0]  status;
    reg [7:0]  crc;
reg [3:0] wait_cnt;

    // ==============================
    // Генерация SPI clock
    // ==============================
    always @(posedge i_clk) begin
        if (clk_cnt == CLK_DIV-1) begin
            clk_cnt <= 0;
            spi_clk <= ~spi_clk;
        end else begin
            clk_cnt <= clk_cnt + 1;
        end
    end

    // ==============================
    // Основная логика SPI
    // ==============================
    always @(posedge i_clk) begin
        case (state)
            // Ждём - потом сразу начинаем транзакцию
            ST_IDLE: begin
                spi_cs   <= 1'b1;
                spi_mosi <= 1'b1;
                bit_cnt  <= 0;
                rx_shift <= 0;

                // Запуск транзакции
                state    <= ST_CMD;
                spi_cs   <= 1'b0;
            end

            // Передаём команду
            ST_CMD: begin
                if (spi_clk == 1'b0 && clk_cnt == 0) begin
                    tx_shift <= {4'b1010, 12'h003};   // команда "read angle"
                    spi_mosi <= tx_shift[15];
                    tx_shift <= {tx_shift[14:0], 1'b0};
                    bit_cnt  <= bit_cnt + 1;
                    if (bit_cnt == 15) begin
                        state   <= ST_READ;
                    end
                end
            end

            ST_READ: begin
                if (spi_clk == 1'b1 && clk_cnt == 0) begin
                    rx_shift <= {rx_shift[30:0], spi_miso};
                    bit_cnt  <= bit_cnt + 1;
                    if (bit_cnt == 31) begin
                        // Собираем данные
                        angle_raw <= rx_shift[31:11];
                        status <= rx_shift[10:8];
                        crc <= rx_shift[7:0];
                        state <= ST_DONE;
                    end
                end
            end



ST_DONE: begin
    spi_cs <= 1'b1;
    if (wait_cnt < 4'd1) begin  // подождать 1 такт
        wait_cnt <= wait_cnt + 1;
    end else begin
        wait_cnt <= 0;
        state    <= ST_IDLE;
    end
end


        endcase
    end

    // ==============================
    // Перевод в градусы
    // ==============================
    reg [8:0] angle_deg; // 0–359

    always @(posedge i_clk) begin
        // простая целочисленная аппроксимация
        // angle_raw * 360 >> 21
        angle_deg <= (angle_raw * 360) >> 21;
    end


endmodule
