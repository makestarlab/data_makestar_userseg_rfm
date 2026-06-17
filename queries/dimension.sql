-- ============================================================
-- 2nd Depth Dimension 분류
-- 집계: 유저 × 아티스트 × 이벤트 × 옵션 → 아티스트 → 유저
--
-- qty_ratio  : user × event_id × option_code 단위
-- 가격(unit_price): SUM(total_revenue) / SUM(order_qty) 옵션 단가
-- 당첨 이력  : tb_commerce_event_winner_group.winner_list
--
-- 분류 우선순위:
--   1. 당첨 이력 있음           → Challenger
--   2. qty_ratio > 1.0          → Challenger
--   3. qty_ratio >= threshold   → Collector  (가격대별 하한)
--   4. qty_ratio < threshold    → Beginner
--
-- 가격대별 Collector 하한:
--   ~5만원    : 0.5
--   5~20만원  : 0.3
--   20만원+   : 0.2
-- ============================================================

WITH

agents AS (
  SELECT user_id FROM UNNEST([
    '1876860','812307','1736734','621230','1302313','1902098','859600','969308',
    '1027784','1581799','797962','802866','1492647','781240','885795','1264675',
    '1001311','2116643','1659287','700815','1540460','1890901','1511280','1006060',
    '1606082','1552669','1913216','1138597','1284854','1504890','12526','944286',
    '945344','2046425','1545878','1600974','886898','1539934','1533310','911936',
    '1069252','971976','1658602','948579','1071325','1995221','1933087','636546',
    '1509180','1257147','2032775','1323619','1958765','864765','1994769','209076',
    '1608153','1312465','1355103','1248833','1506290','965150','1011224','1260938',
    '625886','939836','1870283','1347032','1939835','1973097','2022335','1335644',
    '1975403','646210','1542033','910047','1995697','882978','1252380','2159123',
    '867147','942107','1329252','71764','1845002','999056','809695','1604186',
    '1506617','1006091','870982','1895495','1052115','1313023','1254035','1063330',
    '2050980','1550897','1660416','1620875','946338','1482920','1253405','1502990',
    '91909','1738982','2114301','1005028','1513305','1874153','1267050','1354020',
    '1062950','905126','1071819','1935908','1073305','1247698','898061','943715',
    '1673444','1334025','1982712','1290379','1503928','1502504','2159410'
  ]) AS user_id
),

-- 당첨 이력 유저 목록
winners AS (
  SELECT DISTINCT CAST(o.user_id AS STRING) AS user_id
  FROM `makestar-dw.pg_mystarroom_public.tb_commerce_event_winner_group`
  JOIN UNNEST(JSON_EXTRACT_ARRAY(winner_list)) b
  JOIN `makestar-dw.pg_mystarroom_public.tb_commerce_order` o
    ON JSON_VALUE(b.information.order.order_number) = o.order_number
  WHERE JSON_VALUE(b.user.id) != '-1'
),

-- ── qty_ratio: user × event_id × option_code 단위 ─────────────
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
    AND o.user_id NOT IN (SELECT user_id FROM agents)
    AND s.virtual_child_sku_count > 1
  GROUP BY 1,2,3,4
),

-- ── 가격대별 Collector 하한 ────────────────────────────────────
option_labeled AS (
  SELECT *,
    CASE
      WHEN unit_price >= 200000 THEN 0.2
      WHEN unit_price >= 50000  THEN 0.3
      ELSE                           0.5
    END AS collector_threshold
  FROM option_stats
),

-- ── 옵션 단위 분류 ─────────────────────────────────────────────
event_labeled AS (
  SELECT o.*,
    CASE
      WHEN w.user_id IS NOT NULL               THEN 'Challenger'
      WHEN o.qty_ratio > 1.0                   THEN 'Challenger'
      WHEN o.qty_ratio >= o.collector_threshold THEN 'Collector'
      ELSE                                          'Beginner'
    END AS option_label
  FROM option_labeled o
  LEFT JOIN winners w ON o.user_id = w.user_id
),

-- ── 아티스트 단위 ─────────────────────────────────────────────
artist_label_counts AS (
  SELECT user_id, artist_id, option_label, COUNT(*) AS cnt
  FROM event_labeled WHERE artist_id IS NOT NULL
  GROUP BY 1,2,3
),
artist_labeled AS (
  SELECT user_id, artist_id, option_label AS artist_label
  FROM artist_label_counts
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id, artist_id
    ORDER BY cnt DESC,
      CASE option_label WHEN 'Challenger' THEN 1 WHEN 'Collector' THEN 2 ELSE 3 END
  ) = 1
),

-- ── 유저 단위 ─────────────────────────────────────────────────
user_label_counts AS (
  SELECT user_id, artist_label, COUNT(*) AS cnt
  FROM artist_labeled GROUP BY 1,2
),
user_dimension AS (
  SELECT user_id, artist_label AS dimension_label
  FROM user_label_counts
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id
    ORDER BY cnt DESC,
      CASE artist_label WHEN 'Challenger' THEN 1 WHEN 'Collector' THEN 2 ELSE 3 END
  ) = 1
),

-- ── 주력 아티스트 ─────────────────────────────────────────────
artist_gmv AS (
  SELECT
    o.user_id, e.artist_id,
    MAX(o.ip_name) AS artist_name,
    SUM(o.total_revenue) AS gmv
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  WHERE o.market_type IN ('B2C','B2B')
    AND o.data_source = 'new_commerce_db'
    AND o.user_id NOT IN (SELECT user_id FROM agents)
    AND e.artist_id IS NOT NULL
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
FROM user_dimension d
LEFT JOIN main_artist a ON d.user_id = a.user_id
