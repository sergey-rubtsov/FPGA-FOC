`timescale 1us/1ns
module tb_mt6835_spi_reader;
    reg clk = 0;
    reg rst = 0;
    reg start = 0;
    wire ready;
    wire csn, sck, mosi;
    reg  miso = 0;
    wire [15:0] data_out;

    mt6835_spi_reader dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .ready(ready),
        .data_out(data_out),
        .csn(csn),
        .sck(sck),
        .mosi(mosi),
        .miso(miso)
    );

    // генерация тактов (50 МГц)
    //always #(13563) clk = ~clk;   // 36.864MHz
    always #10 clk = ~clk;

    // виртуальный угол (постоянное вращение вала)
    reg [15:0] sensor_value = 16'h0000;
    always @(posedge clk) begin
            sensor_value <= sensor_value + 1;
            // скорость вращения: 0x0100 ~ 1.4 градуса/шаг
            if (sensor_value >= 16'hFFFF)
               sensor_value <= 16'h0000; // переполнение

        //sensor_value <= sensor_value + 16'h2000;
        // скорость вращения: 0x0100 ~ 1.4 градуса/шаг
        //if (sensor_value >= 16'hFFFF)
           //sensor_value <= 16'h0000; // переполнение
    end

    // SPI модель: при начале транзакции захватываем текущий угол
    reg [23:0] sensor_shift;
    always @(negedge csn) begin
        sensor_shift <= {8'h00, sensor_value};
    end
    always @(posedge sck) begin
        if (!csn) begin
            miso <= sensor_shift[23];
            sensor_shift <= {sensor_shift[22:0], 1'b0};
        end
    end

    // вычисление угла (0..360°)
    real angle_deg;
    always @(posedge ready) begin
        angle_deg = data_out * 360.0 / 65536.0;
        $display("t=%0t ns  raw=0x%h  angle=%.2f deg", $time, data_out, angle_deg);
    end

    // тест
    integer i;
    initial begin
        $dumpfile("mt6835.vcd");
        $dumpvars(0, tb_mt6835_spi_reader);

        rst = 1; #5000; rst = 0;

        // 100 последовательных чтений
        for (i = 0; i < 100; i = i + 1) begin
            #1000 start = 1; #200 start = 0;   // запуск SPI
            #5000; // ждём готовности
        end

        #20000;
        $finish;
    end
endmodule
