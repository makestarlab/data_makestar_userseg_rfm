-- ============================================================
-- CRM 통합 유저 테이블
-- 저장: makestar-dw.datamart.crm_users
-- 주기: 주 1회 전체 재생성 (Airflow DAG)
-- ============================================================

CREATE OR REPLACE TABLE `makestar-dw.datamart.crm_users` AS

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

-- 유저 기본 정보
user_base AS (
  SELECT
    CAST(u.id AS STRING)                              AS user_id,
    u.email,
    u.created_from,                                    -- 가입 서비스 (MAKESTAR, POCAALBUM 등)
    DATE(u.created_at, 'Asia/Seoul')                  AS signup_date,
    DATE(u.last_login, 'Asia/Seoul')                  AS last_login,
    u.is_withdrawn,
    u.is_active,
    i.country_code,
    i.gender_type,
    DATE(i.birth, 'Asia/Seoul')                       AS birth_date
  FROM `makestar-dw.pg_mystarroom_public.tb_auth_user` u
  LEFT JOIN `makestar-dw.pg_mystarroom_public.tb_auth_user_information` i
         ON u.id = i.user_id
  WHERE u.is_certified = TRUE
),

-- 구매 이력 (new_commerce_db 기준)
purchase_stats AS (
  SELECT
    user_id,
    MIN(DATE(pay_date))                               AS first_purchase_date,
    MAX(DATE(pay_date))                               AS last_purchase_date,
    COUNT(DISTINCT order_no)                          AS total_orders,
    ROUND(SUM(total_revenue))                         AS total_gmv,
    ROUND(SAFE_DIVIDE(SUM(total_revenue), COUNT(DISTINCT order_no))) AS avg_order_value,
    COUNT(DISTINCT DATE_TRUNC(DATE(pay_date), MONTH)) AS active_months
  FROM `makestar-dw.datamart.total_orders`
  WHERE market_type = 'B2C'
    AND data_source = 'new_commerce_db'
    AND user_id NOT IN (SELECT user_id FROM agents)
  GROUP BY user_id
)

SELECT
  -- ── 유저 식별 ───────────────────────────────────────
  u.user_id,
  u.email,
  u.created_from,
  u.signup_date,
  u.last_login,
  u.birth_date,
  u.country_code,
  u.gender_type,
  u.is_withdrawn,
  u.is_active,

  -- ── 구매 이력 ───────────────────────────────────────
  p.first_purchase_date,
  p.last_purchase_date,
  COALESCE(p.total_orders, 0)     AS total_orders,
  COALESCE(p.total_gmv, 0)        AS total_gmv,
  COALESCE(p.avg_order_value, 0)  AS avg_order_value,
  COALESCE(p.active_months, 0)    AS active_months,

  -- ── RFM Raw 값 ──────────────────────────────────────
  r.r_raw,                        -- 마지막 로그인 경과일
  r.f_raw,                        -- 아티스트당 평균 라운드 수
  r.m_raw,                        -- 누적 GMV

  -- ── RFM 스코어 (1~5) ────────────────────────────────
  r.r_score,
  r.f_score,
  r.m_score,
  r.r_score + r.f_score + r.m_score AS rfm_total,

  -- ── 2nd Depth Dimension ─────────────────────────────
  COALESCE(d.dimension_label, 'Beginner') AS dimension_label,
  d.main_artist_id,
  d.main_artist_name,
  d.main_artist_gmv,

  -- ── 메타 ────────────────────────────────────────────
  CURRENT_TIMESTAMP()             AS updated_at

FROM user_base u
LEFT JOIN `makestar-dw.datamart.user_rfm_score`     r ON u.user_id = r.user_id
LEFT JOIN `makestar-dw.datamart.user_rfm_dimension` d ON u.user_id = d.user_id
LEFT JOIN purchase_stats                            p ON u.user_id = p.user_id
