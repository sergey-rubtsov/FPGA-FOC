module mt6835_burst_read (
    input  wire        i_clk, // системный такт
    input  wire        rstn,  // активный низкий reset
    // SPI интерфейс
    output wire        spi_clk,
    output wire        spi_cs,
    output wire        spi_mosi,
    input  wire        spi_miso,

    // результат
    output reg [20:0]  phi_21,  // 21-битный угол
    output reg [11:0]  phi      // 12-битный угол
);

    // ---------------------
    // Параметры команды / длины
    // ---------------------
    localparam CMD_BYTE0 = 8'hA0; // MSB команды {4'b1010, addr[11:8]}  (пример для addr=0x003)
    localparam CMD_BYTE1 = 8'h03; // LSB команды (addr[7:0])
    localparam CMD_BYTES = 2;     // 2 байта команды (16 бит = 4b cmd + 12b addr)
    localparam DATA_BYTES = 4;    // ожидаем 4 байта от R3..R6 (32 бит, из них 21 - angle)
    localparam TOTAL_BYTES = CMD_BYTES + DATA_BYTES; // всего байтов в транзакции

    // ---------------------
    // Сигналы к SPI_Master
    // ---------------------
    reg  [7:0]  tx_byte;
    reg         tx_dv;
    wire        tx_ready;
    wire        rx_dv;
    wire [7:0]  rx_byte;

    // ---------------------
    // CS регистр и публичный вывод
    // ---------------------
    reg cs_reg;
    assign spi_cs = cs_reg;

    // ---------------------
    // SPI Master
    // ---------------------
    SPI_Master #(
        .SPI_MODE(3),
        .CLKS_PER_HALF_BIT(8) // подогнать под частоту, у тебя примерно 26 MHz -> выбирай подвид
    ) spi_i (
        .i_Rst_L(rstn),
        .i_Clk(i_clk),
        .i_TX_Byte(tx_byte),
        .i_TX_DV(tx_dv),
        .o_TX_Ready(tx_ready),
        .o_RX_DV(rx_dv),
        .o_RX_Byte(rx_byte),
        .o_SPI_Clk(spi_clk),
        .i_SPI_MISO(spi_miso),
        .o_SPI_MOSI(spi_mosi)
    );

    // ---------------------
    // FSM для burst read
    // ---------------------
    localparam S_IDLE       = 0;
    localparam S_ASSERT_CS  = 1;
    localparam S_SEND_BYTE  = 2;
    localparam S_WAIT_RX    = 3;
    localparam S_DONE_CSUP  = 4;
    localparam S_GAP        = 5;

    reg [2:0] state;
    reg [3:0] byte_idx;                  // индекс текущего байта 0..TOTAL_BYTES-1
    reg [7:0] data_bytes [0:DATA_BYTES-1]; // примем данные сюда
    reg [7:0] saved_cmd0, saved_cmd1;
    reg [15:0] gap_cnt;
    localparam GAP_CYCLES = 16; // пауза между burst (подогнать по необходимости)

    // Инициализация регистров при reset
    integer i;
    always @(posedge i_clk or negedge rstn) begin
        if (!rstn) begin
            state     <= S_IDLE;
            cs_reg    <= 1'b1;
            tx_byte   <= 8'h00;
            tx_dv     <= 1'b0;
            byte_idx  <= 0;
            phi_21     <= 21'd0;
            gap_cnt   <= 0;
            saved_cmd0 <= CMD_BYTE0;
            saved_cmd1 <= CMD_BYTE1;
            for (i=0; i<DATA_BYTES; i=i+1) data_bytes[i] <= 8'h00;
        end else begin
            // default: tx_dv only one cycle pulses
            tx_dv <= 1'b0;

            case (state)
                S_IDLE: begin
                    cs_reg <= 1'b1;
                    if (gap_cnt == 0) begin
                        // начинаем новую burst-транзакцию
                        state    <= S_ASSERT_CS;
                        // сохранённые байты команды
                        saved_cmd0 <= CMD_BYTE0;
                        saved_cmd1 <= CMD_BYTE1;
                    end else begin
                        gap_cnt <= gap_cnt - 1;
                    end
                end

                S_ASSERT_CS: begin
                    // опускаем CS и ждём один такт, чтобы устройство успело latch данные
                    cs_reg   <= 1'b0;
                    byte_idx <= 0;
                    // гарантируем, что прошлые данные стёрты
                    for (i=0; i<DATA_BYTES; i=i+1) data_bytes[i] <= 8'h00;
                    state <= S_SEND_BYTE;
                end

                S_SEND_BYTE: begin
                    // Отправляем следующий байт, но только если мастер готов (o_TX_Ready==1)
                    if (tx_ready) begin
                        // решаем, что отправлять: командный байт или dummy (0x00) для чтения
                        if (byte_idx == 0) begin
                            tx_byte <= saved_cmd0; // MSB команды
                        end else if (byte_idx == 1) begin
                            tx_byte <= saved_cmd1; // LSB команды
                        end else begin
                            tx_byte <= 8'h00;      // dummy, чтобы вытянуть данные
                        end
                        tx_dv   <= 1'b1; // однотактный импульс для SPI_Master
                        state   <= S_WAIT_RX;
                    end
                end

                S_WAIT_RX: begin
                    // Ждём, когда SPI_Master выдаст o_RX_DV — это означает, что этот байт принят и rx_byte валиден
                    if (rx_dv) begin
                        // если пришёл байт данных (после командных байтов) — сохраняем
                        if (byte_idx >= CMD_BYTES) begin
                            data_bytes[byte_idx - CMD_BYTES] <= rx_byte;
                        end
                        // увеличиваем индекс байта
                        if (byte_idx == (TOTAL_BYTES - 1)) begin
                            // получили последний байт — переходим в DONE
                            state <= S_DONE_CSUP;
                        end else begin
                            byte_idx <= byte_idx + 1;
                            state <= S_SEND_BYTE; // отправляем следующий байт
                        end
                    end
                end

                S_DONE_CSUP: begin
                    // Поднимаем CS — транзакция закончена
                    cs_reg <= 1'b1;
                    // Собираем 32-битное слово из 4 принятых байтов: data_bytes[0]..[3]
                    // Предполагаем, что data_bytes[0] — старший байт (MSB)
                    // angle = {data_bytes[0],data_bytes[1],data_bytes[2],data_bytes[3]}[31:11]
                    phi_21 <= { data_bytes[0], data_bytes[1], data_bytes[2], data_bytes[3] } >> 11;
                    // перевод в 12 битный угол (диапазон 0 - 4095)
                    phi <= phi_21[20:9];
                    // задаём паузу перед следующей транзакцией
                    gap_cnt <= GAP_CYCLES;
                    state <= S_GAP;
                end

                S_GAP: begin
                    if (gap_cnt == 0) begin
                        state <= S_IDLE;
                    end else begin
                        gap_cnt <= gap_cnt - 1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
