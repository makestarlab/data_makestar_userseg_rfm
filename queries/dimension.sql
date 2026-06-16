-- ============================================================
-- 2nd Depth Dimension 분류
-- Collector / Challenger / Beginner (라운드 단위 분류 후 유저 레이블링)
-- Artist (주력 아티스트)
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

-- 주문 × 이벤트 × SKU 연결
order_with_round AS (
  SELECT
    o.user_id,
    o.order_no,
    o.event_id,
    o.option_code,
    o.order_qty,
    o.total_revenue,
    e.artist_id,
    e.album_name,                              -- 라운드 단위
    e.event_type,
    i.sku_code,
    s.virtual_child_sku_count
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e
    ON o.event_id = e.event_id
  LEFT JOIN `makestar-dw.datamart.vw_commerce_items_v2` i
    ON o.event_id   = i.product_event_code
    AND o.option_code = i.product_option_id
  LEFT JOIN `makestar-dw.pg_oms_public.mst_sku` s
    ON i.sku_code = s.sku_code
  WHERE o.market_type IN ('B2C', 'B2B')
    AND o.user_id NOT IN (SELECT user_id FROM agents)
),

-- ── 라운드 단위 분류 ──────────────────────────────────────────

-- Collector: virtual_child_sku_count > 1 인 SKU 포함 라운드
-- 라운드 내 해당 옵션 총 구매수 vs virtual_child_sku_count 비교
round_collector AS (
  SELECT
    user_id,
    artist_id,
    album_name,
    SUM(order_qty)             AS round_qty,
    MAX(virtual_child_sku_count) AS sku_variety  -- 라운드 내 최대 종류 수
  FROM order_with_round
  WHERE virtual_child_sku_count > 1
    AND album_name IS NOT NULL
  GROUP BY user_id, artist_id, album_name
),

round_collector_labeled AS (
  SELECT
    user_id,
    artist_id,
    album_name,
    round_qty,
    sku_variety,
    CASE
      WHEN round_qty < sku_variety  THEN 'Collector_Partial'
      WHEN round_qty = sku_variety  THEN 'Collector_Full'
      WHEN round_qty > sku_variety  THEN 'Collector_Over'
    END AS round_label
  FROM round_collector
),

-- Challenger: 라운드 내 이벤트 응모 주문 비중 (event_id IS NOT NULL)
round_challenger AS (
  SELECT
    user_id,
    artist_id,
    album_name,
    COUNT(DISTINCT order_no)                                         AS round_orders,
    COUNT(DISTINCT CASE WHEN event_id IS NOT NULL THEN order_no END) AS event_orders,
    SAFE_DIVIDE(
      COUNT(DISTINCT CASE WHEN event_id IS NOT NULL THEN order_no END),
      COUNT(DISTINCT order_no)
    )                                                                AS event_ratio
  FROM order_with_round
  WHERE album_name IS NOT NULL
  GROUP BY user_id, artist_id, album_name
),

-- 라운드별 최종 레이블 (Challenger 우선)
round_labeled AS (
  SELECT
    COALESCE(ch.user_id, cl.user_id)         AS user_id,
    COALESCE(ch.artist_id, cl.artist_id)     AS artist_id,
    COALESCE(ch.album_name, cl.album_name)   AS album_name,
    CASE
      WHEN ch.event_ratio >= 0.5             THEN 'Challenger'
      WHEN cl.round_label IS NOT NULL        THEN cl.round_label
      ELSE 'Beginner'
    END                                      AS round_label
  FROM round_challenger ch
  FULL OUTER JOIN round_collector_labeled cl
    ON ch.user_id   = cl.user_id
    AND ch.artist_id = cl.artist_id
    AND ch.album_name = cl.album_name
),

-- ── 유저 단위 레이블링 ─────────────────────────────────────────
-- 가장 많이 나온 패턴 → 최종 레이블
-- 동률: Challenger > Collector_Over > Collector_Full > Collector_Partial > Beginner
user_label_counts AS (
  SELECT
    user_id,
    round_label,
    COUNT(*) AS label_cnt
  FROM round_labeled
  GROUP BY user_id, round_label
),

user_dimension AS (
  SELECT
    user_id,
    ARRAY_AGG(round_label ORDER BY
      label_cnt DESC,
      CASE round_label
        WHEN 'Challenger'        THEN 1
        WHEN 'Collector_Over'    THEN 2
        WHEN 'Collector_Full'    THEN 3
        WHEN 'Collector_Partial' THEN 4
        ELSE 5
      END
      LIMIT 1
    )[SAFE_OFFSET(0)]            AS dimension_label
  FROM user_label_counts
  GROUP BY user_id
),

-- ── Artist: 주력 아티스트 ──────────────────────────────────────
artist_gmv AS (
  SELECT
    o.user_id,
    e.artist_id,
    i.artist_name,
    SUM(o.total_revenue)  AS artist_gmv
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  LEFT JOIN (
    SELECT DISTINCT product_event_code, artist_name
    FROM `makestar-dw.datamart.vw_commerce_items_v2`
  ) i ON o.event_id = i.product_event_code
  WHERE o.market_type IN ('B2C', 'B2B')
    AND o.user_id NOT IN (SELECT user_id FROM agents)
    AND e.artist_id IS NOT NULL
  GROUP BY o.user_id, e.artist_id, i.artist_name
),

main_artist AS (
  SELECT
    user_id,
    ARRAY_AGG(
      STRUCT(artist_id, artist_name, artist_gmv)
      ORDER BY artist_gmv DESC LIMIT 1
    )[SAFE_OFFSET(0)] AS top_artist
  FROM artist_gmv
  GROUP BY user_id
)

-- ── 최종 통합 ─────────────────────────────────────────────────
SELECT
  d.user_id,
  d.dimension_label,
  a.top_artist.artist_id   AS main_artist_id,
  a.top_artist.artist_name AS main_artist_name,
  a.top_artist.artist_gmv  AS main_artist_gmv
FROM user_dimension d
LEFT JOIN main_artist a ON d.user_id = a.user_id
