# Trio Settings Review — March 31, 2026

## Changes Made Today

| Setting | Previous | New |
|---|---|---|
| Recommended Bolus Percentage | 80% | 100% |
| Adjustment Factor (AF) | 55% | 65% |

## Why These Changes

- **2-month progressive drift upward** from early February through end of March
- Every week showed more time above 180, especially afternoons/evenings
- 80% bolus meant every meal started with a 20% deficit the algorithm had to chase
- AF at 55% was too conservative for Dynamic ISF to correct elevated readings

## If Still Running High Next Week

Consider these in order:

1. **Autosens Max** — 115% → 125% (give algorithm more room to detect increased resistance)
2. **Add evening CR segment** (5pm-midnight) — tighter than current 8.7 g/U, try 7.5-8.0 g/U
3. **Add evening ISF segment** (5pm-midnight) — try 48-50 mg/dL instead of 56
4. **Increase basal rates** — daytime 1.8 U/hr may need to go to 2.0+
5. **Max SMB Basal Minutes** — 40 → 50-60 min
6. **SMB Delivery Ratio** — 40% → 50%

## Current Settings Snapshot (pre-change baseline)

### Therapy
- Target: 115 mg/dL
- Basal: 1.0 U/hr (12am-6am), 1.8 U/hr (6am+)
- CR: 8.7 g/U (12am-6am, 11am+), 9.8 g/U (6am-11am)
- ISF: 56 mg/dL (12am-6am, 11am+), 64 mg/dL (6am-11am)
- DIA: 6.5 hours
- Max IOB: 10 U, Max Bolus: 8 U

### Algorithm
- Dynamic ISF: Logarithmic
- Weighted Average TDD: 55%
- Autosens: 85-115%
- SMB: Always enabled, Max Basal Min 40, Max UAM Min 35, Delivery Ratio 40%
- High Glucose Target for SMB: 110 mg/dL

### Key Observations
- Overnight control was reasonable until late March
- Post-meal spikes worst in afternoon/evening (2pm-10pm)
- Morning CR/ISF (6am-11am) is weaker than rest of day
- Sensitivity Raises Target is enabled (may contribute to running higher)
