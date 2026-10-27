//+------------------------------------------------------------------+
//| BullionMonkeySync.mq5                                            |
//| Sends closed trades, open positions and the balance to a secret  |
//| GitHub Gist, which the Bullion Monkey app reads.                 |
//| Setup: Tools > Options > Expert Advisors > "Allow WebRequest for |
//| listed URL" and add https://api.github.com and                   |
//| https://www.financialjuice.com (news headlines)                  |
//| https://trumpstruth.org (Trump's Truth Social posts)              |
//| Push messages: Tools > Options > Notifications, enter the        |
//| MetaQuotes ID from the MT5 app on the phone.                     |
//+------------------------------------------------------------------+
#property copyright "Bullion Monkey"
#property version   "1.51"

input string GitHubToken = "";   // GitHub token (classic, only "gist" scope)
input string GistId      = "";   // leave empty: the EA creates a secret gist
input int    DaysBack    = 365;  // how many days of history to send
input int    SyncSeconds = 15;   // check interval in seconds
input string PushLink    = "";   // push link from the app (Tools → Push-Nachrichten); also add its address under WebRequest
input bool   PushTrades  = true; // push message when a trade opens or closes
input double DailyLossPct = 3.0; // push when today's loss reaches this % (0 = off)
input int    MaxTradesDay = 3;   // push when more trades than this are opened today (0 = off)
input int    JournalHour  = 21;  // evening reminder to write the journal, local hour (-1 = off)
input int    NewsPushMinutes = 15; // push this many minutes before high-impact USD news (0 = off)
input int    NoSlMinutes  = 2;   // push when a position has no stop-loss after this many minutes (0 = off)
input int    FeedMinutes  = 2;   // read FinancialJuice headlines every n minutes (0 = off)
input bool   PushHeadlines = true; // push gold-relevant headlines
input string HeadlineWords = "gold,xau,fed ,fomc,powell,cpi,pce,nfp,non-farm,payrolls,inflation,rate cut,rate hike,treasury,yields,dollar,dxy,tariff,geopolit"; // comma list for the push filter
input int    TruthMinutes = 2;   // read Trump's Truth Social posts (trumpstruth.org) every n minutes (0 = off)
input bool   PushTruth    = true; // push Trump posts that match the words below
input double BreakEvenR   = 1.0;  // push when a position is this many R in profit and the SL is not at entry yet (0 = off)
input bool   PriceAlarms  = true; // price alarms set in the app (needs PushLink)
input bool   ChartShots   = true; // chart picture at entry and exit, shown in the app's journal
input string TruthWords   = "gold,tariff,china,fed,powell,rate,interest,dollar,inflation,trade,deal,iran,russia,war,oil,sanction,economy,stock,market,bitcoin"; // comma list for the Trump push filter

#define GIST_FILE "bullion-monkey.json"
#define ID_FILE   "bullion_monkey_gist.txt"
#define API       "https://api.github.com/gists"
#define FEED      "https://www.financialjuice.com/feed.ashx?xy=rss"
#define TRUTH     "https://trumpstruth.org/feed"
#define SHOT_DIR  "bm-shots"
#define SHOT_ID   "bullion_monkey_shots_gist.txt"
#define SHOT_DONE "bullion_monkey_shots.txt"

string g_gist = "";
string g_last = "";     // last uploaded trade/balance payload, to skip unchanged uploads
bool   g_dirty = true;
datetime g_upAt = 0;    // last upload, for the 5-minute heartbeat
datetime g_lossDay = 0, g_tradesDay = 0, g_journalDay = 0;   // day of the last limit push, so each fires once a day
ulong  g_noSl[];                          // positions already warned about a missing stop-loss
string g_news = "";                       // JSON array body of the latest headlines
datetime g_newsAt = 0;
string g_newsSeen = "";                   // newest headline already handled, for the push
bool   g_feedWarned = false;
string g_truth = "";                      // JSON array body of the latest Trump posts
datetime g_truthAt = 0;
string g_truthSeen = "";                  // newest Trump post already handled, for the push
bool   g_truthWarned = false;
ulong  g_be[];                            // positions already reminded about break-even
string g_alarms = "";                     // alarms from the app: JSON text from the push server
datetime g_alarmsAt = 0;
string g_alId[]; double g_alP[]; double g_alLast[];   // parsed alarms and the price seen last time, to detect a cross
string g_alSym[]; string g_alNote[];
string g_macro = "";                      // DXY and gold price, uploaded at most once a minute
string g_shotGist = "";                   // second secret gist for the chart pictures, so the trade gist stays small
string g_shots = "";                      // uploaded pictures, "|<position>-in|<position>-out|..."

//+------------------------------------------------------------------+
// only on a fresh start or new settings, not when the chart just changes timeframe
bool IsNewStart()
  {
   int r = UninitializeReason();
   return r != REASON_CHARTCHANGE;
  }

int OnInit()
  {
   if(StringLen(GitHubToken) < 10)
     {
      Alert("Bullion Monkey: GitHub-Token fehlt (Eingabe GitHubToken).");
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_gist = GistId;
   if(g_gist == "")
      g_gist = ReadSavedId();
   g_shotGist = ReadText(SHOT_ID);
   g_shots = ReadText(SHOT_DONE);
   BackfillBars();
   EventSetTimer(SyncSeconds < 10 ? 10 : SyncSeconds);
   if(FeedMinutes > 0) FetchNews();
   if(TruthMinutes > 0) FetchTruth();
   Sync();
   if(PushLink != "" && IsNewStart())   // test message, so you see right away that pushes reach the phone
      PushApp("MT5 ist mit der App verbunden ✓ Trades, Limits und Journal-Erinnerung kommen ab jetzt als Push.", false);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer()
  {
   CheckNoSl();
   CheckBreakEven();
   CheckAlarms();
   CheckCalendar();
   CheckJournal();
   if(FeedMinutes > 0 && TimeLocal() - g_newsAt >= FeedMinutes * 60)
      FetchNews();
   if(TruthMinutes > 0 && TimeLocal() - g_truthAt >= TruthMinutes * 60)
      FetchTruth();
   UploadShot();
   Sync();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      PushDeal(trans.deal);
      TakeShot(trans.deal);
      g_dirty = true;
      Sync();
     }
  }

//+------------------------------------------------------------------+
//| Push messages to the MT5 app on the phone                        |
//+------------------------------------------------------------------+
void Push(const string msg, const bool journal = false)
  {
   if(PushLink != "") PushApp(msg, journal);
   if(!TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED)) return;
   if(!SendNotification(StringSubstr(msg, 0, 255)))
      Print("Bullion Monkey: Push fehlgeschlagen ", GetLastError());
  }

// push to the Bullion Monkey app through its server; a tap opens the app (the journal when journal is true)
void PushApp(string msg, const bool journal)
  {
   StringReplace(msg, "Bullion Monkey: ", "");
   string body = "{\"body\":\"" + Esc(msg) + "\"" + (journal ? ",\"journal\":true" : "") + "}";
   char data[], res[]; string rh;
   StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(data, ArraySize(data) - 1);   // no trailing 0
   int code = WebRequest("POST", PushLink, "Content-Type: application/json\r\n", 5000, data, res, rh);
   if(code != 200)
      Print("Bullion Monkey: App-Push fehlgeschlagen (", code, " / ", GetLastError(), "). Ist die Push-Server-Adresse unter WebRequest erlaubt?");
  }

void PushDeal(const ulong deal)
  {
   if(deal == 0 || !HistoryDealSelect(deal)) return;
   long type = HistoryDealGetInteger(deal, DEAL_TYPE);
   if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) return;
   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string cur = AccountInfoString(ACCOUNT_CURRENCY);

   // today's result and trade count, in broker time
   MqlDateTime t; TimeToStruct(TimeTradeServer(), t); t.hour = 0; t.min = 0; t.sec = 0;
   datetime day = StructToTime(t);
   double dayPnl = 0; int dayTrades = 0;
   if(HistorySelect(day, TimeTradeServer() + 60))
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong tk = HistoryDealGetTicket(i);
         long ty = HistoryDealGetInteger(tk, DEAL_TYPE);
         if(ty != DEAL_TYPE_BUY && ty != DEAL_TYPE_SELL) continue;
         dayPnl += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP)
                 + HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
         if(HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN) dayTrades++;
        }
   HistoryDealSelect(deal);

   if(PushTrades)
     {
      if(entry == DEAL_ENTRY_IN)
         Push(StringFormat("Bullion Monkey: %s %.2f %s @ %s eröffnet (Trade %d heute)",
              type == DEAL_TYPE_BUY ? "BUY" : "SELL", HistoryDealGetDouble(deal, DEAL_VOLUME), sym,
              DoubleToString(HistoryDealGetDouble(deal, DEAL_PRICE), dg), dayTrades));
      else
        {
         double p = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP)
                  + HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
         Push(StringFormat("Bullion Monkey: %s geschlossen %s%.2f %s · heute %s%.2f %s. Schreib kurz ins Journal: Setup, Gefühl, Lektion.",
              sym, p >= 0 ? "+" : "", p, cur, dayPnl >= 0 ? "+" : "", dayPnl, cur), true);
        }
     }

   double startBal = AccountInfoDouble(ACCOUNT_BALANCE) - dayPnl;
   if(DailyLossPct > 0 && startBal > 0 && dayPnl <= -startBal * DailyLossPct / 100 && g_lossDay != day)
     {
      g_lossDay = day;
      Push(StringFormat("Bullion Monkey: STOPP. Tagesverlust %.2f %s (%.1f %%) hat dein Limit von %.1f %% erreicht.",
           dayPnl, cur, dayPnl / startBal * 100, DailyLossPct));
     }
   if(MaxTradesDay > 0 && entry == DEAL_ENTRY_IN && dayTrades > MaxTradesDay && g_tradesDay != day)
     {
      g_tradesDay = day;
      Push(StringFormat("Bullion Monkey: Achtung, das ist schon dein %d. Trade heute (Limit %d).", dayTrades, MaxTradesDay));
     }
  }

//+------------------------------------------------------------------+
//| FinancialJuice headlines                                         |
//+------------------------------------------------------------------+
string TagText(const string xml, const string tag)
  {
   int a = StringFind(xml, "<" + tag + ">");
   if(a < 0) return "";
   a += StringLen(tag) + 2;
   int b = StringFind(xml, "</" + tag + ">", a);
   if(b < 0) return "";
   string v = StringSubstr(xml, a, b - a);
   StringReplace(v, "<![CDATA[", ""); StringReplace(v, "]]>", "");
   StringReplace(v, "&lt;", "<"); StringReplace(v, "&gt;", ">"); StringReplace(v, "&quot;", "\"");
   StringReplace(v, "&#39;", "'"); StringReplace(v, "&apos;", "'"); StringReplace(v, "&amp;", "&");
   StringReplace(v, "\t", " ");
   StringTrimLeft(v); StringTrimRight(v);
   return v;
  }

bool IsGoldNews(const string title) { return HasWord(title, HeadlineWords); }

bool HasWord(const string title, const string words)
  {
   string t = " " + title + " "; StringToLower(t);
   string w[]; int n = StringSplit(words, ',', w);
   for(int i = 0; i < n; i++)
     {
      string k = w[i]; StringToLower(k); StringTrimLeft(k);
      if(StringLen(k) > 1 && StringFind(t, k) >= 0) return true;
     }
   return false;
  }

void FetchNews()
  {
   g_newsAt = TimeLocal();
   char data[], result[];
   string resHeaders;
   ResetLastError();
   int code = WebRequest("GET", FEED, "User-Agent: Mozilla/5.0 (BullionMonkeySync)\r\n", 15000, data, result, resHeaders);
   if(code != 200)
     {
      if(!g_feedWarned)
        {
         g_feedWarned = true;
         if(code == -1 && GetLastError() == 4014)
            Print("Bullion Monkey: für Schlagzeilen https://www.financialjuice.com bei WebRequest erlauben.");
         else
            Print("Bullion Monkey: FinancialJuice antwortet ", code);
        }
      return;
     }
   string xml = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string out = "", newest = "";
   string fresh[]; int nf = 0;
   bool reachedSeen = (g_newsSeen == "");   // first run: remember, but don't push old headlines
   int pos = 0;
   for(int i = 0; i < 40; i++)
     {
      int a = StringFind(xml, "<item>", pos);
      if(a < 0) break;
      int b = StringFind(xml, "</item>", a);
      if(b < 0) break;
      pos = b + 7;
      string item = StringSubstr(xml, a, b - a);
      string title = TagText(item, "title");
      if(StringFind(title, "FinancialJuice: ") == 0) title = StringSubstr(title, 16);
      if(title == "") continue;
      if(newest == "") newest = title;
      if(title == g_newsSeen) reachedSeen = true;
      if(!reachedSeen) { ArrayResize(fresh, nf + 1); fresh[nf++] = title; }
      if(out != "") out += ",";
      out += "{\"t\":\"" + Esc(title) + "\",\"d\":\"" + Esc(TagText(item, "pubDate")) + "\"}";
     }
   if(out == "") return;
   if(out != g_news) g_dirty = true;
   g_news = out;
   if(PushHeadlines && g_newsSeen != "")
      for(int k = (int)MathMin(nf, 5) - 1; k >= 0; k--)   // oldest first, at most 5 at once
         if(IsGoldNews(fresh[k])) Push("📰 " + fresh[k]);
   g_newsSeen = newest;
  }

// plain text of a post: HTML tags, "RT: <url>" and "View image" links removed, quoted post cut off
string PostText(string html)
  {
   int q = StringFind(html, "<blockquote"); if(q >= 0) html = StringSubstr(html, 0, q);
   q = StringFind(html, "Quoted"); if(q >= 0) html = StringSubstr(html, 0, q);
   string o = ""; bool tag = false;
   int len = StringLen(html);
   for(int i = 0; i < len; i++)
     {
      ushort c = StringGetCharacter(html, i);
      if(c == '<') { tag = true; continue; }
      if(c == '>') { tag = false; o += " "; continue; }
      if(!tag) o += ShortToString(c);
     }
   int r;
   while((r = StringFind(o, "RT: ")) >= 0)
     {
      int e = StringFind(o, " ", r + 4);
      o = StringSubstr(o, 0, r) + (e < 0 ? "" : StringSubstr(o, e));
     }
   StringReplace(o, "View image", ""); StringReplace(o, "View video", "");
   StringReplace(o, "&nbsp;", " "); StringReplace(o, "&amp;", "&"); StringReplace(o, "&quot;", "\""); StringReplace(o, "&#39;", "'");
   StringReplace(o, "\n", " "); StringReplace(o, "\r", " ");
   while(StringFind(o, "  ") >= 0) StringReplace(o, "  ", " ");
   StringTrimLeft(o); StringTrimRight(o);
   if(StringLen(o) > 400) o = StringSubstr(o, 0, 397) + "...";
   return o;
  }

void FetchTruth()
  {
   g_truthAt = TimeLocal();
   char data[], result[];
   string resHeaders;
   ResetLastError();
   int code = WebRequest("GET", TRUTH, "User-Agent: Mozilla/5.0 (BullionMonkeySync)\r\n", 15000, data, result, resHeaders);
   if(code != 200)
     {
      if(!g_truthWarned)
        {
         g_truthWarned = true;
         if(code == -1 && GetLastError() == 4014)
            Print("Bullion Monkey: für Trump-Posts https://trumpstruth.org bei WebRequest erlauben.");
         else
            Print("Bullion Monkey: trumpstruth.org antwortet ", code);
        }
      return;
     }
   string xml = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string out = "", newest = "";
   string fresh[]; int nf = 0;
   bool reachedSeen = (g_truthSeen == "");
   int pos = 0;
   for(int i = 0; i < 20; i++)
     {
      int a = StringFind(xml, "<item>", pos);
      if(a < 0) break;
      int b = StringFind(xml, "</item>", a);
      if(b < 0) break;
      pos = b + 7;
      string item = StringSubstr(xml, a, b - a);
      string link = TagText(item, "link");
      string text = TagText(item, "title");
      if(StringFind(text, " post from ") >= 0 || StringLen(text) >= 100)   // placeholder or shortened title
        {
         string body = PostText(TagText(item, "description"));
         if(body != "") text = body;
        }
      if(text == "" || link == "") continue;
      if(newest == "") newest = link;
      if(link == g_truthSeen) reachedSeen = true;
      if(!reachedSeen) { ArrayResize(fresh, nf + 1); fresh[nf++] = text; }
      if(out != "") out += ",";
      out += "{\"t\":\"" + Esc(text) + "\",\"d\":\"" + Esc(TagText(item, "pubDate")) + "\",\"u\":\"" + Esc(link) + "\",\"o\":\"" + Esc(TagText(item, "truth:originalUrl")) + "\"}";
     }
   if(out == "") return;
   if(out != g_truth) g_dirty = true;
   g_truth = out;
   if(PushTruth && g_truthSeen != "")
      for(int k = (int)MathMin(nf, 5) - 1; k >= 0; k--)
         if(HasWord(fresh[k], TruthWords)) Push("🇺🇸 Trump: " + StringSubstr(fresh[k], 0, 200));
   g_truthSeen = newest;
  }

ulong g_calSeen[];   // calendar values already announced
void CheckCalendar()
  {
   if(NewsPushMinutes <= 0 || PushLink != "") return;   // with PushLink the push server sends the news reminders
   datetime now = TimeTradeServer();
   MqlCalendarValue vals[];
   if(CalendarValueHistory(vals, now, now + NewsPushMinutes * 60, NULL, "USD") <= 0) return;
   for(int i = 0; i < ArraySize(vals); i++)
     {
      if(vals[i].time <= now) continue;
      MqlCalendarEvent ev;
      if(!CalendarEventById(vals[i].event_id, ev) || ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
      bool seen = false;
      for(int j = 0; j < ArraySize(g_calSeen); j++) if(g_calSeen[j] == vals[i].id) { seen = true; break; }
      if(seen) continue;
      int n = ArraySize(g_calSeen); ArrayResize(g_calSeen, n + 1); g_calSeen[n] = vals[i].id;
      Push("Bullion Monkey: In " + IntegerToString((int)((vals[i].time - now + 59) / 60)) + " Min. USD-News: " + ev.name + " (hohes Risiko für Gold)");
     }
  }

// once a day in the evening: if there were trades today, remind to fill in the journal
void CheckJournal()
  {
   if(JournalHour < 0) return;
   MqlDateTime l; TimeToStruct(TimeLocal(), l);
   if(l.hour < JournalHour) return;
   l.hour = 0; l.min = 0; l.sec = 0;
   datetime today = StructToTime(l);
   if(g_journalDay == today) return;
   g_journalDay = today;
   MqlDateTime t; TimeToStruct(TimeTradeServer(), t); t.hour = 0; t.min = 0; t.sec = 0;
   double pnl = 0; int n = 0;
   if(!HistorySelect(StructToTime(t), TimeTradeServer() + 60)) return;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      long ty = HistoryDealGetInteger(tk, DEAL_TYPE);
      if(ty != DEAL_TYPE_BUY && ty != DEAL_TYPE_SELL) continue;
      pnl += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP)
           + HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN) n++;
     }
   if(n > 0)
      Push(StringFormat("Bullion Monkey: Heute %d Trade%s, %s%.2f %s. Zeit fürs Journal: Notizen und Screenshots in der App ergänzen.",
           n, n == 1 ? "" : "s", pnl >= 0 ? "+" : "", pnl, AccountInfoString(ACCOUNT_CURRENCY)), true);
  }

void CheckNoSl()
  {
   if(NoSlMinutes <= 0) return;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetDouble(POSITION_SL) > 0) continue;
      if(TimeCurrent() - (datetime)PositionGetInteger(POSITION_TIME) < NoSlMinutes * 60) continue;
      bool seen = false;
      for(int j = 0; j < ArraySize(g_noSl); j++) if(g_noSl[j] == tk) { seen = true; break; }
      if(seen) continue;
      int n = ArraySize(g_noSl); ArrayResize(g_noSl, n + 1); g_noSl[n] = tk;
      Push("Bullion Monkey: " + PositionGetString(POSITION_SYMBOL) + " Position ohne Stop-Loss!");
     }
  }

//+------------------------------------------------------------------+
//| Collect closed positions and upload them                         |
//+------------------------------------------------------------------+
void Sync()
  {
   // not logged in at the broker: history would be empty, so keep the last good data
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || AccountInfoInteger(ACCOUNT_LOGIN) == 0)
      return;
   string payload = BuildPayload();
   if(payload == "")
      return;
   // the timestamp lives outside the comparison, so identical data is not re-uploaded every minute;
   // but every 5 minutes anyway, so the app sees that MT5 is still running
   // DXY and the gold price change all the time: they don't count as a change, but are refreshed once a minute
   string macro = Macro();
   bool macroDue = (macro != g_macro && TimeLocal() - g_upAt >= 60);
   if(payload == g_last && !g_dirty && !macroDue && TimeLocal() - g_upAt < 300)
      return;
   string json = "{\"updatedAt\":\"" + IsoUtc(TimeGMT()) + "\"," + (macro != "" ? macro + "," : "") + payload + "}";
   if(Upload(json))
     {
      g_last = payload;
      g_macro = macro;
      g_dirty = false;
      g_upAt = TimeLocal();
     }
  }

string BuildPayload()
  {
   datetime to = TimeCurrent() + 86400;
   datetime from = TimeCurrent() - (datetime)DaysBack * 86400;
   if(!HistorySelect(from, to))
      return "";

   long     pid[];      // position id
   string   sym[];
   double   pnl[], volIn[], entry[], exitP[], sl[], tp[], slOut[], tpOut[];   // SL/TP at entry, and at close (if set later)
   datetime closeT[], openT[];
   int      side[];     // 0 buy, 1 sell
   bool     closed[];
   int n = 0;
   datetime cashT[];    // deposits and withdrawals, so the app can tell them apart from trading results
   double   cashA[];
   int nc = 0;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      long type = HistoryDealGetInteger(tk, DEAL_TYPE);
      if(type == DEAL_TYPE_BALANCE || type == DEAL_TYPE_CORRECTION || type == DEAL_TYPE_CHARGE || type == DEAL_TYPE_BONUS)
        {
         double a = HistoryDealGetDouble(tk, DEAL_PROFIT);
         if(a != 0) { ArrayResize(cashT, nc + 1); ArrayResize(cashA, nc + 1); cashT[nc] = (datetime)HistoryDealGetInteger(tk, DEAL_TIME); cashA[nc] = a; nc++; }
         continue;
        }
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;   // skip deposits, credit, etc.
      long p = HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      int k = -1;
      for(int j = 0; j < n; j++) if(pid[j] == p) { k = j; break; }
      if(k < 0)
        {
         k = n++;
         ArrayResize(pid, n); ArrayResize(sym, n); ArrayResize(pnl, n); ArrayResize(volIn, n);
         ArrayResize(entry, n); ArrayResize(exitP, n); ArrayResize(sl, n); ArrayResize(tp, n); ArrayResize(slOut, n); ArrayResize(tpOut, n); ArrayResize(closeT, n); ArrayResize(openT, n); ArrayResize(side, n); ArrayResize(closed, n);
         pid[k] = p; sym[k] = HistoryDealGetString(tk, DEAL_SYMBOL); pnl[k] = 0; volIn[k] = 0;
         entry[k] = 0; exitP[k] = 0; sl[k] = 0; tp[k] = 0; slOut[k] = 0; tpOut[k] = 0; closeT[k] = 0; openT[k] = 0; side[k] = 0; closed[k] = false;
        }
      long ent = HistoryDealGetInteger(tk, DEAL_ENTRY);
      double comm = HistoryDealGetDouble(tk, DEAL_COMMISSION);
      double fee  = HistoryDealGetDouble(tk, DEAL_FEE);
      pnl[k] += comm + fee;
      if(ent == DEAL_ENTRY_IN)
        {
         if(volIn[k] == 0)
           {
            entry[k] = HistoryDealGetDouble(tk, DEAL_PRICE);
            sl[k]    = HistoryDealGetDouble(tk, DEAL_SL);
            tp[k]    = HistoryDealGetDouble(tk, DEAL_TP);
            side[k]  = (type == DEAL_TYPE_BUY) ? 0 : 1;
            openT[k] = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
           }
         volIn[k] += HistoryDealGetDouble(tk, DEAL_VOLUME);
        }
      else // OUT, OUT_BY, INOUT
        {
         pnl[k] += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP);
         datetime t = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
         if(t >= closeT[k]) { closeT[k] = t; exitP[k] = HistoryDealGetDouble(tk, DEAL_PRICE); slOut[k] = HistoryDealGetDouble(tk, DEAL_SL); tpOut[k] = HistoryDealGetDouble(tk, DEAL_TP); }
         closed[k] = true;
        }
     }

   long offset = (long)(TimeTradeServer() - TimeGMT());   // broker time minus UTC
   string trades = "";
   for(int k = 0; k < n; k++)
     {
      if(!closed[k]) continue;
      string r = "null", rk = "";
      int dg = (int)SymbolInfoInteger(sym[k], SYMBOL_DIGITS);
      // SL/TP set when the trade was opened; if added later, the level at close
      if(sl[k] <= 0) sl[k] = slOut[k];
      if(tp[k] <= 0) tp[k] = tpOut[k];
      if(sl[k] > 0 && entry[k] > 0 && volIn[k] > 0)
        {
         double ts = SymbolInfoDouble(sym[k], SYMBOL_TRADE_TICK_SIZE);
         double tv = SymbolInfoDouble(sym[k], SYMBOL_TRADE_TICK_VALUE);
         if(ts > 0 && tv > 0)
           {
            double risk = MathAbs(entry[k] - sl[k]) / ts * tv * volIn[k];
            if(risk > 0) { r = DoubleToString(pnl[k] / risk, 2); rk = ",\"risk\":" + DoubleToString(risk, 2); }
           }
        }
      if(trades != "") trades += ",";
      trades += "{\"id\":\"mt5-" + IntegerToString(pid[k]) + "\""
              + ",\"closeUtc\":\"" + IsoUtc(closeT[k] - (datetime)offset) + "\""
              + (openT[k] > 0 ? ",\"openUtc\":\"" + IsoUtc(openT[k] - (datetime)offset) + "\"" : "")
              + ",\"asset\":\"" + sym[k] + "\""
              + ",\"side\":\"" + (side[k] == 0 ? "buy" : "sell") + "\""
              + ",\"volume\":" + DoubleToString(volIn[k], 2)
              + (entry[k] > 0 ? ",\"open\":" + DoubleToString(entry[k], (int)SymbolInfoInteger(sym[k], SYMBOL_DIGITS)) : "")
              + (exitP[k] > 0 ? ",\"close\":" + DoubleToString(exitP[k], (int)SymbolInfoInteger(sym[k], SYMBOL_DIGITS)) : "")
              + (sl[k] > 0 ? ",\"sl\":" + DoubleToString(sl[k], dg) : "")
              + (tp[k] > 0 ? ",\"tp\":" + DoubleToString(tp[k], dg) : "")
              + ",\"pnl\":" + DoubleToString(pnl[k], 2)
              + ",\"r\":" + r + rk + "}";
     }

   string cash = "";
   for(int c = 0; c < nc; c++)
     {
      if(cash != "") cash += ",";
      cash += "{\"t\":\"" + IsoUtc(cashT[c] - (datetime)offset) + "\",\"a\":" + DoubleToString(cashA[c], 2) + "}";
     }

   string acc = "\"account\":{\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
              + ",\"server\":\"" + Esc(AccountInfoString(ACCOUNT_SERVER)) + "\""
              + ",\"company\":\"" + Esc(AccountInfoString(ACCOUNT_COMPANY)) + "\""
              + ",\"currency\":\"" + AccountInfoString(ACCOUNT_CURRENCY) + "\""
              + ",\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2)
              + ",\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "}";
   // open positions, with the floating result
   string pos = "";
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      string ps = PositionGetString(POSITION_SYMBOL);
      int dg = (int)SymbolInfoInteger(ps, SYMBOL_DIGITS);
      if(pos != "") pos += ",";
      pos += "{\"id\":\"" + IntegerToString((long)tk) + "\""
           + ",\"asset\":\"" + ps + "\""
           + ",\"side\":\"" + (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "buy" : "sell") + "\""
           + ",\"volume\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2)
           + ",\"openUtc\":\"" + IsoUtc((datetime)PositionGetInteger(POSITION_TIME) - (datetime)offset) + "\""
           + ",\"open\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), dg)
           + ",\"price\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), dg)
           + ",\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), dg)
           + ",\"tp\":" + DoubleToString(PositionGetDouble(POSITION_TP), dg)
           + ",\"pnl\":" + DoubleToString(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP), 2) + "}";
     }

   // contract details of the chart symbol, for the lot calculator
   string spec = "\"symbol\":{\"name\":\"" + _Symbol + "\""
               + ",\"contract\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE), 2)
               + ",\"tickSize\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 8)
               + ",\"tickValue\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), 8)
               + ",\"volMin\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), 2)
               + ",\"volStep\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), 2)
               + ",\"volMax\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), 2) + "}";

   // chart pictures and candles: {"mt5-<position>":"iob"} (i = entry picture, o = exit picture, b = candles)
   string ids2[], has2[];
   string parts[];
   int np = StringSplit(g_shots, '|', parts);
   for(int i = 0; i < np; i++)
     {
      int d = StringFind(parts[i], "-");
      if(d <= 0) continue;
      string id = StringSubstr(parts[i], 0, d), tg = StringSubstr(parts[i], d + 1, 1);
      int k = -1;
      for(int j = 0; j < ArraySize(ids2); j++) if(ids2[j] == id) { k = j; break; }
      if(k < 0) { k = ArraySize(ids2); ArrayResize(ids2, k + 1); ArrayResize(has2, k + 1); ids2[k] = id; has2[k] = ""; }
      if(StringFind(has2[k], tg) < 0) has2[k] += tg;
     }
   string shots = "";
   for(int j = 0; j < ArraySize(ids2); j++)
      shots += (shots == "" ? "" : ",") + "\"mt5-" + ids2[j] + "\":\"" + has2[j] + "\"";
   string sh = (g_shotGist != "") ? ",\"shotGist\":\"" + g_shotGist + "\",\"shots\":{" + shots + "}" : "";

   return acc + "," + spec + sh + ",\"headlines\":[" + g_news + "],\"truths\":[" + g_truth + "],\"positions\":[" + pos + "],\"trades\":[" + trades + "],\"cash\":[" + cash + "]";
  }

//+------------------------------------------------------------------+
//| GitHub Gist upload                                               |
//+------------------------------------------------------------------+
bool Upload(const string json)
  {
   string files = "\"files\":{\"" + GIST_FILE + "\":{\"content\":\"" + Esc(json) + "\"}}";
   string body, method, url;
   if(g_gist == "")
     {
      method = "POST"; url = API;
      body = "{\"description\":\"Bullion Monkey MT5\",\"public\":false," + files + "}";
     }
   else
     {
      method = "PATCH"; url = API + "/" + g_gist;
      body = "{" + files + "}";
     }
   string headers = "Authorization: Bearer " + GitHubToken + "\r\n"
                  + "Accept: application/vnd.github+json\r\n"
                  + "User-Agent: BullionMonkeySync\r\n"
                  + "Content-Type: application/json\r\n";
   char data[], result[];
   string resHeaders;
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(data, len - 1);   // drop the trailing zero
   ResetLastError();
   int code = WebRequest(method, url, headers, 15000, data, result, resHeaders);
   if(code == -1)
     {
      int err = GetLastError();
      if(err == 4014)
         Alert("Bullion Monkey: https://api.github.com unter Extras > Optionen > Expert Advisors bei WebRequest erlauben.");
      else
         Print("Bullion Monkey: WebRequest Fehler ", err);
      return false;
     }
   string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code == 401) { Alert("Bullion Monkey: GitHub-Token ungültig."); return false; }
   if(code == 404 && g_gist != "") { Print("Bullion Monkey: Gist nicht gefunden: ", g_gist); return false; }
   if(code < 200 || code >= 300) { Print("Bullion Monkey: GitHub antwortet ", code, " ", StringSubstr(resp, 0, 200)); return false; }

   if(g_gist == "")
     {
      g_gist = JsonString(resp, "id");
      if(g_gist != "")
        {
         SaveId(g_gist);
         Alert("Bullion Monkey: Verbunden. Gist-ID für die App: " + g_gist);
        }
     }
   Print("Bullion Monkey: synchronisiert (", g_gist, ")");
   return true;
  }

//+------------------------------------------------------------------+
//| Break-even reminder, price alarms, DXY                           |
//+------------------------------------------------------------------+
void CheckBreakEven()
  {
   if(BreakEvenR <= 0) return;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      double sl = PositionGetDouble(POSITION_SL), op = PositionGetDouble(POSITION_PRICE_OPEN), px = PositionGetDouble(POSITION_PRICE_CURRENT);
      if(sl <= 0) continue;
      bool buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double risk = buy ? op - sl : sl - op;
      if(risk <= 0) continue;                       // SL already at entry or in profit
      double r = (buy ? px - op : op - px) / risk;
      if(r < BreakEvenR) continue;
      bool seen = false;
      for(int j = 0; j < ArraySize(g_be); j++) if(g_be[j] == tk) { seen = true; break; }
      if(seen) continue;
      int n = ArraySize(g_be); ArrayResize(g_be, n + 1); g_be[n] = tk;
      Push("Bullion Monkey: " + PositionGetString(POSITION_SYMBOL) + (buy ? " Buy" : " Sell") + " ist " + DoubleToString(r, 1) + " R im Plus. SL auf Einstieg nachziehen?");
     }
  }

// the push server keeps the alarms the app sets; read them every 30 s and push once when the price crosses one
void CheckAlarms()
  {
   if(!PriceAlarms || PushLink == "" || StringFind(PushLink, "/push/") < 0) return;
   if(TimeLocal() - g_alarmsAt >= 30)
     {
      g_alarmsAt = TimeLocal();
      string url = PushLink; StringReplace(url, "/push/", "/alarms/");
      char data[], res[]; string rh;
      int code = WebRequest("GET", url, "", 5000, data, res, rh);
      if(code == 200) ParseAlarms(CharArrayToString(res, 0, WHOLE_ARRAY, CP_UTF8));
     }
   for(int i = 0; i < ArraySize(g_alId); i++)
     {
      string sym = g_alSym[i] != "" && SymbolSelect(g_alSym[i], true) ? g_alSym[i] : _Symbol;
      double px = SymbolInfoDouble(sym, SYMBOL_BID);
      if(px <= 0) continue;
      double last = g_alLast[i];
      g_alLast[i] = px;
      if(last <= 0 || g_alP[i] <= 0) continue;
      if((last < g_alP[i] && px >= g_alP[i]) || (last > g_alP[i] && px <= g_alP[i]))
        {
         int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         Push("Bullion Monkey: 🔔 Preis-Alarm " + sym + " bei " + DoubleToString(g_alP[i], dg) + (g_alNote[i] != "" ? " · " + g_alNote[i] : ""));
         string url = PushLink; StringReplace(url, "/push/", "/hit/");
         string body = "{\"id\":\"" + g_alId[i] + "\"}";
         char data[], res[]; string rh;
         StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8); ArrayResize(data, ArraySize(data) - 1);
         WebRequest("POST", url, "Content-Type: application/json\r\n", 5000, data, res, rh);
         g_alP[i] = 0;                               // fired; the server drops it from the list
        }
     }
  }

// {"alarms":[{"id":"..","p":4050.5,"sym":"XAUUSD","note":".."},...]}: keep the last seen price of alarms we already know
void ParseAlarms(const string js)
  {
   string ids[]; double ps[], lasts[]; string syms[], notes[];
   int n = 0, pos = 0;
   while((pos = StringFind(js, "\"id\":\"", pos)) >= 0)
     {
      int e = StringFind(js, "}", pos);
      if(e < 0) break;
      string o = StringSubstr(js, pos, e - pos);
      pos = e;
      string id = JsonString(o, "id");
      int pp = StringFind(o, "\"p\":");
      if(id == "" || pp < 0) continue;
      double p = StringToDouble(StringSubstr(o, pp + 4, 20));
      ArrayResize(ids, n + 1); ArrayResize(ps, n + 1); ArrayResize(lasts, n + 1); ArrayResize(syms, n + 1); ArrayResize(notes, n + 1);
      ids[n] = id; ps[n] = p; syms[n] = JsonString(o, "sym"); notes[n] = JsonString(o, "note"); lasts[n] = 0;
      for(int k = 0; k < ArraySize(g_alId); k++) if(g_alId[k] == id) { lasts[n] = g_alLast[k]; if(g_alP[k] == 0) ps[n] = 0; }
      n++;
     }
   ArrayResize(g_alId, n); ArrayResize(g_alP, n); ArrayResize(g_alLast, n); ArrayResize(g_alSym, n); ArrayResize(g_alNote, n);
   for(int k = 0; k < n; k++) { g_alId[k] = ids[k]; g_alP[k] = ps[k]; g_alLast[k] = lasts[k]; g_alSym[k] = syms[k]; g_alNote[k] = notes[k]; }
  }

double DayOpen(const string sym)
  {
   double o[];
   return CopyOpen(sym, PERIOD_D1, 0, 1, o) == 1 ? o[0] : 0;
  }

// US dollar index from the broker's six currency pairs (official ICE weights), and the gold price
string Macro()
  {
   string out = "";
   string gs = "XAUUSD";
   if(!SymbolSelect(gs, true)) gs = _Symbol;
   double gb = SymbolInfoDouble(gs, SYMBOL_BID), go = DayOpen(gs);
   if(gb > 0) out = "\"gold\":{\"p\":" + DoubleToString(gb, 2) + ",\"o\":" + DoubleToString(go, 2) + "}";
   string S[6] = {"EURUSD", "USDJPY", "GBPUSD", "USDCAD", "USDSEK", "USDCHF"};
   double W[6] = {-0.576, 0.136, -0.119, 0.091, 0.042, 0.036};
   double now = 50.14348112, open = 50.14348112;
   for(int i = 0; i < 6; i++)
     {
      if(!SymbolSelect(S[i], true)) return out;
      double b = SymbolInfoDouble(S[i], SYMBOL_BID), o = DayOpen(S[i]);
      if(b <= 0 || o <= 0) return out;
      now *= MathPow(b, W[i]); open *= MathPow(o, W[i]);
     }
   return out + (out != "" ? "," : "") + "\"dxy\":{\"p\":" + DoubleToString(now, 3) + ",\"o\":" + DoubleToString(open, 3) + "}";
  }

//+------------------------------------------------------------------+
//| Chart pictures at entry and exit                                 |
//+------------------------------------------------------------------+
// picture of a chart with the trade's symbol (this chart if it fits), saved to MQL5/Files/bm-shots
void TakeShot(const ulong deal)
  {
   if(!ChartShots || deal == 0 || !HistoryDealSelect(deal)) return;
   long type = HistoryDealGetInteger(deal, DEAL_TYPE);
   if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) return;
   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
   if(entry != DEAL_ENTRY_IN) SaveBars(HistoryDealGetInteger(deal, DEAL_POSITION_ID));
   long chart = (ChartSymbol(0) == sym) ? ChartID() : 0;
   for(long c = ChartFirst(); chart == 0 && c >= 0; c = ChartNext(c))
      if(ChartSymbol(c) == sym) chart = c;
   if(chart == 0) { Print("Bullion Monkey: kein Chart mit ", sym, " offen, kein Chart-Bild."); return; }
   string file = SHOT_DIR + "\\" + IntegerToString(HistoryDealGetInteger(deal, DEAL_POSITION_ID)) + (entry == DEAL_ENTRY_IN ? "-in" : "-out") + ".png";
   ChartRedraw(chart);
   if(!ChartScreenShot(chart, file, 1200, 700, ALIGN_RIGHT))
      Print("Bullion Monkey: Chart-Bild fehlgeschlagen ", GetLastError());
  }

// candles around a closed position (open to close plus some before and after), for the chart in the app's trade details
void SaveBars(const long posId)
  {
   if(!ChartShots || !HistorySelectByPosition(posId)) return;
   datetime op = 0, cl = 0; string sym = "";
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      datetime t = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
      long en = HistoryDealGetInteger(tk, DEAL_ENTRY);
      if(en == DEAL_ENTRY_IN && (op == 0 || t < op)) { op = t; sym = HistoryDealGetString(tk, DEAL_SYMBOL); }
      if(en != DEAL_ENTRY_IN && t > cl) cl = t;
     }
   if(op == 0 || cl == 0 || sym == "") return;
   long dur = (long)(cl - op);
   ENUM_TIMEFRAMES tf = dur < 2400 ? PERIOD_M1 : dur < 6 * 3600 ? PERIOD_M5 : dur < 20 * 3600 ? PERIOD_M15 : dur < 4 * 86400 ? PERIOD_H1 : PERIOD_H4;
   int sec = PeriodSeconds(tf);
   MqlRates r[];
   int n = CopyRates(sym, tf, op - 30 * sec, cl + 15 * sec, r);
   if(n <= 0) return;
   long offset = (long)(TimeTradeServer() - TimeGMT());
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string o = "{\"tf\":" + IntegerToString(sec / 60) + ",\"bars\":[";
   for(int i = 0; i < n; i++)
      o += (i > 0 ? "," : "") + "[" + IntegerToString((long)r[i].time - offset) + "," + DoubleToString(r[i].open, dg) + "," + DoubleToString(r[i].high, dg) + "," + DoubleToString(r[i].low, dg) + "," + DoubleToString(r[i].close, dg) + "]";
   o += "]}";
   int h = FileOpen(SHOT_DIR + "\\" + IntegerToString(posId) + "-bars.json", FILE_WRITE | FILE_BIN);
   if(h == INVALID_HANDLE) return;
   uchar u[]; StringToCharArray(o, u, 0, WHOLE_ARRAY, CP_UTF8); ArrayResize(u, ArraySize(u) - 1);
   FileWriteArray(h, u);
   FileClose(h);
  }

// once: candles for the trades of the last 60 days that have none yet
void BackfillBars()
  {
   if(!ChartShots || !HistorySelect(TimeCurrent() - 60 * 86400, TimeCurrent() + 86400)) return;
   long done[];
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      long ty = HistoryDealGetInteger(tk, DEAL_TYPE);
      if((ty != DEAL_TYPE_BUY && ty != DEAL_TYPE_SELL) || HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN) continue;
      long p = HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      bool seen = StringFind(g_shots, "|" + IntegerToString(p) + "-bars|") >= 0;
      for(int j = 0; !seen && j < ArraySize(done); j++) if(done[j] == p) seen = true;
      if(seen) continue;
      int n = ArraySize(done); ArrayResize(done, n + 1); done[n] = p;
     }
   for(int k = 0; k < ArraySize(done); k++) SaveBars(done[k]);
  }

// one waiting picture per timer run, as base64 text into the pictures gist; the app shows it in the journal
void UploadShot()
  {
   string name;
   long h = FileFindFirst(SHOT_DIR + "\\*.png", name);
   if(h == INVALID_HANDLE) h = FileFindFirst(SHOT_DIR + "\\*.json", name);
   if(h == INVALID_HANDLE) return;
   FileFindClose(h);
   bool bars = StringFind(name, ".json") > 0;
   string path = SHOT_DIR + "\\" + name;
   int f = FileOpen(path, FILE_READ | FILE_BIN);
   if(f == INVALID_HANDLE) return;
   uchar png[], key[], b64[];
   FileReadArray(f, png);
   FileClose(f);
   if(ArraySize(png) == 0 || (!bars && CryptEncode(CRYPT_BASE64, png, key, b64) <= 0)) { FileDelete(path); return; }
   string tag = StringSubstr(name, 0, StringLen(name) - (bars ? 5 : 4));   // "<position>-in" or "<position>-bars"
   string content = bars ? Esc(CharArrayToString(png, 0, WHOLE_ARRAY, CP_UTF8)) : CharArrayToString(b64, 0, WHOLE_ARRAY, CP_ACP);
   string files = "\"files\":{\"" + tag + (bars ? ".json" : ".txt") + "\":{\"content\":\"" + content + "\"}}";
   string body = (g_shotGist == "") ? "{\"description\":\"Bullion Monkey Charts\",\"public\":false," + files + "}" : "{" + files + "}";
   string resp;
   int code = GitHub(g_shotGist == "" ? "POST" : "PATCH", g_shotGist == "" ? API : API + "/" + g_shotGist, body, resp);
   if(code == 404 && g_shotGist != "") { g_shotGist = ""; g_shots = ""; return; }   // gist deleted: start a new one next time
   if(code < 200 || code >= 300) { Print("Bullion Monkey: Chart-Bild nicht hochgeladen (", code, ")"); return; }
   if(g_shotGist == "")
     {
      g_shotGist = JsonString(resp, "id");
      WriteText(SHOT_ID, g_shotGist);
     }
   if(StringFind(g_shots, "|" + tag + "|") < 0)
     {
      g_shots = (g_shots == "" ? "|" : g_shots) + tag + "|";
      if(StringLen(g_shots) > 8000) g_shots = "|" + StringSubstr(g_shots, StringFind(g_shots, "|", 2000) + 1);   // keep the newest
      WriteText(SHOT_DONE, g_shots);
     }
   FileDelete(path);
   g_dirty = true;
   Print("Bullion Monkey: Chart-Bild hochgeladen (", tag, ")");
  }

int GitHub(const string method, const string url, const string body, string &resp)
  {
   string headers = "Authorization: Bearer " + GitHubToken + "\r\n"
                  + "Accept: application/vnd.github+json\r\n"
                  + "User-Agent: BullionMonkeySync\r\n"
                  + "Content-Type: application/json\r\n";
   char data[], result[];
   string rh;
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(data, len - 1);
   int code = WebRequest(method, url, headers, 30000, data, result, rh);
   resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return code;
  }

string ReadText(const string file)
  {
   int h = FileOpen(file, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return "";
   string v = FileReadString(h);
   FileClose(h);
   StringTrimLeft(v); StringTrimRight(v);
   return v;
  }

void WriteText(const string file, const string v)
  {
   int h = FileOpen(file, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, v);
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string IsoUtc(datetime t)
  {
   MqlDateTime d; TimeToStruct(t, d);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ", d.year, d.mon, d.day, d.hour, d.min, d.sec);
  }

string Esc(const string s)
  {
   string o = s;
   StringReplace(o, "\\", "\\\\");
   StringReplace(o, "\"", "\\\"");
   StringReplace(o, "\r", "");
   StringReplace(o, "\n", "\\n");
   StringReplace(o, "\t", " ");
   return o;
  }

// value of the first "key":"..." at the top level of a GitHub response
string JsonString(const string json, const string key)
  {
   int p = StringFind(json, "\"" + key + "\"");
   if(p < 0) return "";
   p = StringFind(json, "\"", StringFind(json, ":", p) + 1);
   if(p < 0) return "";
   int e = StringFind(json, "\"", p + 1);
   return (e > p) ? StringSubstr(json, p + 1, e - p - 1) : "";
  }

string ReadSavedId()
  {
   int h = FileOpen(ID_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return "";
   string id = FileReadString(h);
   FileClose(h);
   StringTrimLeft(id); StringTrimRight(id);
   return id;
  }

void SaveId(const string id)
  {
   int h = FileOpen(ID_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, id);
   FileClose(h);
  }
//+------------------------------------------------------------------+
