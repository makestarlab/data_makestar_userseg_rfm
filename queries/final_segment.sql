-- ============================================================
-- 최종 세그먼트 통합 테이블 생성
-- BQ 저장: makestar-dw.datamart.user_rfm_segment
-- ============================================================

CREATE OR REPLACE TABLE `makestar-dw.datamart.user_rfm_segment` AS

WITH rfm AS (
  -- rfm_score.sql 결과
  SELECT * FROM (
    WITH base AS (
      -- rfm_base.sql 내용 삽입
      WITH agents AS (
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
      recency AS (
        SELECT
          CAST(id AS STRING) AS user_id,
          DATE_DIFF(CURRENT_DATE('Asia/Seoul'), DATE(last_login, 'Asia/Seoul'), DAY) AS days_since_login
        FROM `makestar-dw.pg_mystarroom_public.tb_auth_user`
        WHERE last_login IS NOT NULL AND is_certified = TRUE AND is_withdrawn = FALSE
      ),
      orders AS (
        SELECT o.user_id, o.order_no, o.total_revenue, o.event_id, e.artist_id, e.album_name
        FROM `makestar-dw.datamart.total_orders` o
        LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
        WHERE o.market_type IN ('B2C','B2B')
          AND o.user_id NOT IN (SELECT user_id FROM agents)
      ),
      frequency AS (
        SELECT
          user_id,
          COUNT(DISTINCT CONCAT(artist_id,'||',album_name)) AS total_rounds,
          COUNT(DISTINCT artist_id) AS total_artists,
          SAFE_DIVIDE(COUNT(DISTINCT CONCAT(artist_id,'||',album_name)), COUNT(DISTINCT artist_id)) AS f_raw
        FROM orders WHERE artist_id IS NOT NULL AND album_name IS NOT NULL
        GROUP BY user_id
      ),
      monetary AS (
        SELECT user_id, SUM(total_revenue) AS m_raw FROM orders GROUP BY user_id
      )
      SELECT
        r.user_id,
        r.days_since_login AS r_raw,
        COALESCE(f.f_raw, 0) AS f_raw,
        COALESCE(m.m_raw, 0) AS m_raw
      FROM recency r
      LEFT JOIN frequency f ON r.user_id = f.user_id
      LEFT JOIN monetary  m ON r.user_id = m.user_id
    )
    SELECT
      user_id, r_raw, f_raw, m_raw,
      6 - NTILE(5) OVER (ORDER BY r_raw ASC) AS r_score,
      NTILE(5) OVER (ORDER BY f_raw ASC)     AS f_score,
      NTILE(5) OVER (ORDER BY m_raw ASC)     AS m_score
    FROM base WHERE m_raw > 0
  )
),

dim AS (
  -- dimension.sql 결과 (간략화 — 실제 실행 시 dimension.sql CTE 전체 삽입)
  SELECT user_id, dimension_label, main_artist_id, main_artist_name
  FROM `makestar-dw.datamart.user_rfm_dimension`  -- dimension.sql 먼저 저장 후 참조
)

SELECT
  r.user_id,
  r.r_raw,
  r.f_raw,
  r.m_raw,
  r.r_score,
  r.f_score,
  r.m_score,
  r.r_score + r.f_score + r.m_score        AS rfm_total,
  d.dimension_label,
  d.main_artist_id,
  d.main_artist_name,
  CURRENT_TIMESTAMP()                       AS updated_at
FROM rfm r
LEFT JOIN dim d ON r.user_id = d.user_id
