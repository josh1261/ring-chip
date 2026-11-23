# SPDX-License-Identifier: Apache-2.0
#
# 링오실레이터 측정 칩 테스트 (RTL 시뮬레이션)
#
# RTL 시뮬레이션에서는 셀 지연을 가짜 값으로 넣었다(project.v 의 RO_SIM_DELAY):
#   인버터 0.10ns, NAND2 0.12ns, NOR2 0.15ns
# 그래서 각 링의 주파수를 손으로 계산할 수 있고, 칩이 그 값을 맞게 세는지 확인한다.
#
# 게이트 수준 테스트(GATES=yes)에서는 링을 켜지 않는다.
# 공정 셀 모델은 지연이 0이라 링을 켜면 시뮬레이터가 같은 시각에서 끝없이 돌며 멈춘다.
# 그래서 게이트 수준에서는 링이 꺼진 상태의 디지털 부분(측정 순서, 카운터 0, 상태 바이트)만 확인한다.

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer
from cocotb.utils import get_sim_time

CLK_NS = 100  # 10 MHz
GATE_CYCLES = {0: 1024, 1: 4096, 2: 16384, 3: 65536}
GL = os.environ.get("GATES") == "yes"

# 반주기 = 고리 한 바퀴 지연. 주기 = 2 x 반주기
RINGS = {
    0: ("inverter x51", 0.12 + 50 * 0.10),  # 첫 단 NAND2 + 인버터 50단
    1: ("nand2 x41", 41 * 0.12),
    2: ("nor2 x41", 41 * 0.15),
}


def expected_count(ring, gate_sel):
    half_ns = RINGS[ring][1]
    period_ns = 2 * half_ns
    gate_ns = GATE_CYCLES[gate_sel] * CLK_NS
    return gate_ns / period_ns


def pins(ring=0, on=1, start=0, byte=0, gate=0):
    return (ring & 3) | (on << 2) | (start << 3) | ((byte & 3) << 4) | ((gate & 3) << 6)


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def measure(dut, ring, on=1, gate=0):
    """측정 한 번: 시작 신호를 올렸다 내리고, 완료되면 24비트 카운트를 읽는다."""
    dut.ui_in.value = pins(ring, on, 0, 0, gate)
    await ClockCycles(dut.clk, 3)
    dut.ui_in.value = pins(ring, on, 1, 0, gate)
    await ClockCycles(dut.clk, 3)
    dut.ui_in.value = pins(ring, on, 0, 0, gate)

    limit = GATE_CYCLES[gate] + 100
    for _ in range(limit):
        await RisingEdge(dut.clk)
        if int(dut.uio_out.value) & 0b010:  # uio[1] = 완료
            break
    else:
        raise AssertionError("측정이 끝나지 않음")

    count = 0
    for b in range(3):
        dut.ui_in.value = pins(ring, on, 0, b, gate)
        await ClockCycles(dut.clk, 1)
        await Timer(1, unit="ns")
        count |= int(dut.uo_out.value) << (8 * b)
    return count


@cocotb.test(skip=GL)
async def test_each_ring_count(dut):
    """링 3종이 각각 계산한 만큼 진동 횟수를 세는지"""
    await setup(dut)
    for ring, (name, _) in RINGS.items():
        count = await measure(dut, ring)
        exp = expected_count(ring, 0)
        dut._log.info(f"{name}: count={count}, 예상={exp:.1f}")
        assert abs(count - exp) <= 3, f"{name}: {count} vs 예상 {exp:.1f}"


@cocotb.test()
async def test_ring_off_counts_zero(dut):
    """링을 끄면 카운트가 0"""
    await setup(dut)
    count = await measure(dut, ring=0, on=0)
    assert count == 0, f"꺼진 링인데 {count} 를 셈"


@cocotb.test(skip=GL)
async def test_gate_length_scales(dut):
    """게이트를 4배로 늘리면 카운트도 약 4배"""
    await setup(dut)
    c0 = await measure(dut, ring=1, gate=0)
    c1 = await measure(dut, ring=1, gate=1)
    dut._log.info(f"gate0={c0}, gate1={c1}, 비율={c1 / c0:.4f}")
    assert abs(c1 / c0 - 4.0) < 0.01


@cocotb.test(skip=GL)
async def test_divided_output(dut):
    """uio[0] 는 선택한 링 주파수의 1/64"""
    await setup(dut)
    dut.ui_in.value = pins(ring=2, on=1)
    await ClockCycles(dut.clk, 5)

    edges = []
    for _ in range(5):
        await RisingEdge(dut.uio0)
        edges.append(get_sim_time(unit="ns"))
    period = (edges[-1] - edges[0]) / 4
    exp = 64 * 2 * RINGS[2][1]
    dut._log.info(f"분주 출력 주기 {period:.2f}ns, 예상 {exp:.2f}ns")
    assert abs(period - exp) < 0.5


@cocotb.test()
async def test_status_byte(dut):
    """상태 바이트: 완료·켜짐·링 번호 (게이트 수준에서는 링을 끈 채로)"""
    on = 0 if GL else 1
    await setup(dut)
    await measure(dut, ring=2, on=on)
    dut.ui_in.value = pins(ring=2, on=on, byte=3)
    await ClockCycles(dut.clk, 1)
    await Timer(1, unit="ns")
    status = int(dut.uo_out.value)
    assert status >> 7 == 1, "완료 비트"
    assert (status >> 6) & 1 == 0, "측정 중 비트"
    assert (status >> 5) & 1 == on, "켜짐 비트"
    assert (status >> 3) & 3 == 2, "링 번호"
