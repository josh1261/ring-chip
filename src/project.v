/*
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * 링오실레이터 측정 칩 (v0 초안)
 *
 * 칩 안에 셀 종류가 다른 링오실레이터 3개를 넣고, 칩 안의 카운터로
 * "정해진 시간(clk 기준) 동안 몇 번 진동했는지"를 세어 핀으로 읽어 낸다.
 *   주파수 f = 카운트 / (게이트 클럭 수 / f_clk)
 *   한 단 지연 t_pd = 1 / (2 * 단수 * f)
 *
 * 핀
 *   ui[1:0]  링 선택: 0 = 인버터 51단, 1 = NAND2 41단, 2 = NOR2 41단, 3 = 끔
 *   ui[2]    링 켜기 (1 = 진동)
 *   ui[3]    측정 시작 (0 -> 1 로 올리면 한 번 측정)
 *   ui[5:4]  읽을 바이트: 0 = 카운트 하위, 1 = 중간, 2 = 상위, 3 = 상태
 *   ui[7:6]  게이트 길이: clk 2^10, 2^12, 2^14, 2^16 주기
 *   uo[7:0]  선택한 바이트
 *   uio[0]   선택한 링 / 64 (보드에서 직접 주파수를 재는 용도)
 *   uio[1]   측정 완료
 *   uio[2]   측정 중
 */

`default_nettype none
`timescale 1ns / 1ps

// ---------------------------------------------------------------------------
// 셀 하나짜리 모듈. keep_hierarchy 로 합성기가 단을 합치거나 지우지 못하게 한다.
// RO_SIM_DELAY 는 RTL 시뮬레이션에서만 켠다(지연이 없으면 고리가 진동하지 못함).
// 셀 종류별 지연은 시뮬레이션용 가짜 값이고, 실제 값은 칩에서 잰다.
// ---------------------------------------------------------------------------

(* keep_hierarchy = "yes" *)
module ro_inv_cell (
    input  wire a,
    /* verilator lint_off UNOPTFLAT */
    output wire y
);
`ifdef RO_SIM_DELAY
  assign #0.10 y = ~a;
`else
  assign y = ~a;
`endif
endmodule

(* keep_hierarchy = "yes" *)
module ro_nand2_cell (
    input  wire a,
    input  wire b,
    /* verilator lint_off UNOPTFLAT */
    output wire y
);
`ifdef RO_SIM_DELAY
  assign #0.12 y = ~(a & b);
`else
  assign y = ~(a & b);
`endif
endmodule

(* keep_hierarchy = "yes" *)
module ro_nor2_cell (
    input  wire a,
    input  wire b,
    /* verilator lint_off UNOPTFLAT */
    output wire y
);
`ifdef RO_SIM_DELAY
  assign #0.15 y = ~(a | b);
`else
  assign y = ~(a | b);
`endif
endmodule

// ---------------------------------------------------------------------------
// 링오실레이터 3종. 단수는 모두 홀수.
// ---------------------------------------------------------------------------

// 인버터 링: 첫 단만 NAND2(켜기 신호용), 나머지 STAGES-1 단은 인버터
module ro_ring_inv #(
    parameter STAGES = 51
) (
    input  wire en,
    output wire osc
);
  (* keep = "true" *) wire [STAGES-1:0] n;

  ro_nand2_cell first (.a(n[STAGES-1]), .b(en), .y(n[0]));

  genvar i;
  generate
    for (i = 1; i < STAGES; i = i + 1) begin : g_inv
      ro_inv_cell c (.a(n[i-1]), .y(n[i]));
    end
  endgenerate

  assign osc = n[STAGES-1];
endmodule

// NAND2 링: 첫 단의 두 번째 입력만 켜기 신호, 나머지 단은 hold(평소 1).
// 모든 단을 켜기 신호로 동시에 풀면 모든 단이 한꺼번에 뒤집히는 엉뚱한 진동이 생긴다
// (시뮬레이션에서 확인함). 그래서 꺼져 있을 때 고리가 한 곳에서만 끊겨 있게 한다.
module ro_ring_nand #(
    parameter STAGES = 41
) (
    input  wire en,
    input  wire hold,  // 평소 1 (리셋 해제 상태). 나머지 단을 인버터처럼 동작시킴
    output wire osc
);
  (* keep = "true" *) wire [STAGES-1:0] n;

  ro_nand2_cell first (.a(n[STAGES-1]), .b(en), .y(n[0]));

  genvar i;
  generate
    for (i = 1; i < STAGES; i = i + 1) begin : g_nand
      ro_nand2_cell c (.a(n[i-1]), .b(hold), .y(n[i]));
    end
  endgenerate

  assign osc = n[STAGES-1];
endmodule

// NOR2 링: 첫 단만 ~en, 나머지 단은 ~hold(평소 0)
module ro_ring_nor #(
    parameter STAGES = 41
) (
    input  wire en,
    input  wire hold,
    output wire osc
);
  (* keep = "true" *) wire [STAGES-1:0] n;
  wire dis_first = ~en;
  wire dis_rest  = ~hold;

  ro_nor2_cell first (.a(n[STAGES-1]), .b(dis_first), .y(n[0]));

  genvar i;
  generate
    for (i = 1; i < STAGES; i = i + 1) begin : g_nor
      ro_nor2_cell c (.a(n[i-1]), .b(dis_rest), .y(n[i]));
    end
  endgenerate

  assign osc = n[STAGES-1];
endmodule

// ---------------------------------------------------------------------------
// 리플 카운터: 링 주파수가 높아도 타이밍 문제가 없도록 각 비트가 앞 비트로 토글.
// 게이트가 닫힌 뒤에는 값이 멈추므로 clk 쪽에서 안전하게 읽을 수 있다.
// ---------------------------------------------------------------------------
module ripple_counter #(
    parameter WIDTH = 24
) (
    input  wire             clk_in,  // 첫 비트를 토글하는 신호(링 출력)
    input  wire             en,      // clk_in 영역에 동기화된 허용 신호
    input  wire             clr,     // 비동기 지우기(1 = 지움)
    output wire [WIDTH-1:0] q
);
  // 비트마다 따로 된 T 플립플롭. 첫 비트는 링의 올라가는 순간, 나머지는 앞 비트가 내려가는 순간에 뒤집힌다.
  wire [WIDTH-1:0] tick;
  assign tick[0] = clk_in;

  genvar i;
  generate
    for (i = 0; i < WIDTH; i = i + 1) begin : g_bit
      if (i == 0) begin : g_first
        tff_bit b (.clk(tick[0]), .t(en), .clr(clr), .q(q[0]));
      end else begin : g_rest
        assign tick[i] = ~q[i-1];
        tff_bit b (.clk(tick[i]), .t(1'b1), .clr(clr), .q(q[i]));
      end
    end
  endgenerate
endmodule

// T 플립플롭 한 개 (t = 1 이면 clk 올라갈 때마다 뒤집힘)
module tff_bit (
    input  wire clk,
    input  wire t,
    input  wire clr,
    output reg  q
);
  always @(posedge clk or posedge clr) begin
    if (clr) q <= 1'b0;
    else if (t) q <= ~q;
  end
endmodule

// ---------------------------------------------------------------------------
// 최상위
// ---------------------------------------------------------------------------
module tt_um_josh1261_ro_meter (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  wire [1:0] ro_sel   = ui_in[1:0];
  wire       ro_on    = ui_in[2];
  wire       start_in = ui_in[3];
  wire [1:0] byte_sel = ui_in[5:4];
  wire [1:0] gate_sel = ui_in[7:6];

  // 리셋이 풀린 뒤 몇 클럭 지나서야 링을 켤 수 있게 한다.
  // hold(=rst_n)가 먼저 1이 되어 꺼진 링이 한 곳에서만 끊긴 상태로 자리 잡은 뒤에
  // 첫 단을 풀어야 진동이 하나만 생긴다.
  reg [3:0] rst_dly;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_dly <= 4'd0;
    else rst_dly <= {rst_dly[2:0], 1'b1};
  end
  wire run_ok = rst_dly[3];

  // 선택한 링만 켠다(나머지는 멈춰서 서로 간섭과 전력을 줄임)
  wire en_inv  = run_ok & ro_on & (ro_sel == 2'd0);
  wire en_nand = run_ok & ro_on & (ro_sel == 2'd1);
  wire en_nor  = run_ok & ro_on & (ro_sel == 2'd2);

  wire osc_inv, osc_nand, osc_nor;
  ro_ring_inv  #(.STAGES(51)) u_inv  (.en(en_inv),  .osc(osc_inv));
  ro_ring_nand #(.STAGES(41)) u_nand (.en(en_nand), .hold(rst_n), .osc(osc_nand));
  ro_ring_nor  #(.STAGES(41)) u_nor  (.en(en_nor),  .hold(rst_n), .osc(osc_nor));

  // 꺼진 링의 출력은 고정값이라 OR 로 합쳐도 선택한 링만 남는다
  wire osc = (osc_inv & en_inv) | (osc_nand & en_nand) | (osc_nor & en_nor);

  // ----- clk 영역: 측정 순서 제어 -----
  localparam S_IDLE = 2'd0, S_CLEAR = 2'd1, S_GATE = 2'd2, S_SETTLE = 2'd3;

  reg [1:0]  state;
  reg [16:0] timer;
  reg        gate;
  reg        clr;
  reg        done;
  reg [2:0]  start_sync;  // 시작 버튼 동기화 + 올라가는 순간 검출

  wire start_rise = start_sync[1] & ~start_sync[2];

  wire [16:0] gate_len = (gate_sel == 2'd0) ? 17'd1024  :
                         (gate_sel == 2'd1) ? 17'd4096  :
                         (gate_sel == 2'd2) ? 17'd16384 : 17'd65536;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      timer      <= 17'd0;
      gate       <= 1'b0;
      clr        <= 1'b1;
      done       <= 1'b0;
      start_sync <= 3'b000;
    end else begin
      start_sync <= {start_sync[1:0], start_in};
      case (state)
        S_IDLE: begin
          clr <= 1'b0;
          if (start_rise) begin
            done  <= 1'b0;
            clr   <= 1'b1;
            timer <= 17'd0;
            state <= S_CLEAR;
          end
        end
        S_CLEAR: begin  // 카운터를 몇 주기 동안 지운다
          timer <= timer + 17'd1;
          if (timer == 17'd3) begin
            clr   <= 1'b0;
            timer <= 17'd0;
            state <= S_GATE;
          end
        end
        S_GATE: begin  // 정확히 gate_len 주기 동안 게이트를 연다
          gate  <= 1'b1;
          timer <= timer + 17'd1;
          if (timer == gate_len) begin
            gate  <= 1'b0;
            timer <= 17'd0;
            state <= S_SETTLE;
          end
        end
        S_SETTLE: begin  // 링 쪽 동기화와 리플이 끝날 때까지 기다린다
          timer <= timer + 17'd1;
          if (timer == 17'd15) begin
            done  <= 1'b1;
            state <= S_IDLE;
          end
        end
      endcase
    end
  end

  // ----- 링 영역: 게이트 동기화 후 카운트 -----
  reg [1:0] gate_ro;
  always @(posedge osc or posedge clr) begin
    if (clr) gate_ro <= 2'b00;
    else gate_ro <= {gate_ro[0], gate};
  end

  wire [23:0] count;
  ripple_counter #(.WIDTH(24)) u_cnt (
      .clk_in(osc),
      .en    (gate_ro[1]),
      .clr   (clr),
      .q     (count)
  );

  // 직접 관찰용: 링 / 64 (항상 동작, 측정과 별개)
  wire [5:0] div;
  ripple_counter #(.WIDTH(6)) u_div (
      .clk_in(osc),
      .en    (1'b1),
      .clr   (~rst_n),
      .q     (div)
  );

  wire busy = (state != S_IDLE);
  wire [7:0] status = {done, busy, ro_on, ro_sel, 3'b000};

  assign uo_out = (byte_sel == 2'd0) ? count[7:0]   :
                  (byte_sel == 2'd1) ? count[15:8]  :
                  (byte_sel == 2'd2) ? count[23:16] : status;

  assign uio_out = {5'b00000, busy, done, div[5]};
  assign uio_oe  = 8'b0000_0111;

  wire _unused = &{ena, uio_in, div[4:0], 1'b0};

endmodule
