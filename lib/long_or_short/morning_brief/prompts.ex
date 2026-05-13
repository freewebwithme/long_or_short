defmodule LongOrShort.MorningBrief.Prompts do
  @moduledoc """
  Bucket-specific prompts for the Morning Brief generator (LON-151).

  Each bucket gets a system prompt that frames the narrator as a
  market-analyst (Korean, sober, fact-driven) and lists the signals
  relevant to that part of the trading day. The user prompt is a thin
  trigger announcing the current ET time and the target bucket.

  No trader-persona injection — the brief is shared (LON-150 design).
  Each reader applies their own strategy lens to a single canonical
  market view.
  """

  @type bucket :: :overnight | :premarket | :after_open

  @doc """
  Build the message list for a given bucket and current ET time.

  Returns `[system_message, user_message]` shaped for
  `LongOrShort.AI.Providers.Claude.call_with_search/2`. The system
  block stays stable across cron runs (good for prompt-cache hits
  within the 5-minute TTL); the user block carries the wall-clock
  trigger.
  """
  @spec build(bucket(), DateTime.t()) :: [map()]
  def build(bucket, %DateTime{} = et_now)
      when bucket in [:overnight, :premarket, :after_open] do
    [
      %{role: "system", content: system_prompt(bucket)},
      %{role: "user", content: user_prompt(bucket, et_now)}
    ]
  end

  # ── System prompt (per-bucket) ────────────────────────────────────

  defp system_prompt(bucket) do
    base_persona() <> "\n\n" <> writing_rules() <> "\n\n" <> bucket_focus(bucket)
  end

  defp base_persona do
    """
    당신은 경험 많은 미국 주식시장 시황 분석가입니다. 한국어로 시황을 분석하고
    작성합니다. 독자는 활발히 거래하는 트레이더로, 시장 흐름과 거시 환경을
    빠르게 파악하고 싶어합니다.
    """
  end

  defp writing_rules do
    """
    작성 규칙:
    - 간결하게 작성 (3–6 문장 또는 짧은 단락 1–2개).
    - 구체적 수치 명시 (CPI %, 선물 %, 섹터 변동 %, 거래량 등). 추상적 표현 피할 것.
    - 출처는 [1], [2] 형식 인라인 마커로 표시.
    - 검색은 최대 5회까지만. 그 이후엔 추가 검색 대신 합성에 집중.
    - 확인 안 된 정보는 "정보 부족" 으로 명시. 추측 또는 일반론으로 채우지 말 것.
    - 개인 매매 추천 / 종목 매수 권유 금지. 시황 사실과 해석만 다룸.
    - "오늘 시장이 좋을 것이다" 같은 방향성 단언 자제. 데이터와 그 함의를 제시.
    """
  end

  defp bucket_focus(:overnight) do
    """
    이 브리프의 초점 (overnight — 전일 미국 마감 후 ~ 오늘 04:00 ET):
    - 전일 미국 마감 후 발생한 주요 catalyst (어닝, 가이던스, M&A 등)
    - 일본 / 홍콩 / 한국 등 아시아 시장 마감 흐름
    - 유럽 시장 오픈 직후 분위기
    - 선물 현황 (S&P 500 / Nasdaq 100 / Dow / Russell 2000)
    - 야간 발표된 주요 기업 뉴스
    """
  end

  defp bucket_focus(:premarket) do
    """
    이 브리프의 초점 (premarket — 04:00 ~ 09:30 ET):
    - 오늘 08:30 ET 발표된 매크로 데이터 (CPI / PPI / Jobless Claims / PCE / NFP 등)
    - 매크로 시장 반응: 선물 / 채권 yield / 달러 인덱스 변동
    - 프리마켓 주요 mover (gainer / loser, % 변동, 거래량)
    - 개장 전 발표된 주요 기업 어닝 / 가이던스
    """
  end

  defp bucket_focus(:after_open) do
    """
    이 브리프의 초점 (after_open — 09:30 ~ 현재):
    - 오늘 10:00 ET 발표된 매크로 데이터 (ISM / JOLTS / 미시간 소비자심리 등)
    - 개장 30분 반응: 주요 지수 / 섹터 ETF 변동
    - 활발한 movers (거래량 급증, unusual options 등)
    - 진행 중인 catalyst 의 후속 흐름
    """
  end

  # ── User prompt ───────────────────────────────────────────────────

  defp user_prompt(bucket, %DateTime{} = et_now) do
    time = Calendar.strftime(et_now, "%Y-%m-%d %H:%M ET")
    "현재 #{time} 기준 #{bucket_label(bucket)} 브리프를 작성해주세요."
  end

  defp bucket_label(:overnight), do: "overnight (전일 마감 후 ~ 04:00 ET)"
  defp bucket_label(:premarket), do: "premarket (04:00 ~ 09:30 ET)"
  defp bucket_label(:after_open), do: "after-open (09:30 ET 이후)"
end
