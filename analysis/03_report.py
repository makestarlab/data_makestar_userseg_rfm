"""
RFM + Dimension 분석 결과 → HTML 리포트 생성
페르소나 카드 + CRM 액션 예시 포함
"""

from google.cloud import bigquery
from pathlib import Path
import json

KEY_PATH = "YOUR_BQ_SERVICE_ACCOUNT_KEY.json"
PROJECT_ID = "makestar-dw"
OUTPUT_PATH = Path(__file__).parent.parent / "output" / "rfm_report.html"

def fetch_data(client):
    q = """
    SELECT
      dimension_label,
      r_score, f_score, m_score, rfm_total,
      main_artist_name,
      COUNT(*)                        AS user_cnt,
      ROUND(AVG(r_raw))               AS avg_days_since_login,
      ROUND(AVG(f_raw), 1)            AS avg_rounds_per_artist,
      ROUND(AVG(m_raw))               AS avg_gmv,
      ROUND(AVG(rfm_total), 1)        AS avg_rfm_total
    FROM `makestar-dw.datamart.user_rfm_segment`
    GROUP BY 1,2,3,4,5,6
    ORDER BY avg_rfm_total DESC
    """
    summary_q = """
    SELECT
      dimension_label,
      COUNT(*)                       AS user_cnt,
      ROUND(AVG(rfm_total), 1)       AS avg_rfm,
      ROUND(AVG(m_raw))              AS avg_gmv,
      ROUND(AVG(r_raw))              AS avg_days_since_login,
      ROUND(AVG(f_raw), 1)           AS avg_rounds_per_artist,
      COUNTIF(r_score = 5) * 100.0 / COUNT(*) AS pct_active
    FROM `makestar-dw.datamart.user_rfm_segment`
    GROUP BY 1
    ORDER BY avg_rfm DESC
    """
    rfm_dist_q = """
    SELECT
      r_score, f_score, m_score,
      COUNT(*) AS user_cnt
    FROM `makestar-dw.datamart.user_rfm_segment`
    GROUP BY 1,2,3
    ORDER BY 1,2,3
    """
    top_artists_q = """
    SELECT
      main_artist_name,
      dimension_label,
      COUNT(*) AS user_cnt,
      ROUND(AVG(m_raw)) AS avg_gmv
    FROM `makestar-dw.datamart.user_rfm_segment`
    WHERE main_artist_name IS NOT NULL
    GROUP BY 1,2
    ORDER BY user_cnt DESC
    LIMIT 20
    """

    summary = [dict(r) for r in client.query(summary_q).result()]
    rfm_dist = [dict(r) for r in client.query(rfm_dist_q).result()]
    top_artists = [dict(r) for r in client.query(top_artists_q).result()]
    total_users = sum(r['user_cnt'] for r in summary)

    return summary, rfm_dist, top_artists, total_users


PERSONAS = {
    "Challenger": {
        "emoji": "🏆",
        "name": "챌린저",
        "desc": "당첨을 위해 수량을 베팅하는 열성 팬. 전종 초과 구매로 응모 확률을 극대화.",
        "traits": ["높은 구매금액", "동일 이벤트 고수량 구매", "아티스트 충성도 강함"],
        "color": "#FF6B6B",
    },
    "Collector": {
        "emoji": "📦",
        "name": "콜렉터",
        "desc": "멤버 포카를 빠짐없이 모으는 수집가. 전종 정확히 구매하는 체계적인 팬.",
        "traits": ["virtual_child_sku_count 기준 정확한 구매", "다양한 버전 구매", "완성도 중시"],
        "color": "#4ECDC4",
    },
    "Beginner": {
        "emoji": "🌱",
        "name": "비기너",
        "desc": "특정 특전이 탐나서 소량 구매하는 라이트 팬. 다양한 아티스트에 관심.",
        "traits": ["소량 구매", "다양한 이벤트 탐색", "잠재적 충성 팬"],
        "color": "#95E1D3",
    },
}

CRM_ACTIONS = {
    "Challenger": [
        {"action": "응모 우선권 제공", "desc": "일정 금액 이상 구매 시 추가 응모권 자동 부여"},
        {"action": "VIP 얼리버드", "desc": "신규 이벤트 오픈 24시간 전 선구매 알림"},
        {"action": "누적 구매 리워드", "desc": "라운드별 누적 구매금액 달성 시 한정 굿즈 제공"},
        {"action": "당첨 확률 강조 마케팅", "desc": "구매량 대비 당첨 확률 시뮬레이션 제공"},
    ],
    "Collector": [
        {"action": "전종 세트 할인", "desc": "virtual_child_sku_count 수량 구매 시 N% 할인"},
        {"action": "미수집 버전 알림", "desc": "아직 구매하지 않은 멤버 버전 재고 알림"},
        {"action": "컬렉션 달성 배지", "desc": "전종 수집 완료 시 앱 내 배지 + 인증 혜택"},
        {"action": "시즌 컬렉션 예고", "desc": "다음 라운드 신규 포카 버전 선공개 알림"},
    ],
    "Beginner": [
        {"action": "입문 패키지 추천", "desc": "1~2장 소량 구매 가능한 스타터 상품 노출"},
        {"action": "아티스트 탐색 유도", "desc": "관심 아티스트 기반 신규 이벤트 추천"},
        {"action": "첫 전종 달성 챌린지", "desc": "처음 전종 구매 시 특별 혜택으로 Collector 전환 유도"},
        {"action": "리타겟팅 캠페인", "desc": "마지막 구매 이후 관심 아티스트 이벤트 오픈 시 알림"},
    ],
}


def generate_html(summary, rfm_dist, top_artists, total_users):
    summary_by_label = {r['dimension_label']: r for r in summary}

    persona_cards = ""
    for label, p in PERSONAS.items():
        s = summary_by_label.get(label, {})
        cnt = s.get('user_cnt', 0)
        pct = cnt / total_users * 100 if total_users else 0
        avg_gmv = f"₩{s.get('avg_gmv', 0):,.0f}" if s.get('avg_gmv') else '-'
        avg_rfm = s.get('avg_rfm', '-')
        avg_days = s.get('avg_days_since_login', '-')

        actions_html = "".join(
            f'<div class="crm-item"><strong>{a["action"]}</strong><p>{a["desc"]}</p></div>'
            for a in CRM_ACTIONS[label]
        )

        traits_html = "".join(f'<span class="trait">{t}</span>' for t in p['traits'])

        persona_cards += f"""
        <div class="persona-card" style="border-top: 4px solid {p['color']}">
          <div class="persona-header">
            <span class="emoji">{p['emoji']}</span>
            <div>
              <h2>{p['name']}</h2>
              <span class="badge" style="background:{p['color']}">{cnt:,}명 ({pct:.1f}%)</span>
            </div>
          </div>
          <p class="persona-desc">{p['desc']}</p>
          <div class="traits">{traits_html}</div>
          <div class="stats-row">
            <div class="stat"><label>평균 RFM</label><value>{avg_rfm}</value></div>
            <div class="stat"><label>평균 GMV</label><value>{avg_gmv}</value></div>
            <div class="stat"><label>평균 미접속</label><value>{avg_days}일</value></div>
          </div>
          <h3>CRM 액션 예시</h3>
          <div class="crm-actions">{actions_html}</div>
        </div>
        """

    top_artist_rows = "".join(
        f"<tr><td>{r['main_artist_name']}</td><td>{r['dimension_label']}</td>"
        f"<td>{r['user_cnt']:,}</td><td>₩{r['avg_gmv']:,.0f}</td></tr>"
        for r in top_artists[:10]
    )

    return f"""<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Makestar 유저 세그멘테이션 — RFM Report</title>
<style>
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #f5f5f7; color: #1d1d1f; padding: 24px; }}
  h1 {{ font-size: 28px; font-weight: 700; margin-bottom: 4px; }}
  .subtitle {{ color: #6e6e73; margin-bottom: 32px; }}
  .summary-bar {{ display: flex; gap: 16px; margin-bottom: 32px; flex-wrap: wrap; }}
  .summary-card {{ background: white; border-radius: 12px; padding: 20px 24px;
                   flex: 1; min-width: 160px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }}
  .summary-card label {{ font-size: 12px; color: #6e6e73; display: block; margin-bottom: 4px; }}
  .summary-card value {{ font-size: 26px; font-weight: 700; }}
  .section-title {{ font-size: 20px; font-weight: 600; margin: 32px 0 16px; }}
  .personas {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 20px; }}
  .persona-card {{ background: white; border-radius: 12px; padding: 24px;
                   box-shadow: 0 1px 4px rgba(0,0,0,0.08); }}
  .persona-header {{ display: flex; align-items: center; gap: 12px; margin-bottom: 12px; }}
  .emoji {{ font-size: 36px; }}
  .persona-header h2 {{ font-size: 20px; font-weight: 700; }}
  .badge {{ display: inline-block; color: white; font-size: 12px; font-weight: 600;
            padding: 3px 10px; border-radius: 20px; margin-top: 4px; }}
  .persona-desc {{ color: #444; line-height: 1.6; margin-bottom: 12px; }}
  .traits {{ display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 16px; }}
  .trait {{ background: #f5f5f7; border-radius: 20px; padding: 4px 12px; font-size: 12px; color: #444; }}
  .stats-row {{ display: flex; gap: 12px; margin-bottom: 20px; }}
  .stat {{ flex: 1; background: #f5f5f7; border-radius: 8px; padding: 10px 14px; }}
  .stat label {{ font-size: 11px; color: #6e6e73; display: block; margin-bottom: 2px; }}
  .stat value {{ font-size: 15px; font-weight: 600; }}
  h3 {{ font-size: 14px; font-weight: 600; color: #6e6e73; margin-bottom: 10px;
        text-transform: uppercase; letter-spacing: 0.5px; }}
  .crm-actions {{ display: flex; flex-direction: column; gap: 8px; }}
  .crm-item {{ background: #f9f9f9; border-radius: 8px; padding: 10px 14px; }}
  .crm-item strong {{ font-size: 13px; display: block; margin-bottom: 2px; }}
  .crm-item p {{ font-size: 12px; color: #6e6e73; }}
  table {{ width: 100%; border-collapse: collapse; background: white;
           border-radius: 12px; overflow: hidden;
           box-shadow: 0 1px 4px rgba(0,0,0,0.08); }}
  th {{ background: #f5f5f7; padding: 12px 16px; text-align: left;
        font-size: 12px; color: #6e6e73; text-transform: uppercase; }}
  td {{ padding: 12px 16px; border-top: 1px solid #f0f0f0; font-size: 14px; }}
  .updated {{ font-size: 12px; color: #aaa; margin-top: 32px; text-align: right; }}
</style>
</head>
<body>

<h1>Makestar 유저 세그멘테이션</h1>
<p class="subtitle">RFM × Dimension 분석 — v1</p>

<div class="summary-bar">
  <div class="summary-card">
    <label>전체 분석 유저</label>
    <value>{total_users:,}</value>
  </div>
  {"".join(
    f'<div class="summary-card"><label>{PERSONAS[r["dimension_label"]]["emoji"]} {PERSONAS[r["dimension_label"]]["name"]}</label>'
    f'<value>{r["user_cnt"]:,}명</value></div>'
    for r in summary if r["dimension_label"] in PERSONAS
  )}
</div>

<div class="section-title">페르소나 × CRM 액션</div>
<div class="personas">
  {persona_cards}
</div>

<div class="section-title">아티스트별 유저 분포 (상위 10)</div>
<table>
  <thead>
    <tr><th>아티스트</th><th>주요 세그먼트</th><th>유저 수</th><th>평균 GMV</th></tr>
  </thead>
  <tbody>{top_artist_rows}</tbody>
</table>

<p class="updated">생성일: {__import__('datetime').datetime.now().strftime('%Y-%m-%d %H:%M')}</p>
</body>
</html>"""


def main():
    client = bigquery.Client.from_service_account_json(KEY_PATH, project=PROJECT_ID)
    summary, rfm_dist, top_artists, total_users = fetch_data(client)
    html = generate_html(summary, rfm_dist, top_artists, total_users)
    OUTPUT_PATH.parent.mkdir(exist_ok=True)
    OUTPUT_PATH.write_text(html, encoding="utf-8")
    print(f"리포트 저장: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
