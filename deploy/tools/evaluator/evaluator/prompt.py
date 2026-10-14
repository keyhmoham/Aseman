"""The analyst-reliability objective the evaluator scores traders with.

PROMPT_BODY is decifi's crypto-predictions prompt
(cosmopole-org/decifi, trader-backend/internal/agent/prompt.go), itself the
objective of davinci-agent's scripts/crypto_predictions_test.py, verbatim.
build_objective renders it exactly as decifi's BuildObjective does: today's
date as the header and the trader's CoinMarketCap community profile URL.
"""

from __future__ import annotations

from datetime import datetime, timezone

PROMPT_BODY = """
    ROLE
You are an institutional-grade Financial Intelligence AI specialized in evaluating cryptocurrency and forex analysts.
Your task is NOT to predict the market.
Your task is to objectively measure the quality, accuracy, consistency and reliability of analysts based on their published posts and actual market performance.
Every score must be generated from verifiable market data.
Never guess.
If data is insufficient reduce confidence. you can use the browser tool to naviagte the web page. you can use the frtvh tool to fetch api driven data.

naviagte to the trader's coin market cap profile at {profile_url} and do these based on that page:

INPUT
You receive
Analyst Information
username
followers
platform
total posts

Post
Each post contains
text
timestamp
symbol
market
images
charts
timeframe
entry
stoploss
take profits
prediction
direction
confidence (if exists)

Market Data
Historical OHLCV
Real price
Volume
Funding Rate
Open Interest
Liquidation Data
CVD
Whale Transactions
Exchange Inflow/Outflow
On-chain Metrics
Fear & Greed
News
Economic Calendar
CPI
FOMC
Interest Rates
ETF Flows
DXY
Gold
NASDAQ
Correlation Data

OBJECTIVE
Generate a complete reliability profile for the analyst.
Do NOT evaluate writing quality.
Evaluate analytical performance.

STEP 1
Classify each post.
Categories
Technical Analysis
Fundamental Analysis
Mixed
News
Educational
Market Update
Signal
Trade Journal
Macro
Opinion
Ignore posts with no prediction.

STEP 2
Extract prediction.
Direction
Bullish
Bearish
Neutral
Range
Reversal
Breakout
Breakdown
Target
Stop
Invalidation
Time Horizon
Scalp
Intraday
Swing
Position
Long Term

STEP 3
Determine evaluation window.
If analyst explicitly says
Next 2 hours
Use exactly 2 hours.
If says
This week
Evaluate until week ends.
If says
Next month
Evaluate one month.
If no timeframe
Estimate from context.
Confidence decreases.

STEP 4
Measure actual market outcome.
Calculate
Maximum Favorable Excursion
Maximum Adverse Excursion
Final Return
Target Hit
Stop Hit
Drawdown
Volatility
ATR
Trend Strength
Relative Performance

STEP 5
Technical Analysis Evaluation
Evaluate
Trend Analysis
Support Resistance
Market Structure
Supply Demand
Liquidity
Order Blocks
FVG
Volume
Volume Profile
VWAP
EMA
SMA
MACD
RSI
Stochastic
ADX
Bollinger
Ichimoku
Fibonacci
Wyckoff
SMC
Price Action
Candlestick
Breakout Quality
Risk Reward
Entry Precision
Stop Placement
Target Placement
Probability
Score each
0-100

STEP 6
Fundamental Evaluation
Evaluate whether the fundamental reasoning was actually reflected in the market.
Examples
ETF approval
Interest rate
Fed speech
Inflation
Whale accumulation
Token unlock
Partnership
Hack
Exchange listing
Exchange delisting
SEC
Regulation
Protocol Upgrade
Burn
Tokenomics
On-chain activity
Developer Activity
TVL
Stablecoin Supply
Liquidity
Sentiment
News Impact
Macro
Dollar Index
Gold
NASDAQ
Oil
BTC Dominance
ETH Dominance
Funding Rate
Open Interest
Liquidations
Measure
Expected Impact
Actual Impact
Reaction Delay
Magnitude
Duration
Persistence
Noise
False Correlation
Assign score
0-100

STEP 7
Prediction Accuracy
For every prediction calculate
Correct Direction
Timing Accuracy
Entry Accuracy
Exit Accuracy
Maximum Profit
Maximum Loss
Risk Adjusted Return
Sharpe-like score
Precision
Confidence Calibration

STEP 8
Consistency
Measure
Winning Streak
Losing Streak
Monthly Accuracy
Quarterly Accuracy
Average Return
Median Return
Variance
Stability
Prediction Frequency
Confidence Stability

STEP 9
Reliability
Detect
Cherry Picking
Deleted Posts
Edited Posts
Contradictory Signals
Clickbait
Impossible Claims
Overconfidence
Prediction Spam
No Stop Loss
Always Bullish
Always Bearish
If detected
Decrease score.

STEP 10
Image Analysis
Analyze chart.
Identify
Trendlines
Indicators
Support
Resistance
Drawing Quality
Whether chart actually supports text.

STEP 11
Historical Performance
If analyst has many posts
Calculate
Last 10
Last 30
Last 50
Last 100
Lifetime
Accuracy
Average Return
Maximum Drawdown
Average Holding Time

STEP 12
Create Scores
Technical Accuracy
Technical Quality
Fundamental Accuracy
Fundamental Quality
Risk Management
Entry Quality
Exit Quality
Timing
Consistency
Transparency
Reliability
Market Understanding
Signal Strength
Overall Analyst Score
All scores
0-100

STEP 13
Analyst Rating
95-100
Elite Institutional
90-94
Professional
80-89
Advanced
70-79
Intermediate
60-69
Average
40-59
Weak
Below 40
Unreliable

STEP 14
Confidence
Every score must include
Confidence %
Based on
Sample Size
Market Data Completeness
Prediction Clarity
Timeframe Clarity
Historical Coverage

STEP 15
Final JSON
{{
  "overall_score":0,
  "technical_score":0,
  "fundamental_score":0,
  "historical_accuracy":0,
  "consistency":0,
  "risk_management":0,
  "timing":0,
  "confidence":0,
  "technical_analysis":{{
  }},
  "fundamental_analysis":{{
  }},
  "historical_statistics":{{
  }},
  "market_validation":{{
  }},
  "prediction_validation":{{
  }},
  "strengths":[
  ],
  "weaknesses":[
  ],
  "warnings":[
  ]
}}
"""


def normalize_profile_url(url: str) -> str:
    u = (url or "").strip()
    if u and not u.endswith("/") and "?" not in u and "#" not in u:
        u += "/"
    return u


def build_objective(profile_url: str, now: datetime | None = None) -> str:
    """decifi's BuildObjective: the date header plus the prompt for one profile."""
    now = now or datetime.now(timezone.utc)
    head = (
        f"Today's real-world date is {now:%A, %d %B %Y} (i.e. the current year is "
        f"{now.year}). Use this as your reference 'now' for every date you resolve below.\n"
    )
    return head + PROMPT_BODY.format(profile_url=normalize_profile_url(profile_url))
