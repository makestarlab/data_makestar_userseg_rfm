-- ============================================================
-- RFM 원본값 계산
-- R: 마지막 로그인 이후 경과일
-- F: 아티스트당 평균 참여 라운드 수 (라운드 = album_name 단위)
-- M: 누적 총 결제금액 (KRW)
-- ============================================================

WITH

-- 구매대행 제외 목록
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

-- R: 마지막 로그인 기준 경과일
recency AS (
  SELECT
    CAST(id AS STRING)                                             AS user_id,
    DATE_DIFF(
      CURRENT_DATE('Asia/Seoul'),
      DATE(last_login, 'Asia/Seoul'),
      DAY
    )                                                              AS days_since_login
  FROM `makestar-dw.pg_mystarroom_public.tb_auth_user`
  WHERE last_login    IS NOT NULL
    AND is_certified  = TRUE
    AND is_withdrawn  = FALSE
),

-- 주문 기반 기초 집계 (구매대행 제외)
orders AS (
  SELECT
    o.user_id,
    o.order_no,
    o.total_revenue,
    o.event_id,
    e.artist_id,
    e.album_name
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  WHERE o.market_type IN ('B2C', 'B2B')
    AND o.user_id NOT IN (SELECT user_id FROM agents)
),

-- F: 아티스트당 평균 참여 라운드 수
-- 라운드 = artist_id × album_name 조합
frequency AS (
  SELECT
    user_id,
    COUNT(DISTINCT CONCAT(artist_id, '||', album_name)) AS total_rounds,
    COUNT(DISTINCT artist_id)                           AS total_artists,
    SAFE_DIVIDE(
      COUNT(DISTINCT CONCAT(artist_id, '||', album_name)),
      COUNT(DISTINCT artist_id)
    )                                                   AS f_raw
  FROM orders
  WHERE artist_id IS NOT NULL
    AND album_name IS NOT NULL
  GROUP BY user_id
),

-- M: 누적 총 결제금액
monetary AS (
  SELECT
    user_id,
    SUM(total_revenue) AS m_raw
  FROM orders
  GROUP BY user_id
)

SELECT
  r.user_id,
  r.days_since_login                       AS r_raw,
  COALESCE(f.f_raw, 0)                     AS f_raw,
  COALESCE(m.m_raw, 0)                     AS m_raw,
  COALESCE(f.total_rounds, 0)              AS total_rounds,
  COALESCE(f.total_artists, 0)             AS total_artists
FROM recency r
LEFT JOIN frequency f ON r.user_id = f.user_id
LEFT JOIN monetary  m ON r.user_id = m.user_id
