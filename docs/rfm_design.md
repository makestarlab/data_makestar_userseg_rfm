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

#### SKU 필터

분류 대상 SKU를 먼저 걸러낸다.

| SKU 타입 | 처리 | 이유 |
|---|---|---|
| `sku_type = 'C'` (child SKU) | **제외** | 실제 앨범 단위 — 포카/응모 분석 대상 아님 |
| `sku_type = 'P'` (parent SKU) | **포함** | 랜덤 포카 종류 수(`virtual_child_sku_count`) 보유 |
| `sku_type = NULL` (조인 안 됨) | **포함** | 일반 상품 — 금액 기준으로 분류 |

#### virtual_child_sku_count 처리

| 상황 | 값 | qty_ratio 분모 |
|---|---|---|
| 포카 상품 (`vc > 1`) | 실제 멤버/종류 수 | `virtual_child_sku_count` |
| 일반 상품 (`vc = NULL / 0`) | COALESCE → **1** | `1` (장수 그대로) |

#### 핵심 변수

| 변수 | 집계 단위 | 설명 |
|---|---|---|
| `qty_ratio` | user × event_id × **option_code** | `SUM(order_qty) / COALESCE(virtual_child_sku_count, 1)` |
| `unit_price` | user × event_id × option_code | `SUM(total_revenue) / SUM(order_qty)` |
| `is_winner` | user | `tb_commerce_event_winner_group.winner_list` 당첨 이력 |

#### 4단계 유저 분류 (MECE)

**옵션 단위 → 아티스트 → 유저** 집계 후 최종 레이블 결정.

| 우선순위 | 조건 | 레이블 |
|---|---|---|
| 1 | 당첨 이력 있음 | **Challenger** |
| 1 | `qty_ratio > 1.5` (vc > 1 상품) | **Challenger** |
| 1 | 응모권 상품 `SUM(order_qty) >= 10` (vc = 0/NULL) | **Challenger** |
| 2 | `COUNT(DISTINCT ip_name) >= 3` AND `MAX(order_qty) <= 5` | **Album Collector** |
| 3 | `qty_ratio >= collector_threshold` (vc > 1 상품) | **Poca Collector** |
| 4 | 나머지 | **Beginner** |

> **Album Collector**: 유저 전체 구매 이력 기준. 여러 아티스트를 소량씩 수집하는 패턴.
> Challenger 조건 미충족 시만 적용.

#### Challenger 임계값 변경 이력
- v1: qty_ratio > 1.0
- **v2: qty_ratio > 1.5** — qty_ratio 1.0~1.5 구간은 전종+여분 구매로 판단, Poca Collector로 분류

#### 가격대별 Collector 하한 (collector_threshold)

| 가격대 (unit_price) | 하한 | 포카 상품 의미 | 일반 상품 의미 |
|---|---|---|---|
| ~5만원 미만 | 0.5 | 전종의 절반 이상 | qty ≥ 0.5 → 1장만 사도 Collector |
| 5만원~20만원 미만 | 0.3 | 전종의 1/3 이상 | qty ≥ 0.3 → 1장만 사도 Collector |
| 20만원 이상 | 0.2 | 전종의 1/5 이상 | qty ≥ 0.2 → 1장만 사도 Collector |

> **일반 상품(vc=1)**: qty_ratio = order_qty이므로 1장 구매 = qty_ratio 1.0 ≥ 하한 → 항상 Collector 이상
> **Beginner는 사실상 포카 상품 소량 구매자** (예: 8멤버 중 1장 = qty_ratio 0.125 < 0.5)

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
-- SKU C타입(album child SKU) 제외, vc=NULL → COALESCE 1 (일반 상품)
option_stats AS (
  SELECT
    o.user_id,
    e.artist_id,
    o.event_id,
    o.option_code,
    SUM(o.order_qty)                                                                  AS total_qty,
    SAFE_DIVIDE(SUM(o.total_revenue), NULLIF(SUM(o.order_qty), 0))                    AS unit_price,
    COALESCE(MAX(s.virtual_child_sku_count), 1)                                       AS sku_variety,
    SAFE_DIVIDE(SUM(o.order_qty), NULLIF(COALESCE(MAX(s.virtual_child_sku_count),1),0)) AS qty_ratio
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  LEFT JOIN `makestar-dw.datamart.vw_commerce_items_v2` i
         ON o.event_id = i.product_event_code AND o.option_code = i.product_option_id
  LEFT JOIN `makestar-dw.pg_oms_public.mst_sku` s ON i.sku_code = s.sku_code
  WHERE o.market_type IN ('B2C','B2B')
    AND o.data_source = 'new_commerce_db'
    AND (s.sku_type IS NULL OR s.sku_type = 'P')  -- album child SKU 제외
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

#### v2 결과 (new_commerce_db, B2C, 최근 3개월 기준)

| 세그먼트 | 유저 수 | 비율 | avg_GMV | 특성 |
|---|---|---|---|---|
| **Challenger** | 17,180명 | 55.0% | ₩1,076,095 | 당첨 이력 / qty_ratio > 1.5 / 응모권 10장+ |
| **Album Collector** | 56명 | 0.2% | ₩168,462 | 3개+ IP 소량 수집 (max_qty ≤ 5) |
| **Poca Collector** | 2,282명 | 7.3% | ₩69,132 | qty_ratio 0.5~1.5 |
| **Beginner** | 11,715명 | 37.5% | ₩98,799 | 소량 단발 구매 |

> Challenger threshold: qty_ratio > **1.5** (v1: > 1.0 → 1.0~1.5는 여분 구매로 Poca Collector 흡수)

---

### V1 제한사항

| 항목 | 내용 | 개선 방향 (v2) |
|---|---|---|
| old_commerce_db 미포함 | new_commerce_db(2024-12-20~)만 분류 가능 | 구형 데이터 조인 경로 확보 |
| opportunity_version 미활용 | 응모권 포함 여부 미반영 — 응모권 없는 상품의 qty > 1이 Challenger로 과분류될 수 있음 | 응모권 유무로 Challenger 기준 세분화 |
| 멤버별 옵션 다양성 미반영 | 멤버별로 1장씩 구매(option diversity)해도 option 단위 qty_ratio = 0.125 → Beginner 분류 가능 | 주문번호 × event 단위 total_qty 집계 추가 |
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
