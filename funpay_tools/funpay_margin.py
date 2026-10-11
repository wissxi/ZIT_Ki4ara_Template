#!/usr/bin/env python3
"""
funpay_margin.py - считает, сколько продавец реально получит на FunPay и окупается ли перепродажа.

Только чтение: ходит по страницам категорий и в калькулятор комиссии (/lots/calc),
ничего не выставляет и не покупает.

    export FUNPAY_GOLDEN_KEY=...      # cookie golden_key из браузера; в код и в git не класть
    python funpay_margin.py           # все товары из PRODUCTS
    python funpay_margin.py --eur 1.12 --withdraw 0.05 --min-reviews 100

Что считает для каждого товара:
  * коэффициент комиссии категории: цена для покупателя (карта RU, $) / сумма продавцу;
  * топ самых дешёвых конкурентов и сколько получает каждый (net);
  * нашу цену: на 0.01 $ ниже самого дешёвого продавца с >= --min-reviews отзывов;
  * прибыль за штуку после закупки и вывода (--withdraw: СБП 3% + спред P2P на USDT).
"""
import argparse
import html
import os
import re
import sys
import time

import requests

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")

# node - id категории (https://funpay.com/lots/<node>/), filters - значения data-f-* на лотах,
# text - regex по описанию (для категорий без фильтров), buy_eur - закупка с комиссией магазина.
PRODUCTS = [
    {"name": "Roblox 400 Robux (US-карта, Gamivo)", "node": 1264,
     "filters": {"quantity": "400 робуксов", "region": "другие страны"}, "buy_eur": 3.19 + 0.40},
    {"name": "Roblox 800 Robux (global, Gamivo)", "node": 1264,
     "filters": {"quantity": "800 робуксов", "region": "другие страны"}, "buy_eur": 6.82 + 0.40},
    {"name": "Roblox 1000 Robux (US, Gamivo)", "node": 1264,
     "filters": {"quantity": "1000 робуксов", "region": "другие страны"}, "buy_eur": 8.26 + 0.40},
    {"name": "Roblox 2000 Robux (global, Gamivo)", "node": 1264,
     "filters": {"quantity": "2000 робуксов", "region": "другие страны"}, "buy_eur": 16.99 + 0.60},
    {"name": "Discord Nitro Basic 1 мес код (Kinguin)", "node": 923,
     "filters": {"type": "nitro basic", "time": "1 месяц", "method": "код активации"}, "buy_eur": 2.20 + 0.30},
    {"name": "Discord Nitro 3 мес trial (Kinguin)", "node": 923,
     "filters": {"type": "nitro", "time": "3 месяца", "oldnitro": "нет"}, "buy_eur": 0.47 + 0.10},
    {"name": "Minecoins 1720 (Kinguin UK)", "node": 1016, "text": r"\b1720\b", "buy_eur": 5.60 + 0.40},
    {"name": "Minecoins 3500 (Kinguin AT)", "node": 1016, "text": r"\b3500\b", "buy_eur": 10.21 + 0.50},
    {"name": "Spotify 3 мес trial-ссылка (Kinguin CA)", "node": 1521,
     "filters": {"time": "3 месяца"}, "buy_eur": 0.95 + 0.10},
]

OFFER_RE = re.compile(r'<a href="https://funpay.com/lots/offer\?id=(\d+)" class="tc-item[^"]*"([^>]*)>(.*?)</a>', re.S)


def session(key):
    s = requests.Session()
    s.headers.update({"User-Agent": UA, "Accept-Language": "ru"})
    s.cookies.set("golden_key", key, domain="funpay.com")
    return s


def get(s, url, **kw):
    for attempt in range(4):
        try:
            r = (s.post if "data" in kw else s.get)(url, timeout=30, **kw)
            r.raise_for_status()
            return r
        except requests.RequestException:
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)


def parse_lots(page):
    lots = []
    for oid, attrs, body in OFFER_RE.findall(page):
        a = dict(re.findall(r'data-([\w-]+)="([^"]*)"', attrs))
        price = re.search(r'tc-price" data-s="([\d.]+)"', body)
        if not price:
            continue
        desc = re.search(r'tc-desc-text">(.*?)</div>', body, re.S)
        seller = re.search(r'media-user-name">\s*<span[^>]*>([^<]*)', body)
        reviews = re.search(r'rating-mini-count">(\d+)', body)
        lots.append({
            "id": oid, "price": float(price.group(1)), "auto": a.get("auto") == "1",
            "filters": {k[2:]: html.unescape(v) for k, v in a.items() if k.startswith("f-")},
            "desc": html.unescape(re.sub(r"<[^>]+>", "", desc.group(1))).strip() if desc else "",
            "seller": html.unescape(seller.group(1)) if seller else "",
            "reviews": int(reviews.group(1)) if reviews else 0,
        })
    return lots


def commission_factor(s, node):
    """Во сколько раз цена для покупателя (карта RU, $) больше суммы продавцу."""
    r = get(s, "https://funpay.com/lots/calc", data={"nodeId": node, "price": 100},
            headers={"X-Requested-With": "XMLHttpRequest"})
    for m in r.json()["methods"]:
        if m["unit"] == "$":
            return float(m["price"].replace(" ", "")) / 100
    raise RuntimeError(f"калькулятор не вернул цену в $ для node {node}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--eur", type=float, default=1.12, help="курс EUR->USD для закупки")
    ap.add_argument("--withdraw", type=float, default=0.05, help="доля, теряемая на выводе в USDT")
    ap.add_argument("--min-reviews", type=int, default=100, help="кого считаем серьёзным конкурентом")
    ap.add_argument("--top", type=int, default=5)
    args = ap.parse_args()

    key = os.environ.get("FUNPAY_GOLDEN_KEY")
    if not key:
        sys.exit("Задай FUNPAY_GOLDEN_KEY (cookie golden_key)")
    s = session(key)

    pages, factors = {}, {}
    for p in PRODUCTS:
        node = p["node"]
        if node not in pages:
            pages[node] = parse_lots(get(s, f"https://funpay.com/lots/{node}/").text)
            factors[node] = commission_factor(s, node)
            time.sleep(1)
        allowed = "Доступ запрещен" not in get(s, f"https://funpay.com/lots/offerEdit?node={node}").text
        lots = [l for l in pages[node]
                if all(l["filters"].get(k) == v for k, v in p.get("filters", {}).items())
                and (not p.get("text") or re.search(p["text"], l["desc"]))]
        lots.sort(key=lambda l: l["price"])
        f = factors[node]
        buy = p["buy_eur"] * args.eur

        print(f"\n=== {p['name']}  | категория {node}, комиссия x{f:.3f}, "
              f"лотов {len(lots)}, выставлять {'можно' if allowed else 'НЕЛЬЗЯ (доступ закрыт)'}")
        for l in lots[:args.top]:
            print(f"   {l['price']:8.2f}$  продавцу {l['price'] / f:7.2f}$  {l['reviews']:6} отз "
                  f"{'A' if l['auto'] else ' '} {l['seller'][:16]:<16} {l['desc'][:60]}")
        rivals = [l for l in lots if l["reviews"] >= args.min_reviews]
        if not rivals:
            print("   серьёзных конкурентов нет")
            continue
        our_list = rivals[0]["price"] - 0.01
        our_net = our_list / f
        profit = our_net * (1 - args.withdraw) - buy
        print(f"   закупка {buy:.2f}$ | наша цена {our_list:.2f}$ (нам {our_net:.2f}$) | "
              f"прибыль после вывода {profit:+.2f}$ ({profit / buy * 100:+.0f}%)")


if __name__ == "__main__":
    main()
