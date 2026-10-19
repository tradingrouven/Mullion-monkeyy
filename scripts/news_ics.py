"""Builds docs/gold-news.ics from docs/news.json: the USD high and medium impact
events that move XAUUSD, each with a reminder, for the iPhone calendar."""
import hashlib, json, sys
from datetime import datetime, timezone

src = sys.argv[1] if len(sys.argv) > 1 else "docs/news.json"
dst = sys.argv[2] if len(sys.argv) > 2 else "docs/gold-news.ics"
news = json.load(open(src))

def esc(s):
    return str(s).replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")

def utc(iso):
    return datetime.fromisoformat(iso).astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

stamp = utc(news.get("fetchedAt", "").replace("Z", "+00:00")) if news.get("fetchedAt") else datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
out = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Bullion Monkey//Gold-News//DE", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
       "X-WR-CALNAME:Gold-News (USD)", "X-WR-CALDESC:Wichtige USD-News für XAUUSD", "REFRESH-INTERVAL;VALUE=DURATION:PT2H",
       "X-PUBLISHED-TTL:PT2H"]
for e in news.get("events", []):
    if e.get("country") != "USD" or e.get("impact") not in ("High", "Medium"):
        continue
    high = e["impact"] == "High"
    info = " · ".join(x for x in [f"Prognose {e['forecast']}" if e.get("forecast") else "", f"Vorher {e['previous']}" if e.get("previous") else ""] if x)
    out += ["BEGIN:VEVENT",
            "UID:" + hashlib.sha1((e["title"] + e["date"]).encode()).hexdigest() + "@bullion-monkey",
            "DTSTAMP:" + stamp, "DTSTART:" + utc(e["date"]), "DURATION:PT15M",
            "SUMMARY:" + esc(("🔴 " if high else "🟠 ") + "USD " + e["title"]),
            "DESCRIPTION:" + esc(("Hoher" if high else "Mittlerer") + " Impact für Gold." + (" " + info if info else "")),
            "TRANSP:TRANSPARENT"]
    for mins in ([30, 5] if high else [10]):
        out += ["BEGIN:VALARM", "ACTION:DISPLAY", f"TRIGGER:-PT{mins}M",
                "DESCRIPTION:" + esc(f"In {mins} Min.: USD {e['title']}"), "END:VALARM"]
    out.append("END:VEVENT")
out.append("END:VCALENDAR")
open(dst, "w", newline="").write("\r\n".join(out) + "\r\n")
