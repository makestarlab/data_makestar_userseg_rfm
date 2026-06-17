# RFM 설계 문서

## 지표 정의

| 지표 | 정의 | 소스 | 비고 |
|---|---|---|---|
| **R** (Recency) | 마지막 로그인일 | `pg_mystarroom_public.tb_auth_user.last_login` | 최신성 |
| **F** (Frequency) | 아티스트당 평균 라운드 수 | `datamart.total_orders` + `datamart.events_` | 라운드 = album_name 단위 |
| **M** (Monetary) | 누적 총 결제금액 | `datamart.total_orders.total_revenue` | KRW 기준 |

### F 계산 방식

```
F = COUNT(DISTINCT artist_id || album_name) / COUNT(DISTINCT artist_id)
```

예시: ATEEZ 앨범 3라운드, ITZY 앨범 1라운드 구매 → F = (3+1) / 2 = 2.0

---

## 스코어링

- 각 지표를 **1~5점**으로 변환 (전체 유저풀 내 상대 위치 기준, NTILE 5분위)
- 5점 = 상위 20%, 1점 = 하위 20%
- R은 역순 (미접속 일수가 적을수록 5점)

---

## 가중치 모델

> **마지막 단계에서 결정** — R/F/M 분포 확인 후 엔트로피 방식 또는 전문가 판단 적용 예정

최종 RFM 스코어 = `w_r × R점수 + w_f × F점수 + w_m × M점수`

---

## 2nd Depth Dimension

### Collector / Challenger / Beginner

#### 집계 단위

```
유저 × 아티스트 × 이벤트(event_id) × 옵션(option_code)
  → 옵션 레이블
  → 아티스트 레이블 (옵션들의 최빈값)
  → 유저 레이블 (아티스트들의 최빈값)
```

#### 핵심 변수

| 변수 | 집계 단위 | 설명 |
|---|---|---|
| `qty_ratio` | user × event_id × **option_code** | `SUM(order_qty) / virtual_child_sku_count` |
| `unit_price` | user × event_id × option_code | `SUM(total_revenue) / SUM(order_qty)` |
| `is_winner` | user | `tb_commerce_event_winner_group.winner_list` 당첨 이력 |

> qty_ratio는 **옵션 단위**로 계산 — 같은 이벤트에서 멤버별 옵션을 따로 집계
> 가격대는 **unit_price** 기준으로 Collector 하한 결정

#### 옵션 단위 분류 로직

| 우선순위 | 조건 | 레이블 |
|---|---|---|
| 1 | `is_winner = true` | **Challenger** |
| 2 | `qty_ratio > 1.0` | **Challenger** |
| 3 | `qty_ratio >= collector_threshold` | **Collector** |
| 4 | `qty_ratio < collector_threshold` | **Beginner** |

#### 가격대별 Collector 하한 (collector_threshold)

| 가격대 (unit_price) | collector_threshold | 의미 |
|---|---|---|
| ~5만원 미만 | 0.5 | 절반 이상 구매 |
| 5만원~20만원 미만 | 0.3 | 1/3 이상 구매 |
| 20만원 이상 | 0.2 | 1/5 이상 구매 |

> 비싼 앨범일수록 낮은 qty_ratio도 Collector 의도로 인정

#### 당첨 이력 소스

```sql
-- tb_commerce_event_winner_group.winner_list JSON에서 user_id 추출
SELECT DISTINCT CAST(o.user_id AS STRING) AS user_id
FROM `makestar-dw.pg_mystarroom_public.tb_commerce_event_winner_group`
JOIN UNNEST(JSON_EXTRACT_ARRAY(winner_list)) b
JOIN `makestar-dw.pg_mystarroom_public.tb_commerce_order` o
  ON JSON_VALUE(b.information.order.order_number) = o.order_number
WHERE JSON_VALUE(b.user.id) != '-1'
```

#### 아티스트 → 유저 레이블링

1. 아티스트 레이블 = 해당 아티스트 옵션 레이블 최빈값
2. 유저 레이블 = 아티스트 레이블 최빈값
3. 동률 우선순위: **Challenger > Collector > Beginner**

#### 전체 분류 쿼리 예시

```sql
WITH
winners AS (
  SELECT DISTINCT CAST(o.user_id AS STRING) AS user_id
  FROM `makestar-dw.pg_mystarroom_public.tb_commerce_event_winner_group`
  JOIN UNNEST(JSON_EXTRACT_ARRAY(winner_list)) b
  JOIN `makestar-dw.pg_mystarroom_public.tb_commerce_order` o
    ON JSON_VALUE(b.information.order.order_number) = o.order_number
  WHERE JSON_VALUE(b.user.id) != '-1'
),

-- qty_ratio: user × event_id × option_code 단위
option_stats AS (
  SELECT
    o.user_id,
    e.artist_id,
    o.event_id,
    o.option_code,
    SUM(o.order_qty)                                                        AS total_qty,
    SAFE_DIVIDE(SUM(o.total_revenue), NULLIF(SUM(o.order_qty), 0))          AS unit_price,
    MAX(s.virtual_child_sku_count)                                          AS sku_variety,
    SAFE_DIVIDE(SUM(o.order_qty), NULLIF(MAX(s.virtual_child_sku_count),0)) AS qty_ratio
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  LEFT JOIN `makestar-dw.datamart.vw_commerce_items_v2` i
         ON o.event_id = i.product_event_code AND o.option_code = i.product_option_id
  LEFT JOIN `makestar-dw.pg_oms_public.mst_sku` s ON i.sku_code = s.sku_code
  WHERE o.market_type IN ('B2C','B2B')
    AND o.data_source = 'new_commerce_db'
    AND s.virtual_child_sku_count > 1
  GROUP BY 1,2,3,4
),

-- 가격대별 Collector 하한 적용
option_labeled AS (
  SELECT *,
    CASE
      WHEN unit_price >= 200000 THEN 0.2
      WHEN unit_price >= 50000  THEN 0.3
      ELSE                           0.5
    END AS collector_threshold
  FROM option_stats
),

-- 옵션 단위 분류
event_labeled AS (
  SELECT o.*,
    CASE
      WHEN w.user_id IS NOT NULL              THEN 'Challenger'  -- 당첨 이력
      WHEN o.qty_ratio > 1.0                  THEN 'Challenger'  -- 전종 초과
      WHEN o.qty_ratio >= o.collector_threshold THEN 'Collector'
      ELSE                                         'Beginner'
    END AS option_label
  FROM option_labeled o
  LEFT JOIN winners w ON o.user_id = w.user_id
),

-- 아티스트 단위
artist_label_counts AS (
  SELECT user_id, artist_id, option_label, COUNT(*) AS cnt
  FROM event_labeled WHERE artist_id IS NOT NULL
  GROUP BY 1,2,3
),
artist_labeled AS (
  SELECT user_id, artist_id,
    ARRAY_AGG(option_label ORDER BY cnt DESC,
      CASE option_label WHEN 'Challenger' THEN 1 WHEN 'Collector' THEN 2 ELSE 3 END
      LIMIT 1)[SAFE_OFFSET(0)] AS artist_label
  FROM artist_label_counts GROUP BY 1,2
),

-- 유저 단위
user_label_counts AS (
  SELECT user_id, artist_label, COUNT(*) AS cnt
  FROM artist_labeled GROUP BY 1,2
)
SELECT user_id,
  ARRAY_AGG(artist_label ORDER BY cnt DESC,
    CASE artist_label WHEN 'Challenger' THEN 1 WHEN 'Collector' THEN 2 ELSE 3 END
    LIMIT 1)[SAFE_OFFSET(0)] AS dimension_label
FROM user_label_counts GROUP BY user_id
```

#### v1 결과 (new_commerce_db 기준)

| 세그먼트 | 유저 수 | 당첨 이력 |
|---|---|---|
| Challenger | 32,789명 | 24,328명 (74%) |
| Collector | 24,077명 | — |
| Beginner | 50,204명 | — |

---

### V1 제한사항

| 항목 | 내용 | 개선 방향 (v2) |
|---|---|---|
| old_commerce_db 미포함 | new_commerce_db(2024-12-20~)만 분류 가능 | 구형 데이터 조인 경로 확보 |
| opportunity_version 미활용 | 응모권 포함 여부 미반영 | 응모권 유무 세분화 |
| 인지도 낮은 아티스트 일부 오분류 | 낙첨 소량 베터는 qty_ratio가 낮아 Beginner로 분류될 수 있음 | 경쟁률 데이터 반영 |

---

### Artist

누적 결제금액(`total_revenue`) 기준 최다 지출 아티스트 1개.
`events_.artist_id` + `vw_commerce_items_v2.artist_name` 기준.

---

## 적용 기준

- **데이터 소스**: `data_source = 'new_commerce_db'` (2024-12-20~)
- **마켓**: `market_type IN ('B2C','B2B')`
- **구매대행 제외**: KPI 집계는 포함, 유저 행동 분석 시 제외
