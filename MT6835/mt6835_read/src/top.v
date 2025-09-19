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
    output reg         o_valid,      // готовность результата (импульс 1 такт)
    output reg [20:0]  o_angle,      // угол (21 бит)
    output reg [2:0]   o_status,     // статус
    output reg [7:0]   o_crc         // CRC от чипа
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
    reg [1:0]  reg_index;  // 0..3 для регистров 0x003..0x006

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
    // FSM
    // ==============================
    always @(posedge i_clk or negedge i_rst) begin
        if(!i_rst) begin
            state    <= ST_IDLE;
            spi_cs   <= 1'b1;
            spi_mosi <= 1'b1;
            bit_cnt  <= 0;
            reg_index<= 0;
            rx_shift <= 0;
            o_angle  <= 0;
            o_status <= 0;
            o_crc    <= 0;
            o_valid  <= 0;
        end else begin
            o_valid <= 1'b0; // по умолчанию сбрасываем
            case (state)

                ST_IDLE: begin
                    spi_cs   <= 1'b1;
                    bit_cnt  <= 0;
                    reg_index<= 0;
                    spi_cs   <= 1'b0;  // старт транзакции
                    tx_shift <= {4'b1010, 12'h003}; // первый запрос (0x003)
                    state    <= ST_CMD;
                end

                ST_CMD: begin
                    if (spi_sck == 1'b0 && clk_cnt == 0) begin
                        spi_mosi <= tx_shift[15];
                        tx_shift <= {tx_shift[14:0], 1'b0};
                        bit_cnt  <= bit_cnt + 1;
                        if (bit_cnt == 15) begin
                            bit_cnt <= 0;
                            state   <= ST_READ;
                        end
                    end
                end

                ST_READ: begin
                    if (spi_sck == 1'b1 && clk_cnt == 0) begin
                        rx_shift <= {rx_shift[14:0], spi_miso};
                        bit_cnt  <= bit_cnt + 1;
                        if (bit_cnt == 15) begin
                            // один байт принят
                            case (reg_index)
                                0: o_angle[20:13] <= rx_shift[7:0];   // старшие биты
                                1: o_angle[12:5]  <= rx_shift[7:0];
                                2: o_angle[4:0]   <= rx_shift[7:3];
                                3: begin
                                       o_status <= rx_shift[2:0];
                                       o_crc    <= rx_shift[7:0]; // при желании сюда CRC
                                   end
                            endcase

                            reg_index <= reg_index + 1;
                            bit_cnt   <= 0;

                            if (reg_index == 3) begin
                                state <= ST_DONE; // все регистры вычитаны
                            end else begin
                                tx_shift <= {4'b1010, (12'h003 + reg_index + 1)};
                                state    <= ST_CMD;
                            end
                        end
                    end
                end

                ST_DONE: begin
                    spi_cs  <= 1'b1;   // подняли CS — транзакция завершена
                    o_valid <= 1'b1;   // данные готовы
                    bit_cnt <= 0;
                    state   <= ST_WAIT;
                end

                ST_WAIT: begin
                    // маленькая пауза, чтобы CS подержать high
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
