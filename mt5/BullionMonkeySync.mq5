//+------------------------------------------------------------------+
//| BullionMonkeySync.mq5                                            |
//| Sends closed trades, open positions and the balance to a secret  |
//| GitHub Gist, which the Bullion Monkey app reads.                 |
//| Setup: Tools > Options > Expert Advisors > "Allow WebRequest for |
//| listed URL" and add https://api.github.com and                   |
//| https://www.financialjuice.com (news headlines)                  |
//| Push messages: Tools > Options > Notifications, enter the        |
//| MetaQuotes ID from the MT5 app on the phone.                     |
//+------------------------------------------------------------------+
#property copyright "Bullion Monkey"
#property version   "1.31"

input string GitHubToken = "";   // GitHub token (classic, only "gist" scope)
input string GistId      = "";   // leave empty: the EA creates a secret gist
input int    DaysBack    = 365;  // how many days of history to send
input int    SyncSeconds = 15;   // check interval in seconds
input bool   PushTrades  = true; // push message when a trade opens or closes
input double DailyLossPct = 3.0; // push when today's loss reaches this % (0 = off)
input int    MaxTradesDay = 3;   // push when more trades than this are opened today (0 = off)
input int    NoSlMinutes  = 2;   // push when a position has no stop-loss after this many minutes (0 = off)
input int    FeedMinutes  = 2;   // read FinancialJuice headlines every n minutes (0 = off)
input bool   PushHeadlines = true; // push gold-relevant headlines
input string HeadlineWords = "gold,xau,fed ,fomc,powell,cpi,pce,nfp,non-farm,payrolls,inflation,rate cut,rate hike,treasury,yields,dollar,dxy,tariff,geopolit"; // comma list for the push filter

#define GIST_FILE "bullion-monkey.json"
#define ID_FILE   "bullion_monkey_gist.txt"
#define API       "https://api.github.com/gists"
#define FEED      "https://www.financialjuice.com/feed.ashx?xy=rss"

string g_gist = "";
string g_last = "";     // last uploaded trade/balance payload, to skip unchanged uploads
bool   g_dirty = true;
datetime g_lossDay = 0, g_tradesDay = 0;   // day of the last limit push, so each fires once a day
ulong  g_noSl[];                          // positions already warned about a missing stop-loss
string g_news = "";                       // JSON array body of the latest headlines
datetime g_newsAt = 0;
string g_newsSeen = "";                   // newest headline already handled, for the push
bool   g_feedWarned = false;

//+------------------------------------------------------------------+
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
   EventSetTimer(SyncSeconds < 10 ? 10 : SyncSeconds);
   if(FeedMinutes > 0) FetchNews();
   Sync();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer()
  {
   CheckNoSl();
   if(FeedMinutes > 0 && TimeLocal() - g_newsAt >= FeedMinutes * 60)
      FetchNews();
   Sync();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      PushDeal(trans.deal);
      g_dirty = true;
      Sync();
     }
  }

//+------------------------------------------------------------------+
//| Push messages to the MT5 app on the phone                        |
//+------------------------------------------------------------------+
void Push(const string msg)
  {
   if(!TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED)) return;
   if(!SendNotification(StringSubstr(msg, 0, 255)))
      Print("Bullion Monkey: Push fehlgeschlagen ", GetLastError());
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
         Push(StringFormat("Bullion Monkey: %s geschlossen %s%.2f %s · heute %s%.2f %s",
              sym, p >= 0 ? "+" : "", p, cur, dayPnl >= 0 ? "+" : "", dayPnl, cur));
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

bool IsGoldNews(const string title)
  {
   string t = " " + title + " "; StringToLower(t);
   string w[]; int n = StringSplit(HeadlineWords, ',', w);
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
   // the timestamp lives outside the comparison, so identical data is not re-uploaded every minute
   if(payload == g_last && !g_dirty)
      return;
   string json = "{\"updatedAt\":\"" + IsoUtc(TimeGMT()) + "\"," + payload + "}";
   if(Upload(json))
     {
      g_last = payload;
      g_dirty = false;
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
   double   pnl[], volIn[], entry[], sl[];
   datetime closeT[], openT[];
   int      side[];     // 0 buy, 1 sell
   bool     closed[];
   int n = 0;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      long type = HistoryDealGetInteger(tk, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;   // skip deposits, credit, etc.
      long p = HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      int k = -1;
      for(int j = 0; j < n; j++) if(pid[j] == p) { k = j; break; }
      if(k < 0)
        {
         k = n++;
         ArrayResize(pid, n); ArrayResize(sym, n); ArrayResize(pnl, n); ArrayResize(volIn, n);
         ArrayResize(entry, n); ArrayResize(sl, n); ArrayResize(closeT, n); ArrayResize(openT, n); ArrayResize(side, n); ArrayResize(closed, n);
         pid[k] = p; sym[k] = HistoryDealGetString(tk, DEAL_SYMBOL); pnl[k] = 0; volIn[k] = 0;
         entry[k] = 0; sl[k] = 0; closeT[k] = 0; openT[k] = 0; side[k] = 0; closed[k] = false;
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
            side[k]  = (type == DEAL_TYPE_BUY) ? 0 : 1;
            openT[k] = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
           }
         volIn[k] += HistoryDealGetDouble(tk, DEAL_VOLUME);
        }
      else // OUT, OUT_BY, INOUT
        {
         pnl[k] += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP);
         datetime t = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
         if(t > closeT[k]) closeT[k] = t;
         closed[k] = true;
        }
     }

   long offset = (long)(TimeTradeServer() - TimeGMT());   // broker time minus UTC
   string trades = "";
   for(int k = 0; k < n; k++)
     {
      if(!closed[k]) continue;
      string r = "null";
      if(sl[k] > 0 && entry[k] > 0 && volIn[k] > 0)
        {
         double ts = SymbolInfoDouble(sym[k], SYMBOL_TRADE_TICK_SIZE);
         double tv = SymbolInfoDouble(sym[k], SYMBOL_TRADE_TICK_VALUE);
         if(ts > 0 && tv > 0)
           {
            double risk = MathAbs(entry[k] - sl[k]) / ts * tv * volIn[k];
            if(risk > 0) r = DoubleToString(pnl[k] / risk, 2);
           }
        }
      if(trades != "") trades += ",";
      trades += "{\"id\":\"mt5-" + IntegerToString(pid[k]) + "\""
              + ",\"closeUtc\":\"" + IsoUtc(closeT[k] - (datetime)offset) + "\""
              + (openT[k] > 0 ? ",\"openUtc\":\"" + IsoUtc(openT[k] - (datetime)offset) + "\"" : "")
              + ",\"asset\":\"" + sym[k] + "\""
              + ",\"side\":\"" + (side[k] == 0 ? "buy" : "sell") + "\""
              + ",\"volume\":" + DoubleToString(volIn[k], 2)
              + ",\"pnl\":" + DoubleToString(pnl[k], 2)
              + ",\"r\":" + r + "}";
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

   return acc + "," + spec + ",\"headlines\":[" + g_news + "],\"positions\":[" + pos + "],\"trades\":[" + trades + "]";
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
