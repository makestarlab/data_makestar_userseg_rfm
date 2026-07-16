-- ============================================================
-- 2nd Depth Dimension 분류 (v3 — total_orders 미사용 + fan-out 버그 수정)
-- 5단계: Challenger / Album Collector / Poca Collector / Shopper / Beginner
--
-- v3 변경점 (2026-07-15):
--   1. 베이스 소스: datamart.total_orders / datamart.events_ (파생 마트) 대신
--      pg_mystarroom_public 원본(tb_commerce_order.ordered_data)에서 직접 재구축.
--      (makestar-dbt 프로젝트의 stg_commerce__orders / int_order_channel_classification과
--       동일 로직 — 이 레포는 dbt를 안 쓰므로 raw SQL로 인라인함)
--      단순화: 차액지불(COMMERCE_ADDITIONAL) 라인은 제외 — offer_id/option_id/artist_id가
--      전부 NULL이라 이 분류 로직(포카/응모권/아티스트 집계) 어디에도 기여하지 않아 결과가
--      동일함. shipping_revenue 안분도 제외(가격대 임계값 버킷 판정용이라 큰 영향 없음) —
--      필요시 후속으로 추가 가능.
--   2. 포카상품/응모권 판별·vc값: mst_sku.sku_type/virtual_child_sku_count(OMS)를 코드 기반으로
--      완전히 대체하려 시도했으나 실측으로 불가능함이 확인됨 —
--        - item_type=1(포토카드) content_id_list 길이: 커버리지 195/11,628건뿐(대부분 슬롯 1개=콘텐츠
--          1개라 항상 1로 계산됨, 실제 랜덤 종류 수를 못 잡음)
--        - "아티스트 멤버 수"로 대체: 67%(8,019/11,969)만 일치, 나머지는 버전 종류 수 등 다른 기준으로
--          물류팀이 잡는 값이라 단일 code로 못 뭉침
--      → vc 값 소스는 mst_sku 그대로 유지(대체할 code 없음, 실측 확인됨).
--      대신 실제 버그였던 지점(fan-out)만 수정: 기존엔 vw_commerce_items_v2 x mst_sku를 옵션 단위로
--      먼저 GROUP BY 안 하고 order 라인에 직접 join해서, 한 옵션에 매칭 콘텐츠(SKU)가 여러 개면 주문
--      수량이 그 개수만큼 복제되는 버그가 있었음(실측 확인: 여러 건에서 total_qty가 정확히 2배로
--      부풀려짐 — 예: P_9232_ATEEZ_7 옵션 9822, 실제 1,578 → 기존 쿼리 3,156). 이번 재구축은
--      옵션 단위로 먼저 vc/응모권여부를 확정(option_poca_vc/option_is_omg)한 뒤 join해서 원천 차단.
--   3. Shopper 판별: event_id IS NOT NULL(쇼핑 상품도 event_id를 갖고 있어서 실제로는
--      구분이 안 되던 로직 결함) 대신 offer_type(P_POB/F_FUNDING) 구매 건수 = 0으로 판별.
--   4. 숫자 임계값(qty_ratio>1.5, 가격대별 0.2/0.3/0.5, distinct_ips>=3, max_qty<=5,
--      응모권 order_qty>=10)은 전부 변경 없음 — 원본 로직 그대로 유지.
--
-- [Challenger] (우선순위 1)
--   - 당첨 이력 있음
--   - qty_ratio > 1.5 (vc > 1 포카 상품)
--   - 응모권 상품 SUM(order_qty) >= 10
--
-- [Album Collector] (우선순위 2)
--   - NOT Challenger
--   - COUNT(DISTINCT artist_id) >= 3 AND MAX(order_qty) <= 5
--
-- [Poca Collector] (우선순위 3)
--   - NOT Challenger, NOT Album Collector
--   - qty_ratio >= 가격대별 하한 (0.2~0.5)
--
-- [Shopper] (우선순위 4)
--   - 위 전부 아님, 이벤트(POB/펀딩)성 구매가 0건
--
-- [Beginner] (우선순위 5)
--   - 나머지
--
-- 가격대별 Poca Collector 하한:
--   ~5만원    : 0.5
--   5~20만원  : 0.3
--   20만원+   : 0.2
-- ============================================================

WITH

-- makestar.com 내부/테스트/운영 계정 (수동 관리 대상 — 구매대행과 무관)
internal_accounts AS (
  SELECT user_id FROM UNNEST([
    -- makestar.com 추가분
    '2308791','2065197','1966353','2108478','1973103','1967649','1962518','1651127',
    -- makestar.com 내부 계정 전체 (271개)
    '1','2','4','5','6','11','23','28','46','47','81','149','250','293','445','446','506','639','640','642','660','1143','1669','1698','2266','3570','3697','6397','7323','7405','9969','13710','18891','18894','18907','18910','18918','18922','18937','18941','18943','25527','27096','31592','61472','65178','75428','77164','81888','89996','91817','94183','114029','116449','118315','135807','158291','159444','171365','171433','183250','191191','200172','634299','703146','777996','779425','780061','873495','912353','913997','916406','924614','927469','952068','957967','958079','978851','1052062','1052063','1072108','1248703','1266580','1297564','1311611','1325480','1468256','1482741','1495292','1529990','1545005','1548348','1600245','1600492','1600495','1601827','1612695','1628967','1641220','1645106','1645266','1645965','1650883','1651127','1674672','1674702','1697154','1709547','1733846','1750907','1763267','1766373','1777929','1821468','1831384','1833148','1843309','1849858','1873463','1873637','1875148','1876851','1878152','1878641','1878643','1881909','1890911','1893867','1901629','1907491','1908565','1913442','1913658','1917824','1917825','1917826','1917867','1917868','1917870','1917871','1917872','1917873','1918208','1920091','1920207','1920253','1921331','1922190','1922323','1924210','1924273','1925289','1928348','1928421','1928595','1928604','1929489','1939880','1944677','1944678','1944790','1951334','1953163','1961321','1962518','1962948','1962950','1966113','1966181','1966353','1967649','1972061','1973103','1976288','1977684','1984821','1987033','2001809','2007916','2010410','2012770','2013196','2018509','2022128','2029267','2034114','2034894','2037880','2040138','2040417','2040419','2047053','2047862','2047934','2048523','2048754','2050183','2050512','2052554','2063566','2063973','2064638','2064873','2065197','2073991','2074693','2080193','2085818','2086326','2090320','2092774','2099682','2103431','2105715','2108478','2112627','2113859','2114330','2116477','2116575','2116643','2117074','2121241','2129227','2132673','2132707','2132737','2142915','2146416','2149239','2149241','2149489','2154856','2161922','2162318','2168465','2170725','2184510','2187366','2189092','2208829','2216236','2219279','2223971','2233650','2238011','2238047','2238604','2242193','2246393','2246854','2246968','2251552','2256789','2258846','2258853','2258864','2258883','2262807','2267385','2277798','2281976','2293704','2293705','2297965','2297968','2302762','2306968','2308791','2310926','2312066',
    -- B2B/운영 계정 추가 제외
    '2293705','2293704','2302812','2048754','1984821','2132737','2116643','1986193','2073991','2063566','1976288'
  ]) AS user_id
),

-- 구매대행 추정 (하드코딩 리스트 대체): 동일 창고주소에 고객코드 3개 이상 + 아티스트 2개 이상 구매
order_shipping AS (
  SELECT
    user_id,
    TRIM(JSON_EXTRACT_SCALAR(shipping_information, '$.information.address'))        AS base_address,
    TRIM(JSON_EXTRACT_SCALAR(shipping_information, '$.information.detail_address')) AS customer_code
  FROM `makestar-dw.pg_mystarroom_public.tb_commerce_order`
  WHERE payment_status IN ('CONFIRMED', 'PARTIAL_CANCELED')
    AND user_id IS NOT NULL
    AND shipping_information IS NOT NULL
),
purchasing_candidates AS (
  SELECT user_id
  FROM order_shipping
  WHERE customer_code IS NOT NULL AND customer_code != ''
    AND base_address  IS NOT NULL AND base_address  != ''
  GROUP BY user_id, base_address
  HAVING COUNT(DISTINCT customer_code) >= 3
),
multi_artist AS (
  SELECT o.user_id
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  WHERE o.market_type = 'B2C'
    AND DATE(o.pay_date) >= '2025-01-01'
    AND e.artist_id IS NOT NULL
  GROUP BY o.user_id
  HAVING COUNT(DISTINCT e.artist_id) >= 2
),
purchasing_agents AS (
  SELECT DISTINCT CAST(p.user_id AS STRING) AS user_id
  FROM purchasing_candidates p
  JOIN multi_artist m ON m.user_id = CAST(p.user_id AS STRING)
),

agents AS (
  SELECT user_id FROM internal_accounts
  UNION DISTINCT
  SELECT user_id FROM purchasing_agents
),

-- 당첨 이력 (변경 없음, 원래부터 raw 원본 기반)
winners AS (
  SELECT DISTINCT CAST(o.user_id AS STRING) AS user_id
  FROM `makestar-dw.pg_mystarroom_public.tb_commerce_event_winner_group`
  JOIN UNNEST(JSON_EXTRACT_ARRAY(winner_list)) b
  JOIN `makestar-dw.pg_mystarroom_public.tb_commerce_order` o
    ON JSON_VALUE(b.information.order.order_number) = o.order_number
  WHERE JSON_VALUE(b.user.id) != '-1'
),

-- ── [v3 신규] 주문 라인 원본 재구축 (주문 × 오퍼 × 옵션) — datamart 미사용 ──
-- tb_commerce_order.ordered_data 배열 2단 UNNEST (buying_option_list가 한 번 더 중첩됨, 실측 확인됨)
commerce_lines AS (
  SELECT
    o.id AS order_id,
    o.user_id,
    o.order_status,
    COALESCE(o.payment_status, JSON_VALUE(o.payment_data, '$.status')) AS payment_status,
    LEFT(o.order_number, 1) AS order_no_prefix,
    SAFE_CAST(JSON_VALUE(offer_line, '$.id') AS INT64) AS offer_id,
    JSON_VALUE(offer_line, '$.code') AS offer_code,
    SAFE_CAST(JSON_VALUE(option_line, '$.id') AS INT64) AS option_id,
    SAFE_CAST(JSON_VALUE(option_line, '$.quantity') AS INT64) AS order_qty,
    -- price는 라인 단가가 아니라 이 라인의 결제금액 자체(수량 곱하면 안 됨, makestar-dbt에서 실측 확인된 버그 포인트)
    SAFE_CAST(JSON_VALUE(option_line, '$.price') AS FLOAT64) AS total_revenue
  FROM `makestar-dw.pg_mystarroom_public.tb_commerce_order` o,
  UNNEST(JSON_QUERY_ARRAY(o.ordered_data)) AS offer_line,
  UNNEST(JSON_QUERY_ARRAY(offer_line, '$.buying_option_list')) AS option_line
),

-- offer_type(F_FUNDING/P_POB/S_SHOPPING) + artist_id/name — datamart.events_ 대신 원본 직접 조인
-- (events_는 INSERT-ONLY라 일부 stale함이 이미 확인된 마트 — 원본으로 대체)
offer_lookup AS (
  SELECT
    pe.id AS offer_id,
    CASE pe.product_event_type
      WHEN 0 THEN 'F_FUNDING' WHEN 1 THEN 'P_POB' WHEN 2 THEN 'S_SHOPPING'
    END AS offer_type,
    p.artist_id,
    aa.name AS artist_name
  FROM `makestar-dw.pg_mystarroom_public.tb_commerce_product_event_data` pe
  JOIN `makestar-dw.pg_mystarroom_public.tb_commerce_product` p ON pe.product_id = p.id
  LEFT JOIN `makestar-dw.pg_mystarroom_public.tb_artist_artist` aa ON p.artist_id = aa.id
),

-- B2C 결제완료 주문만 (makestar-dbt fct_orders와 동일한 결제완료 판정 기준)
-- event_id는 offer_code(문자열, 예: P_9232_ATEEZ_7) — vw_commerce_items_v2.product_event_code와
-- 매칭하려면 offer_id(숫자)가 아니라 이 값이어야 함 (원본 total_orders.event_id도 offer_code였음)
commerce_orders AS (
  SELECT
    CAST(c.user_id AS STRING) AS user_id,
    c.offer_code AS event_id,
    CAST(c.option_id AS STRING) AS option_code,
    c.order_qty,
    c.total_revenue,
    o.offer_type,
    o.artist_id,
    o.artist_name
  FROM commerce_lines c
  LEFT JOIN offer_lookup o ON c.offer_id = o.offer_id
  WHERE
    (c.payment_status IN ('CONFIRMED', 'PARTIAL_CANCELED') OR c.order_status IN (1, 10, 11))
    AND c.order_status IN (1, 2, 4, 5, 6, 10, 11)
    -- B2C만 (쇼핑인데 주문번호가 'B'로 시작하면 B2B 차액결제 주문 — 제외)
    AND NOT (o.offer_type = 'S_SHOPPING' AND c.order_no_prefix = 'B')
),

-- ── [v3] 옵션 × 매칭 SKU (아직 콘텐츠 개수만큼 fan-out된 그레인 — 여기서 바로 order에 join하면 안 됨) ──
-- vc(virtual_child_sku_count) 자체는 code로 완전히 대체 불가능함이 실측으로 확인됨(2026-07-15):
--   - item_type=1(포토카드) content_id_list 길이로 시도 → 커버리지 195/11,628건뿐(대부분 슬롯 1개=콘텐츠 1개라 항상 vc=1로 계산됨)
--   - "아티스트 멤버 수"로 시도 → 67%(8,019/11,969)만 일치, 나머지는 버전 종류 수 등 다른 기준
--   → mst_sku.virtual_child_sku_count(OMS)를 값 소스로 유지. 대신 판정 자체는 옵션 단위로
--     먼저 GROUP BY해서 접은 뒤 order에 join하는 구조로 바꿔 fan-out만 원천 차단(원본 버그의 진짜 원인)
option_sku_matches AS (
  SELECT
    i.product_event_code AS event_id,
    i.product_option_id AS option_code,
    s.sku_type,
    s.virtual_child_sku_count
  FROM `makestar-dw.datamart.vw_commerce_items_v2` i
  JOIN `makestar-dw.pg_oms_public.mst_sku` s ON i.sku_code = s.sku_code
),

-- 옵션 단위로 먼저 vc 확정 (포카상품 판정 + 값) — fan-out 방지
option_poca_vc AS (
  SELECT event_id, option_code, MAX(virtual_child_sku_count) AS vc
  FROM option_sku_matches
  WHERE sku_type = 'P' AND virtual_child_sku_count > 1
  GROUP BY 1, 2
),

-- 옵션 단위로 먼저 응모권 여부 확정 — fan-out 방지 (원본과 동일 기준: sku_type NULL/C, 또는 P인데 vc=0)
option_is_omg AS (
  SELECT DISTINCT event_id, option_code
  FROM option_sku_matches
  WHERE sku_type IS NULL OR sku_type = 'C' OR (sku_type = 'P' AND COALESCE(virtual_child_sku_count, 0) = 0)
),

-- ── 포카 상품: qty_ratio (vc > 1) ─────────────────────
-- option_poca_vc가 이미 옵션 단위 1행이라 join해도 fan-out 없음
poca_stats AS (
  SELECT
    o.user_id, o.artist_id, o.event_id, o.option_code,
    SUM(o.order_qty)                                              AS total_qty,
    SAFE_DIVIDE(SUM(o.total_revenue), NULLIF(SUM(o.order_qty),0)) AS unit_price,
    v.vc,
    SAFE_DIVIDE(SUM(o.order_qty), NULLIF(v.vc,0))                 AS qty_ratio
  FROM commerce_orders o
  JOIN option_poca_vc v ON o.event_id = v.event_id AND o.option_code = v.option_code
  WHERE o.user_id NOT IN (SELECT user_id FROM agents)
  GROUP BY 1,2,3,4, v.vc
),

-- ── 응모권 상품: qty >= 10이면 Challenger ──────────
omg_challengers AS (
  SELECT DISTINCT o.user_id
  FROM commerce_orders o
  JOIN option_is_omg h ON o.event_id = h.event_id AND o.option_code = h.option_code
  WHERE o.event_id IS NOT NULL
    AND o.user_id NOT IN (SELECT user_id FROM agents)
  GROUP BY o.user_id, o.event_id, o.option_code
  HAVING SUM(o.order_qty) >= 10
),

-- ── 전체 구매 요약 (Album Collector / Shopper 판별용) ─────────
-- ip_name(아티스트명 텍스트) 대신 artist_id로 집계 — 동일 아티스트의 이름 표기 차이로 인한
-- 중복집계 위험이 없어 더 안전함(숫자 임계값 자체는 변경 없음)
user_purchases AS (
  SELECT
    user_id,
    COUNT(DISTINCT artist_id)                     AS distinct_ips,
    MAX(order_qty)                                AS max_qty,
    -- [v3 변경] event_id IS NOT NULL(쇼핑도 event_id를 가져서 구분 안 되던 결함) 대신
    -- offer_type이 실제 이벤트성(POB/펀딩)인 구매 건수로 판별
    COUNTIF(offer_type IN ('P_POB', 'F_FUNDING')) AS event_order_cnt
  FROM commerce_orders
  WHERE user_id NOT IN (SELECT user_id FROM agents)
  GROUP BY 1
),

-- ── 옵션 단위 포카 분류 (로직 변경 없음) ────────────────────────
poca_labeled AS (
  SELECT o.*,
    CASE
      WHEN w.user_id IS NOT NULL                THEN 'Challenger'
      WHEN o.user_id IN (SELECT user_id FROM omg_challengers) THEN 'Challenger'
      WHEN o.qty_ratio > 1.5                    THEN 'Challenger'
      WHEN o.qty_ratio >= CASE
             WHEN o.unit_price >= 200000 THEN 0.2
             WHEN o.unit_price >= 50000  THEN 0.3
             ELSE 0.5 END                       THEN 'Poca Collector'
      ELSE                                           'Beginner'
    END AS option_label
  FROM poca_stats o
  LEFT JOIN winners w ON o.user_id = w.user_id
),

-- ── 아티스트 단위 집계 (로직 변경 없음) ────────────────────────
artist_lc AS (
  SELECT user_id, artist_id, option_label, COUNT(*) AS cnt
  FROM poca_labeled WHERE artist_id IS NOT NULL GROUP BY 1,2,3
),
artist_labeled AS (
  SELECT user_id, artist_id, option_label AS artist_label
  FROM artist_lc
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id, artist_id
    ORDER BY cnt DESC,
      CASE option_label WHEN 'Challenger' THEN 1 WHEN 'Poca Collector' THEN 2 ELSE 3 END
  ) = 1
),

-- ── 유저 단위 포카 기반 레이블 (로직 변경 없음) ────────────────
user_lc AS (SELECT user_id, artist_label, COUNT(*) AS cnt FROM artist_labeled GROUP BY 1,2),
user_poca_label AS (
  SELECT user_id, artist_label AS poca_label
  FROM user_lc
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id
    ORDER BY cnt DESC,
      CASE artist_label WHEN 'Challenger' THEN 1 WHEN 'Poca Collector' THEN 2 ELSE 3 END
  ) = 1
),

-- ── 최종 5단계 분류 (로직 변경 없음, Shopper 조건의 판별 기준만 코드 기반으로 교체) ──
-- 1. Challenger (당첨/qty>1.5/응모권10장+)
-- 2. Album Collector (artist>=3 AND max_qty<=5, not Challenger)
-- 3. Poca Collector (qty_ratio 범위)
-- 4. Shopper (이벤트성 구매 0건)
-- 5. Beginner
final_dimension AS (
  SELECT
    up.user_id,
    CASE
      -- Challenger: poca 기반 OR 당첨 OR 응모권 대량 (순서 중요)
      WHEN COALESCE(pl.poca_label, 'Beginner') = 'Challenger'    THEN 'Challenger'
      WHEN up.user_id IN (SELECT user_id FROM winners)            THEN 'Challenger'
      WHEN up.user_id IN (SELECT user_id FROM omg_challengers)    THEN 'Challenger'
      -- Album Collector
      WHEN up.distinct_ips >= 3 AND up.max_qty <= 5               THEN 'Album Collector'
      -- Poca Collector
      WHEN COALESCE(pl.poca_label, 'Beginner') = 'Poca Collector' THEN 'Poca Collector'
      -- Shopper: 이벤트(POB/펀딩)성 구매가 단 한 건도 없는 유저
      WHEN up.event_order_cnt = 0                                  THEN 'Shopper'
      ELSE                                                              'Beginner'
    END AS dimension_label
  FROM user_purchases up
  LEFT JOIN user_poca_label pl ON up.user_id = pl.user_id
),

-- ── 주력 아티스트 (datamart 미사용으로 교체, 로직 변경 없음) ──────
artist_gmv AS (
  SELECT user_id, artist_id,
    ANY_VALUE(artist_name) AS artist_name,
    SUM(total_revenue) AS gmv
  FROM commerce_orders
  WHERE user_id NOT IN (SELECT user_id FROM agents)
    AND artist_id IS NOT NULL
  GROUP BY 1,2
),
main_artist AS (
  SELECT user_id, artist_id, artist_name, gmv AS artist_gmv
  FROM artist_gmv
  QUALIFY ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY gmv DESC) = 1
)

-- ── 최종 결과 ─────────────────────────────────────────────────
SELECT
  d.user_id,
  d.dimension_label,
  a.artist_id   AS main_artist_id,
  a.artist_name AS main_artist_name,
  a.artist_gmv  AS main_artist_gmv
FROM final_dimension d
LEFT JOIN main_artist a ON d.user_id = a.user_id
