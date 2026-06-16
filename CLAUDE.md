@/Users/songakim/Documents/works/analysis-shared/CLAUDE.md

# Makestar 유저 세그멘테이션 — RFM + Dimension 분석

## 프로젝트 개요

전체 유저풀 내에서 개별 유저의 상대적 위치를 RFM 스코어로 정량화하고,
행동 유형(Collector/Challenger)과 주력 아티스트를 2nd depth dimension으로 분류.

## RFM 정의

| 지표 | 정의 | 소스 |
|---|---|---|
| R (Recency) | 마지막 구매일 기준 최신성 | `datamart.total_orders.pay_date` |
| F (Frequency) | 아티스트당 평균 구매횟수 = 총 구매횟수 / 구매 아티스트 수 | `datamart.total_orders` |
| M (Monetary) | 누적 총 결제금액 | `datamart.total_orders.total_revenue` |

- 각 지표 **1~5점** 스코어 (전체 유저풀 내 상대 위치 기준)
- 구매대행 제외 (`service.md` 목록 참조)
- `market_type IN ('B2C','B2B')` 기준

## 2nd Depth Dimension

| 유형 | 정의 |
|---|---|
| Collector | 동일 이벤트에서 포카 전종 구매 패턴 (`order_qty >= mst_sku.virtual_child_sku_count`) |
| Challenger | POB 응모 목적 구매 비율 높음 (`event_id IS NOT NULL` 주문 비중) |
| Artist | 누적 결제금액 기준 주력 아티스트 1개 |

- Collector / Challenger 는 중복 가능 (하나의 유저가 둘 다일 수 있음)
