# Makestar 유저 세그멘테이션 — RFM + Dimension 분석

<!-- analysis-shared 컨텍스트는 각자 ~/.claude/CLAUDE.md 전역 설정으로 적용 (README 참조) -->

## 프로젝트 개요

전체 유저풀 내에서 개별 유저의 상대적 위치를 RFM 스코어로 정량화하고,
행동 유형(Collector/Challenger)과 주력 아티스트를 2nd depth dimension으로 분류.

## RFM 설계

→ `docs/rfm_design.md` 참조

## 2nd Depth Dimension

| 유형 | 정의 |
|---|---|
| Collector | 동일 이벤트에서 포카 전종 구매 패턴 (`order_qty >= mst_sku.virtual_child_sku_count`) |
| Challenger | POB 응모 목적 구매 비율 높음 (`event_id IS NOT NULL` 주문 비중) |
| Artist | 누적 결제금액 기준 주력 아티스트 1개 |

- Collector / Challenger 는 중복 가능 (하나의 유저가 둘 다일 수 있음)
