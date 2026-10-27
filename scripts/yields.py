"""US Treasury yields (2 and 10 years) from the official daily par yield curve, saved as docs/macro.json for the app."""
import csv, datetime, io, json, urllib.request

year = datetime.date.today().year
rows = []
for y in (year, year - 1):
    url = ("https://home.treasury.gov/resource-center/data-chart-center/interest-rates/daily-treasury-rates.csv/"
           f"{y}/all?type=daily_treasury_yield_curve&field_tdr_date_value={y}&page&_format=csv")
    req = urllib.request.Request(url, headers={"User-Agent": "BullionMonkey (github.com/tradingrouven/Mullion-monkeyy)"})
    text = urllib.request.urlopen(req, timeout=30).read().decode("utf-8-sig")
    rows += [r for r in csv.DictReader(io.StringIO(text)) if r.get("2 Yr") and r.get("10 Yr")]
    if len(rows) >= 2:
        break

rows.sort(key=lambda r: datetime.datetime.strptime(r["Date"], "%m/%d/%Y"), reverse=True)
now, prev = rows[0], rows[1]
day = lambda r: datetime.datetime.strptime(r["Date"], "%m/%d/%Y").strftime("%Y-%m-%d")
out = {
    "source": "U.S. Department of the Treasury, daily par yield curve",
    "yields": {"date": day(now), "prevDate": day(prev),
               "y2": float(now["2 Yr"]), "y10": float(now["10 Yr"]),
               "prev2": float(prev["2 Yr"]), "prev10": float(prev["10 Yr"])},
}
json.dump(out, open("docs/macro.json", "w"), indent=1)
print(out)
