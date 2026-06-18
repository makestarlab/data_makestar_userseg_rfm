-- ============================================================
-- 2nd Depth Dimension 분류 (v2)
-- 4단계: Challenger / Album Collector / Poca Collector / Beginner
--
-- [Challenger] (우선순위 1)
--   - 당첨 이력 있음
--   - qty_ratio > 1.5 (vc > 1 포카 상품)
--   - 응모권 상품(vc=0/NULL) SUM(order_qty) >= 10
--
-- [Album Collector] (우선순위 2)
--   - NOT Challenger
--   - COUNT(DISTINCT ip_name) >= 3 AND MAX(order_qty) <= 5
--
-- [Poca Collector] (우선순위 3)
--   - NOT Challenger, NOT Album Collector
--   - qty_ratio >= 가격대별 하한 (0.2~0.5)
--
-- [Beginner] (우선순위 4)
--   - 나머지
--
-- 가격대별 Poca Collector 하한:
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
    '1673444','1334025','1982712','1290379','1503928','1502504','2159410',
    -- makestar.com 추가분
    '2308791','2065197','1966353','2108478','1973103','1967649','1962518','1651127',
    -- B2B 구매대행 추가 (2차)
    '1494663','1258217','972756','1480569','1259545','1006027','1255662','1058426','1244607','1501762','1254620','1348964','1076452','1322237','1338060','1062458','1297787','1286096','1288283','1072082','1265855','1495652','996807','1468276','1244739','977248','972130','1472608','1004909','995332','1051856','987358','1346872','1002300','943898','1323824','1297564','1327819','1005817','1058484','1281717','996716','1313605','1249057','1293236','958834','1005876','988738','997518','1292877','1499076','1254653','1319204','1469325','981974','1482736','1254866','1063821','1470750','1263588','977208','1251349','1324898','1245755','955897','1481098','1263999','1005685','1342389','983775','1063741','1290619','1282287','1073634','1334387','1050606','1058279','1000646','1477942','1005390','1350547','1468062','1324648','1288815','1337517','1003062','1311659','1058452','921754','1337269','1325667','956410','900504','1253814','980648','1344536','1323806','1255330','1004064','1324353',
    -- makestar.com 내부 계정 전체 (271개)
    '1','2','4','5','6','11','23','28','46','47','81','149','250','293','445','446','506','639','640','642','660','1143','1669','1698','2266','3570','3697','6397','7323','7405','9969','13710','18891','18894','18907','18910','18918','18922','18937','18941','18943','25527','27096','31592','61472','65178','75428','77164','81888','89996','91817','94183','114029','116449','118315','135807','158291','159444','171365','171433','183250','191191','200172','634299','703146','777996','779425','780061','873495','912353','913997','916406','924614','927469','952068','957967','958079','978851','1052062','1052063','1072108','1248703','1266580','1297564','1311611','1325480','1468256','1482741','1495292','1529990','1545005','1548348','1600245','1600492','1600495','1601827','1612695','1628967','1641220','1645106','1645266','1645965','1650883','1651127','1674672','1674702','1697154','1709547','1733846','1750907','1763267','1766373','1777929','1821468','1831384','1833148','1843309','1849858','1873463','1873637','1875148','1876851','1878152','1878641','1878643','1881909','1890911','1893867','1901629','1907491','1908565','1913442','1913658','1917824','1917825','1917826','1917867','1917868','1917870','1917871','1917872','1917873','1918208','1920091','1920207','1920253','1921331','1922190','1922323','1924210','1924273','1925289','1928348','1928421','1928595','1928604','1929489','1939880','1944677','1944678','1944790','1951334','1953163','1961321','1962518','1962948','1962950','1966113','1966181','1966353','1967649','1972061','1973103','1976288','1977684','1984821','1987033','2001809','2007916','2010410','2012770','2013196','2018509','2022128','2029267','2034114','2034894','2037880','2040138','2040417','2040419','2047053','2047862','2047934','2048523','2048754','2050183','2050512','2052554','2063566','2063973','2064638','2064873','2065197','2073991','2074693','2080193','2085818','2086326','2090320','2092774','2099682','2103431','2105715','2108478','2112627','2113859','2114330','2116477','2116575','2116643','2117074','2121241','2129227','2132673','2132707','2132737','2142915','2146416','2149239','2149241','2149489','2154856','2161922','2162318','2168465','2170725','2184510','2187366','2189092','2208829','2216236','2219279','2223971','2233650','2238011','2238047','2238604','2242193','2246393','2246854','2246968','2251552','2256789','2258846','2258853','2258864','2258883','2262807','2267385','2277798','2281976','2293704','2293705','2297965','2297968','2302762','2306968','2308791','2310926','2312066'
    -- B2B/운영 계정 추가 제외
    '2293705','2293704','2302812','2048754','1984821','2132737','2116643','1986193','2073991','2063566','1976288',
    '1','2','4','5','6','11','23','28','46','47','81','149','250','293','445','446','506','639','640','642','660','1143','1669','1698','2266','3570','3697','6397','7323','7405','9969','13710','18891','18894','18907','18910','18918','18922','18937','18941','18943','25527','27096','31592','61472','65178','75428','77164','81888','89996','91817','94183','114029','116449','118315','135807','158291','159444','171365','171433','183250','191191','200172','634299','703146','777996','779425','780061','873495','912353','913997','916406','924614','927469','952068','957967','958079','978851','1052062','1052063','1072108','1248703','1266580','1297564','1311611','1325480','1468256','1482741','1495292','1529990','1545005','1548348','1600245','1600492','1600495','1601827','1612695','1628967','1641220','1645106'
  ]) AS user_id
),

-- 당첨 이력
winners AS (
  SELECT DISTINCT CAST(o.user_id AS STRING) AS user_id
  FROM `makestar-dw.pg_mystarroom_public.tb_commerce_event_winner_group`
  JOIN UNNEST(JSON_EXTRACT_ARRAY(winner_list)) b
  JOIN `makestar-dw.pg_mystarroom_public.tb_commerce_order` o
    ON JSON_VALUE(b.information.order.order_number) = o.order_number
  WHERE JSON_VALUE(b.user.id) != '-1'
),

-- ── 포카 상품: qty_ratio (vc > 1, P타입) ─────────────────────
poca_stats AS (
  SELECT
    o.user_id, e.artist_id, o.event_id, o.option_code,
    SUM(o.order_qty)                                                        AS total_qty,
    SAFE_DIVIDE(SUM(o.total_revenue), NULLIF(SUM(o.order_qty), 0))          AS unit_price,
    MAX(s.virtual_child_sku_count)                                          AS vc,
    SAFE_DIVIDE(SUM(o.order_qty), NULLIF(MAX(s.virtual_child_sku_count),0)) AS qty_ratio
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  LEFT JOIN `makestar-dw.datamart.vw_commerce_items_v2` i
         ON o.event_id = i.product_event_code AND o.option_code = i.product_option_id
  LEFT JOIN `makestar-dw.pg_oms_public.mst_sku` s ON i.sku_code = s.sku_code
  WHERE o.market_type = 'B2C'
    AND o.data_source = 'new_commerce_db'
    AND o.user_id NOT IN (SELECT user_id FROM agents)
    AND s.sku_type = 'P' AND s.virtual_child_sku_count > 1
  GROUP BY 1,2,3,4
),

-- ── 응모권 상품: qty >= 10이면 Challenger (vc=0/NULL) ──────────
omg_challengers AS (
  SELECT DISTINCT o.user_id
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.vw_commerce_items_v2` i
         ON o.event_id = i.product_event_code AND o.option_code = i.product_option_id
  LEFT JOIN `makestar-dw.pg_oms_public.mst_sku` s ON i.sku_code = s.sku_code
  WHERE o.market_type = 'B2C'
    AND o.data_source = 'new_commerce_db'
    AND o.event_id IS NOT NULL
    AND o.user_id NOT IN (SELECT user_id FROM agents)
    AND (s.sku_type IS NULL OR s.sku_type = 'C'
         OR (s.sku_type = 'P' AND COALESCE(s.virtual_child_sku_count,0) = 0))
  GROUP BY o.user_id, o.event_id, o.option_code
  HAVING SUM(o.order_qty) >= 10
),

-- ── 전체 구매 요약 (Album Collector / Shopper 판별용) ─────────
user_purchases AS (
  SELECT
    user_id,
    COUNT(DISTINCT ip_name)                                     AS distinct_ips,
    MAX(order_qty)                                              AS max_qty,
    COUNTIF(event_id IS NOT NULL AND event_id != '')            AS event_order_cnt
  FROM `makestar-dw.datamart.total_orders`
  WHERE market_type = 'B2C'
    AND data_source = 'new_commerce_db'
    AND user_id NOT IN (SELECT user_id FROM agents)
  GROUP BY 1
),

-- ── 옵션 단위 포카 분류 ────────────────────────────────────────
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

-- ── 아티스트 단위 집계 ────────────────────────────────────────
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

-- ── 유저 단위 포카 기반 레이블 ────────────────────────────────
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

-- ── 최종 4단계 분류 ───────────────────────────────────────────
-- 1. Challenger (당첨/qty>1.5/응모권10장+)
-- 2. Album Collector (ip>=3 AND max_qty<=5, not Challenger)
-- 3. Poca Collector (qty_ratio 범위)
-- 4. Beginner
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
      -- Shopper: 이벤트 구매가 단 한 건도 없는 유저
      WHEN up.event_order_cnt = 0                                  THEN 'Shopper'
      ELSE                                                              'Beginner'
    END AS dimension_label
  FROM user_purchases up
  LEFT JOIN user_poca_label pl ON up.user_id = pl.user_id
),

-- ── 주력 아티스트 ─────────────────────────────────────────────
artist_gmv AS (
  SELECT o.user_id, e.artist_id,
    MAX(o.ip_name) AS artist_name,
    SUM(o.total_revenue) AS gmv
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  WHERE o.market_type = 'B2C'
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
FROM final_dimension d
LEFT JOIN main_artist a ON d.user_id = a.user_id
