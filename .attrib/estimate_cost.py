#!/usr/bin/env python3
"""Estimate spend per model from published API rates.

Why estimate at all: the harnesses only recorded cost for some providers. Crush
and OpenCode track it; Claude Code stores tokens but no cost, so the models that
did the most work were unpriced and the "total" was a floor, not a total.

Rates are $/million tokens, applied as:
    fresh_in * in_rate + cache_in * cache_read_rate + out * out_rate

Cache reads are billed at ~10% of the input rate on Anthropic and on most
OpenAI-compatible providers that implement caching. That distinction matters
enormously here: 13.9B of the 14.2B input tokens are cache reads, so pricing
them at the full input rate would overstate spend by roughly an order of
magnitude.

Anthropic rates are current published list prices. Third-party rates are the
providers' published list prices; several models were used through subscription
plans or free tiers where the marginal cost was zero, so their estimate is an
upper bound on what list-price usage would have cost, not a bill.
"""
import json
from collections import Counter

OUT = '/Users/rtomasi/cousas/duktape-c3/.attrib'

# $/1M tokens: (input, output). Cache reads are billed at CACHE_FACTOR * input.
CACHE_FACTOR = 0.10

RATES = {
    # Anthropic — published list prices
    'claude-fable-5':      (10.00, 50.00),
    'claude-opus-5':        (5.00, 25.00),
    'claude-opus-4.8':      (5.00, 25.00),
    'claude-opus-4.7':      (5.00, 25.00),
    'claude-opus-4.6':      (5.00, 25.00),
    'claude-sonnet-5':      (3.00, 15.00),
    'claude-sonnet-4.6':    (3.00, 15.00),
    'claude-sonnet-4':      (3.00, 15.00),
    'claude-haiku-4.5':     (1.00,  5.00),

    # Third-party published list prices (approximate; several were used via
    # subscription plans or free tiers where marginal cost was 0).
    'minimax-m3':           (0.30,  1.20),
    'minimax-m2.7':         (0.30,  1.20),
    'mimo-v2.5':            (0.30,  1.20),
    'mimo-v2.5-pro':        (0.60,  2.40),
    'mimo-v2-pro':          (0.60,  2.40),
    'mimo-v2.5-pro-ultraspeed': (0.60, 2.40),
    'deepseek-v4-pro':      (0.55,  2.19),
    'deepseek-v4-flash':    (0.27,  1.10),
    'kimi-k2.7-code':       (0.60,  2.50),
    'kimi-k3':              (0.60,  2.50),
    'k3-256k':              (0.60,  2.50),
    'qwen3.6-35b-a3b':      (0.00,  0.00),   # local (lmstudio)
    'qwen3.6-27b':          (0.00,  0.00),   # local
    'qwopus3.6-27b-v2-mtp': (0.00,  0.00),   # local
    'qwopus3.6-27b-v1-preview': (0.00, 0.00),
    'gemma-4-12b-qat':      (0.00,  0.00),   # local
    'qwen3.7-max':          (1.60,  6.40),
    'glm-5.2':              (0.60,  2.20),
    'gpt-5.5-free':         (0.00,  0.00),
    'mistral-medium-3-5':   (0.40,  2.00),
    'codestral-2506':       (0.30,  0.90),
    'gemini-3.5-flash':     (0.30,  2.50),
    'gemini-3.1-flash-lite-preview': (0.10, 0.40),
}
FREE_SUFFIXES = ('-free',)          # free tiers: marginal cost 0
LOCAL = {'qwen3.6-35b-a3b', 'qwen3.6-27b', 'qwopus3.6-27b-v2-mtp',
         'qwopus3.6-27b-v1-preview', 'gemma-4-12b-qat'}

tok = json.load(open(f'{OUT}/token_totals.json'))

rows, unpriced = [], []
for r in tok['by_model']:
    m = r['model']
    base = m
    is_free = any(m.endswith(s) for s in FREE_SUFFIXES)
    if is_free:
        base = m.rsplit('-free', 1)[0]

    rate = RATES.get(m) or RATES.get(base)
    if rate is None:
        unpriced.append(m)
        est = None
        basis = 'no published rate'
    elif is_free or m in LOCAL:
        est = 0.0
        basis = 'local model' if m in LOCAL else 'free tier'
    else:
        i, o = rate
        est = (r['tokens_fresh_in'] / 1e6) * i \
            + (r['tokens_cache_in'] / 1e6) * i * CACHE_FACTOR \
            + (r['tokens_out'] / 1e6) * o
        basis = 'list price'

    rows.append({
        'model': m,
        'cost_recorded': r['cost_usd'],
        'cost_estimated': round(est, 2) if est is not None else None,
        'cost_basis': basis,
        'rate_in': rate[0] if rate else None,
        'rate_out': rate[1] if rate else None,
        'tokens_out': r['tokens_out'],
        'tokens_fresh_in': r['tokens_fresh_in'],
        'tokens_cache_in': r['tokens_cache_in'],
        # what we'd show: prefer the harness's own number where it exists
        'cost_best': r['cost_usd'] if r['cost_usd'] else
                     (round(est, 2) if est is not None else None),
    })

rows.sort(key=lambda r: -(r['cost_best'] or 0))

tot_est = sum(r['cost_estimated'] or 0 for r in rows)
tot_rec = sum(r['cost_recorded'] or 0 for r in rows)
tot_best = sum(r['cost_best'] or 0 for r in rows)

doc = {
    'note': ('Estimated from published $/M rates: fresh_in*in + cache_in*in*0.10 + out*out. '
             'Cache reads bill at ~10% of input. cost_best prefers the harness-recorded '
             'figure where one exists and falls back to the estimate. Local models and '
             'free tiers are 0 by definition; several paid models ran under subscription '
             'plans, so estimates are an upper bound on list-price usage, not a bill.'),
    'cache_factor': CACHE_FACTOR,
    'totals': {
        'recorded': round(tot_rec, 2),
        'estimated': round(tot_est, 2),
        'best': round(tot_best, 2),
    },
    'unpriced_models': unpriced,
    'by_model': rows,
}
# What actually left the bank. Credits are one-off top-ups; the Claude plan was
# $20/month Pro for the first two months, then $90 Max in July.
credits = [
    {'provider': 'opencode-go', 'usd': 5}, {'provider': 'xiaomi (mimo)', 'usd': 16},
    {'provider': 'minimax', 'usd': 20}, {'provider': 'openrouter', 'usd': 10},
    {'provider': 'opencode-zen', 'usd': 10}, {'provider': 'aihubmix', 'usd': 5},
]
subs = [
    {'plan': 'Claude Pro', 'usd_per_month': 20, 'months': 2, 'covers': 'May, Jun', 'usd': 40},
    {'plan': 'Claude Max', 'usd_per_month': 90, 'months': 1, 'covers': 'Jul', 'usd': 90},
]
credit_total = sum(i['usd'] for i in credits)
sub_total = sum(i['usd'] for i in subs)
actual = credit_total + sub_total
doc['actual_spend'] = {
    'note': ('What the project actually cost. Credits are one-off top-ups. The Claude plan was '
             '$20/month Pro for the first two months and $90 Max in July, when the bulk of the '
             'Claude work happened. Figures supplied by the project owner.'),
    'credits': credits, 'credits_total_usd': credit_total,
    'subscriptions': subs, 'subscriptions_total_usd': sub_total,
    'total_usd': actual,
}
doc['totals']['actual'] = actual
doc['totals']['inference_value'] = doc['totals']['best']
doc['totals']['multiple'] = round(doc['totals']['best'] / actual, 1)

json.dump(doc, open(f'{OUT}/cost_estimates.json', 'w'), indent=1)

print(f"recorded ${tot_rec:,.2f} | estimated ${tot_est:,.2f} | best-available ${tot_best:,.2f}\n")
print(f"{'model':28} {'recorded':>10} {'estimated':>11} {'best':>10}  basis")
for r in rows[:20]:
    rec = f"${r['cost_recorded']:.0f}" if r['cost_recorded'] else '—'
    est = f"${r['cost_estimated']:.0f}" if r['cost_estimated'] is not None else '—'
    bst = f"${r['cost_best']:.0f}" if r['cost_best'] else '—'
    print(f"{r['model']:28} {rec:>10} {est:>11} {bst:>10}  {r['cost_basis']}")
if unpriced:
    print('\nno published rate for:', unpriced)
