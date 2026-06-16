# RFM 설계 문서

## 지표 정의

| 지표 | 정의 | 소스 | 비고 |
|---|---|---|---|
| **R** (Recency) | 마지막 로그인일 | `pg_mystarroom_public.tb_auth_user.last_login` | 최신성 |
| **F** (Frequency) | 아티스트당 평균 구매횟수 | `datamart.total_orders` | 복수 아티스트 구매 시 평균값 |
| **M** (Monetary) | 누적 총 결제금액 | `datamart.total_orders.total_revenue` | KRW 기준 |

### F 계산 방식

```
F = 총 구매횟수 / 구매한 아티스트 수
```

예시: 아티스트 A에서 10번, 아티스트 B에서 2번 구매 → F = (10 + 2) / 2 = 6

---

## 스코어링

- 각 지표를 **1~5점**으로 변환 (전체 유저풀 내 상대 위치 기준, 5분위)
- 5점 = 상위 20%, 1점 = 하위 20%

---

## 가중치 모델

> **마지막 단계에서 결정** — R/F/M 분포 확인 후 엔트로피 방식 또는 전문가 판단 적용 예정

최종 RFM 스코어 = `w_r × R점수 + w_f × F점수 + w_m × M점수`

---

## 2nd Depth Dimension

### Collector / Challenger / Beginner

**이벤트 단위 분류**

| 유형 | 조건 |
|---|---|
| Collector - Partial | `order_qty < virtual_child_sku_count` (일부만 구매) |
| Collector - Full | `order_qty == virtual_child_sku_count` (전종 구매) |
| Collector - Over | `order_qty > virtual_child_sku_count` (전종 초과 — 복수 세트) |
| Challenger | POB 응모 목적 구매 (`event_id IS NOT NULL` 주문 비중 높음) |
| Beginner | 위 패턴 해당 없음 |

**유저 단위 레이블링 로직**

1. 유저의 전체 이벤트 이력에서 이벤트별로 Collector / Challenger 분류
2. 가장 많이 나온 패턴 → 최종 레이블
3. **동률 우선순위**: Challenger > Collector > Beginner

### Artist

누적 결제금액(`total_revenue`) 기준 최다 지출 아티스트 1개.
`total_orders.ip_name` 또는 `events_.artist_id` 기준.

---

## 적용 기준

- 분석 대상: `market_type IN ('B2C','B2B')` B2C 구매 유저
- 구매대행 제외 (유저 행동 분석 목적)
- 분석 기간: TBD
